module Base (
    -- * General utilities
    module Control.Applicative,
    module Control.Monad.Extra,
    module Data.Bifunctor,
    module Data.Function,
    module Data.List.Extra,
    module Data.Maybe,
    module Data.Monoid,
    MonadTrans(lift),

    -- * Shake
    module Development.Shake,
    module Development.Shake.Classes,
    module Development.Shake.FilePath,

    -- * Paths
    configPath, configFile, sourcePath, programInplacePath,

    -- * Output
    putColoured, putOracle, putBuild, putSuccess, putError,

    -- * Miscellaneous utilities
    minusOrd, intersectOrd, lookupAll, replaceEq, quote, replaceSeparators,
    unifyPath, (-/-), versionToInt, matchVersionedFilePath
    ) where

import Control.Applicative
import Control.Monad.Extra
import Control.Monad.Reader
import Data.Bifunctor
import Data.Char
import Data.Function
import Data.List.Extra
import Data.Maybe
import Data.Monoid
import Development.Shake hiding (parallel, unit, (*>), Normal)
import Development.Shake.Classes
import Development.Shake.FilePath
import System.Console.ANSI
import qualified System.Info as Info
import System.IO

-- TODO: reexport Stage, etc.?

-- Build system files and paths
hadrianPath :: FilePath
hadrianPath = "hadrian"

configPath :: FilePath
configPath = hadrianPath -/- "cfg"

configFile :: FilePath
configFile = configPath -/- "system.config"

-- | Path to source files of the build system, e.g. this file is located at
-- sourcePath -/- "Base.hs". We use this to `need` some of the source files.
sourcePath :: FilePath
sourcePath = hadrianPath -/- "src"

-- TODO: move to buildRootPath, see #113
programInplacePath :: FilePath
programInplacePath = "inplace/bin"

-- Utility functions
-- | Find and replace all occurrences of a value in a list
replaceEq :: Eq a => a -> a -> [a] -> [a]
replaceEq from = replaceWhen (== from)

-- | Find and replace all occurrences of path separators in a String with a Char
replaceSeparators :: Char -> String -> String
replaceSeparators = replaceWhen isPathSeparator

replaceWhen :: (a -> Bool) -> a -> [a] -> [a]
replaceWhen p to = map (\from -> if p from then to else from)

-- | Add quotes to a String
quote :: String -> String
quote s = "\"" ++ s ++ "\""

-- | Given a version string such as "2.16.2" produce an integer equivalent
versionToInt :: String -> Int
versionToInt s = major * 1000 + minor * 10 + patch
  where
    [major, minor, patch] = map read . words $ replaceEq '.' ' ' s

-- | Normalise a path and convert all path separators to @/@, even on Windows.
unifyPath :: FilePath -> FilePath
unifyPath = toStandard . normaliseEx

-- | Combine paths with a forward slash regardless of platform.
(-/-) :: FilePath -> FilePath -> FilePath
"" -/- b = b
a  -/- b
    | last a == '/' = a ++       b
    | otherwise     = a ++ '/' : b

infixr 6 -/-

-- | A more colourful version of Shake's putNormal
putColoured :: Color -> String -> Action ()
putColoured colour msg = do
    liftIO $ set [SetColor Foreground Vivid colour]
    putNormal msg
    liftIO $ set []
    liftIO $ hFlush stdout
  where
    set a = do
        supported <- hSupportsANSI stdout
        when (win || supported) $ setSGR a
    -- An ugly hack to always try to print colours when on mingw and cygwin.
    -- See: https://github.com/snowleopard/hadrian/pull/253
    win = "mingw" `isPrefixOf` Info.os || "cygwin" `isPrefixOf` Info.os

-- | Make oracle output more distinguishable
putOracle :: String -> Action ()
putOracle = putColoured Blue

-- | Make build output more distinguishable
putBuild :: String -> Action ()
putBuild = putColoured White

-- | A more colourful version of success message
putSuccess :: String -> Action ()
putSuccess = putColoured Green

-- | A more colourful version of error message
putError :: String -> Action a
putError msg = do
    putColoured Red msg
    error $ "GHC build system error: " ++ msg

-- Explicit definition to avoid dependency on Data.List.Ordered
-- | Difference of two ordered lists.
minusOrd :: Ord a => [a] -> [a] -> [a]
minusOrd [] _  = []
minusOrd xs [] = xs
minusOrd (x:xs) (y:ys) = case compare x y of
    LT -> x : minusOrd xs (y:ys)
    EQ ->     minusOrd xs ys
    GT ->     minusOrd (x:xs) ys

-- Explicit definition to avoid dependency on Data.List.Ordered. TODO: add tests
-- | Intersection of two ordered lists by a predicate.
intersectOrd :: (a -> b -> Ordering) -> [a] -> [b] -> [a]
intersectOrd cmp = loop
  where
    loop [] _ = []
    loop _ [] = []
    loop (x:xs) (y:ys) = case cmp x y of
        LT ->     loop xs (y:ys)
        EQ -> x : loop xs (y:ys)
        GT ->     loop (x:xs) ys

-- | Lookup all elements of a given sorted list in a given sorted dictionary.
-- @lookupAll list dict@ is equivalent to @map (flip lookup dict) list@ but has
-- linear complexity O(|list| + |dist|) instead of quadratic O(|list| * |dict|).
--
-- > lookupAll ["b", "c"] [("a", 1), ("c", 3), ("d", 4)] == [Nothing, Just 3]
-- > list & dict are sorted: lookupAll list dict == map (flip lookup dict) list
lookupAll :: Ord a => [a] -> [(a, b)] -> [Maybe b]
lookupAll []     _      = []
lookupAll (_:xs) []     = Nothing : lookupAll xs []
lookupAll (x:xs) (y:ys) = case compare x (fst y) of
    LT -> Nothing      : lookupAll xs (y:ys)
    EQ -> Just (snd y) : lookupAll xs (y:ys)
    GT -> lookupAll (x:xs) ys

-- | Given a @prefix@ and a @suffix@ check whether a @filePath@ matches the
-- template @prefix ++ version ++ suffix@ where @version@ is an arbitrary string
-- comprising digits (@0-9@), dashes (@-@), and dots (@.@). Examples:
--
--- * @'matchVersionedFilePath' "foo/bar"  ".a" "foo/bar.a"     '==' 'True'@
--- * @'matchVersionedFilePath' "foo/bar"  ".a" "foo\bar.a"     '==' 'False'@
--- * @'matchVersionedFilePath' "foo/bar"  "a"  "foo/bar.a"     '==' 'True'@
--- * @'matchVersionedFilePath' "foo/bar"  ""   "foo/bar.a"     '==' 'False'@
--- * @'matchVersionedFilePath' "foo/bar"  "a"  "foo/bar-0.1.a" '==' 'True'@
--- * @'matchVersionedFilePath' "foo/bar-" "a"  "foo/bar-0.1.a" '==' 'True'@
--- * @'matchVersionedFilePath' "foo/bar/" "a"  "foo/bar-0.1.a" '==' 'False'@
matchVersionedFilePath :: String -> String -> FilePath -> Bool
matchVersionedFilePath prefix suffix filePath =
    case stripPrefix prefix filePath >>= stripSuffix suffix of
        Nothing      -> False
        Just version -> all (\c -> isDigit c || c == '-' || c == '.') version
