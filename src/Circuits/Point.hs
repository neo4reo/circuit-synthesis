{-# LANGUAGE TupleSections #-}

module Circuits.Point where

import Circuit
import Circuit.Builder
import Data.List.Split (chunksOf)
import Control.Monad
import Util
import Rand

make :: IO [(Maybe String, Circuit)]
make = sequence
    [ (Just "point.dsl.acirc",) <$> point 27 8
    , (Just "point_base8.dsl.acirc",) <$> pointBaseN 27 8
    ]

point :: Int -> Int -> IO Circuit
point ninputs symlen = do
    let q = (fromIntegral ninputs :: Integer) ^ (fromIntegral symlen :: Integer)
    thePoint <- randIntegerModIO q
    let nbits = numBits q
        bs    = num2Bits nbits thePoint
        ixs   = map bits2Num $ chunksOf (nbits `div` ninputs) bs
        sels  = map (toSel symlen) ixs
    return $ buildCircuit $ do
        setSymlen symlen
        xs <- replicateM ninputs (inputs symlen)
        ys <- mapM secrets sels
        -- !(!(x1=y1) + !(x2=y2) + ... + !(xn=yn))
        zs <- mapM (circNot <=< circSum <=< uncurry (zipWithM circMul)) (zip xs ys)
        output =<< circNot =<< circSum zs
  where
    toSel n x = [ if i == x then 1 else 0 | i <- [0..n-1] ]

pointBaseN :: Int -> Int -> IO Circuit
pointBaseN ndigits base = do
    let q = (fromIntegral base :: Integer) ^ (fromIntegral ndigits :: Integer)
    thePoint <- randIntegerModIO q
    let pointDigits = num2Base base ndigits thePoint
    return $ buildCircuit $ do
        setBase base
        xs <- inputs ndigits
        ys <- secrets pointDigits
        -- !((x1-y1) + (x2-y2) + ... + (xn-yn))
        output =<< circSum =<< zipWithM circSub xs ys
