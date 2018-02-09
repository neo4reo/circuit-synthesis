{-# LANGUAGE TupleSections #-}
{-# LANGUAGE RecordWildCards #-}

module Boots.Garbler where

import Circuit
import Circuit.Builder
import Circuit.Builder.Internals (runCircuitT)
import Circuit.Conversion
import Circuit.Utils
import Examples.Goldreich
import Examples.Simple

import Control.Monad
import Control.Monad.Trans (liftIO, lift)
import Data.Array
import Data.Array.IO
import Data.IORef
import Lens.Micro.Platform
import System.Exit
import System.IO
import Text.Printf
import qualified Data.IntMap as IM

data GarblerParams = GarblerParams {
    securityParam :: Int,
    paddingSize   :: Int,
    numIndices    :: Int,
    gatesPerIndex :: Int
} deriving (Show, Read)

-- XXX: only fan-out one is secure at the moment
garbler :: GarblerParams -> Circ2 -> IO (Acirc2, (Circ, Circ, [Circ]))
garbler (GarblerParams {..}) c = runCircuitT $ do
    let numIterations = ceiling (fi (length (garbleableGates c)) / fi gatesPerIndex)
        ixLen = ceiling (fi numIterations ** (1 / fi numIndices))

    -- seeds to the PRGs. the number of seeds is determined by the number of symbols in c.
    -- each seed corresponds to the inputs for each symbol, and is used to generate their wirelabels
    seeds <- replicateM (nsymbols c) (symbol securityParam)

    -- the main seed, used to generate all intermediate wirelabels
    s <- foldM1 (zipWithM circXor) seeds

    let wlGen nWLs = do
            g <- prgBuilder securityParam (securityParam * nWLs) 5 xorAnd
            let g' xs = safeChunksOf securityParam <$> g xs
            asCirc <- lift $ buildCircuitT (inputs securityParam >>= g >>= outputs)
            return (g', toCirc asCirc)

    -- G1 is the PRG used to generate intermediate wirelabels
    (g1, g1Save) <- do
        let nWLs = 1 + nconsts c + nsecrets c + length (garbleableGates c)
        wlGen nWLs

    -- G2 is the PRG used to encrypt the garbled tables
    (g2, g2Save) <- do
        g <- prgBuilder securityParam (2*(securityParam + paddingSize)) 5 xorAnd
        let g' i xs = (!! i) . safeChunksOf (securityParam+paddingSize) <$> g xs
        asCirc <- lift $ buildCircuitT (inputs securityParam >>= g >>= outputs)
        return (g', toCirc asCirc)

    -- generate the wirelabels for each symbol
    (inpGs, inpGSaves) <- unzip <$> mapM wlGen (map (2*) (symlens c))
    inputWLs <- do
        wls <- concat <$> zipWithM ($) inpGs seeds
        return $ listArray (InputId 0, InputId (ninputs c-1)) (pairsOf wls)

    allWires <- do
        -- construct the true wirelabels by xoring in delta
        (delta:falseWLs) <- g1 s

        fresh  <- liftIO $ newIORef falseWLs
        labels <- liftIO $ (newArray_ (0, Ref (nwires c-1)) :: IO (IOArray Ref ([Ref], [Ref])))

        let nextFresh = liftIO $ do
                whenM (null <$> readIORef fresh) $ do
                    putStrLn "[garbler] not enough outputs from G1!"
                    exitFailure
                z <- head <$> readIORef fresh
                modifyIORef fresh tail
                return z

        forM_ (wires c) $ \(zref, g) -> case g of
            (Bool2Base (Input id)) -> do
                liftIO $ writeArray labels zref (inputWLs ! id)

            (Bool2Xor xref yref) | nsymbols c == 1 || not (hasInputArg c g) -> do
                -- only use freeXOR for intermediate gates, this allows MIFE since freeXOR requires
                -- globally known delta, but we dont know it until we have all the seeds.
                x <- fst <$> liftIO (readArray labels xref)
                y <- fst <$> liftIO (readArray labels yref)
                z  <- zipWithM circXor x y
                z' <- zipWithM circXor z delta
                liftIO $ writeArray labels zref (z, z')

            _ -> do
                z  <- nextFresh
                z' <- zipWithM circXor z delta
                liftIO $ writeArray labels zref (z, z')

        liftIO (freeze labels)

    mapM_ saveRef (allWires ^.. each.each.each)

    -- plaintext outputs for the output gates
    zero <- constant 0
    one  <- constant 1
    outWires <- do
        let zs = replicate (securityParam-1) zero
        return (zs++[zero], zs++[one])

    -- gate wires is a list of lists of the wires needed for the ith garbled gate, in the correct order
    gateWires <- lift $ randIO $ forM (garbleableGates c) $ \(zref,g) -> do
        let [xref,yref] = gateArgs g
            get stuff 0 = fst stuff
            get stuff 1 = snd stuff

        -- randomize the truth table for gate g
        tt <- randomize (permutations 2 [0,1])

        -- for each table entry, we need to know whether to encrypt the first or second wirelabel of z
        fmap concat $ forM tt $ \[i,j] -> do
            let x = get (allWires ! xref) i
                y = get (allWires ! yref) j
                z = if isOutputRef c zref
                    then get outWires (gateEval (const undefined) g [i,j])
                    else get (allWires ! zref) (gateEval (const undefined) g [i,j])
            return (x ++ y ++ z)

    gateWLs <-
        if gatesPerIndex < length (garbleableGates c) then do
            -- relevant wires for this iteration
            let gatePad     = replicate (3*4*securityParam) zero
                wireBundles = map concat $ chunksOfPad gatesPerIndex gatePad gateWires
            ix <- sigmaProd =<< replicateM numIndices (sigma ixLen) -- the index to evaluate
            relevantSel <- selectListSigma ix wireBundles
            return $ safeChunksOf (3*4*securityParam) relevantSel
        else
            return gateWires

    let pad = replicate paddingSize zero

    forM_ gateWLs $ \gateWL -> do
        let ws = safeChunksOf 3 $ safeChunksOf securityParam gateWL
        forM_ (zip ws (permutations 2 [0,1])) $ \([x,y,z],[i,j]) -> do
            mx  <- g2 j x
            my  <- g2 i y
            row <- foldM1 (zipWithM circXor) [mx, my, pad ++ z]
            outputs row

    return (g1Save, g2Save, inpGSaves) -- the PRGs for evaluation

--------------------------------------------------------------------------------
-- helpers

isXor :: BoolGate2 -> Bool
isXor (Bool2Xor _ _) = True
isXor _              = False

hasInputArg :: Circ2 -> BoolGate2 -> Bool
hasInputArg c gate = any isInput $ map (getGate c) (gateArgs gate)
  where
    isInput (Bool2Base (Input _)) = True
    isInput _ = False

garbleableGates :: Circ2 -> [(Ref, BoolGate2)]
garbleableGates c = filter garbleMe (gates c)
  where
    garbleMe (_,g) = not (isXor g) || (nsymbols c > 1 && hasInputArg c g)

fi = fromIntegral
