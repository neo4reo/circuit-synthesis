module Main where

import Circuit
import Util
import Rand
import Circuit.Builder
import Circuit.Optimizer (flatten)
import Circuit.Parser (CircuitParser)
import qualified Circuit.Format.Acirc   as Acirc

import Circuits.Aes as Aes
import Circuits.Goldreich as Goldreich
import Circuits.Tribes as Tribes

import Control.Monad
import Options
import Text.Printf
import System.Exit

data MainOptions = MainOptions { opt_info       :: Bool
                               , opt_latex_info :: Bool
                               , opt_verbose    :: Bool
                               , opt_test       :: Bool
                               , opt_gentests   :: Maybe Int
                               , opt_gencirc    :: Maybe String
                               , opt_add_acirc_tests    :: Bool
                               , opt_randomize_secrets  :: Bool
                               , opt_write_to_file      :: Maybe String
                               , opt_flatten            :: Bool
                               }

instance Options MainOptions where
    defineOptions = pure MainOptions
        <*> defineOption optionType_bool
            (\o -> o { optionLongFlags   = ["info"]
                     , optionShortFlags  = "i"
                     , optionDescription = "Show circuit info."
                     })
        <*> defineOption optionType_bool
            (\o -> o { optionLongFlags   = ["latex"]
                     , optionShortFlags  = "l"
                     , optionDescription = "Show circuit info as a latex table."
                     })
        <*> defineOption optionType_bool
            (\o -> o { optionShortFlags  = "v"
                     , optionLongFlags   = ["verbose"]
                     , optionDescription = "Be verbose."
                     })
        <*> defineOption optionType_bool
            (\o -> o { optionShortFlags  = "t"
                     , optionLongFlags   = ["test"]
                     , optionDescription = "Run the circuit on tests (random if none exist)."
                     })
        <*> defineOption (optionType_maybe optionType_int)
            (\o -> o { optionLongFlags   = ["gen-tests"]
                     , optionDescription = "Generate tests."
                     })
        <*> defineOption (optionType_maybe optionType_string)
            (\o -> o { optionLongFlags   = ["gen-circuit"]
                     , optionShortFlags  = "C"
                     , optionDescription = "Generate a circuit"
                     })
        <*> defineOption optionType_bool
            (\o -> o { optionShortFlags  = "A"
                     , optionLongFlags   = ["add-tests"]
                     , optionDescription = "Add tests to the acirc file"
                     })
        <*> defineOption optionType_bool
            (\o -> o { optionShortFlags  = "r"
                     , optionLongFlags   = ["randomize-secrets"]
                     , optionDescription = "Randomize the key"
                     })
        <*> defineOption (optionType_maybe optionType_string)
            (\o -> o { optionShortFlags  = "o"
                     , optionLongFlags   = ["output"]
                     , optionDescription = "Write the circuit to file FILE"
                     })
        <*> defineOption optionType_bool
            (\o -> o { optionShortFlags  = "f"
                     , optionLongFlags   = ["flatten"]
                     , optionDescription = "Flatten the input using Sage"
                     })


main :: IO ()
main = runCommand $ \opts args -> do
    case opt_gencirc opts of
        Just "aes"       -> Aes.make
        Just "goldreich" -> Goldreich.makePRG
        Just "ggm"       -> Goldreich.makeGGM
        Just "applebaum" -> Goldreich.makeApplebaum
        Just "tribes"    -> Tribes.make
        Just "gf28Mult"  -> Aes.makeGF28Mult
        Just _ -> do
            putStrLn "[error] known circuit generation modes: aes, goldreich, ggm, applebaum, tribes, gf28Mult"
            exitFailure
        Nothing -> do
            when (null args) $ do
                putStrLn "[error] input circuit required"
                exitFailure
            let inputFile = head args
                parser    = parserFor inputFile :: CircuitParser
            when (opt_add_acirc_tests opts) $ Acirc.addTestsToFile inputFile
            (c,ts) <- parser <$> readFile inputFile
            c <- if opt_flatten opts then flatten c else return c
            c <- if opt_randomize_secrets opts then randomizeSecrets c else return c
            when (opt_info opts) $ printCircInfo c
            when (opt_latex_info opts) $ printCircInfoLatex c
            ts' <- case opt_gentests opts of
                Nothing -> return ts
                Just i  -> replicateM i (genTest (ninputs c) c)
            when (opt_test opts) $ evalTests opts c ts'
            case opt_write_to_file opts of
                Just f  -> Acirc.write f c
                Nothing -> putStrLn =<< Acirc.showCircWithTests 10 c
            exitSuccess

evalTests :: MainOptions -> Circuit -> [TestCase] -> IO ()
evalTests opts c ts = do
    pr "evaluating plaintext circuit tests"
    ok <- ensure (opt_verbose opts) c ts
    if ok then pr "ok" else pr "failed"

dirName :: FilePath -> Int -> FilePath
dirName fp λ = fp ++ "." ++ show λ

getKappa :: Circuit -> Integer
getKappa c = δ + 2*n + n*(2*n-1)
  where
    n = fromIntegral $ ninputs c
    δ = sum (degs c)

parserFor :: String -> CircuitParser
parserFor filename = case extension filename of
    "acirc" -> Acirc.parseCirc
    ext     -> error $ printf "[error] unknown circuit type: \"%s\"" ext
  where
    extension = reverse . takeWhile (/= '.') . reverse
