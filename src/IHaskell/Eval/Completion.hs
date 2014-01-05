{-# LANGUAGE NoImplicitPrelude, OverloadedStrings #-}
{- |
Description : Generates tab completion options.

This has a limited amount of context sensitivity. It distinguishes between four contexts at the moment:
- import statements (completed using modules)
- identifiers (completed using in scope values)
- extensions via :ext (completed using GHC extensions)
- qualified identifiers (completed using in-scope values)

-}
module IHaskell.Eval.Completion (complete, completionTarget, completionType, CompletionType(..)) where

import Control.Applicative ((<$>))
import Data.ByteString.UTF8 hiding (drop, take)
import Data.Char
import Data.List (find, isPrefixOf, nub, findIndex, intercalate, elemIndex)
import Data.List.Split
import Data.List.Split.Internals
import Data.Maybe
import Data.String.Utils (strip, startswith, replace)
import Prelude

import GHC
import DynFlags
import GhcMonad
import PackageConfig
import Outputable (showPpr)

import IHaskell.Types


data CompletionType 
     = Empty 
     | Identifier String
     | Extension String
     | Qualified String String
     | ModuleName String String
     deriving (Show, Eq)

complete :: GHC.GhcMonad m => String -> Int -> m (String, [String])
complete line pos = do
  flags <- getSessionDynFlags
  rdrNames <- map (showPpr flags) <$> getRdrNamesInScope
  scopeNames <- nub <$> map (showPpr flags) <$> getNamesInScope
  let isQualified = ('.' `elem`)
      unqualNames = nub $ filter (not . isQualified) rdrNames
      qualNames = nub $ scopeNames ++ filter isQualified rdrNames

  let Just db = pkgDatabase flags
      getNames = map moduleNameString . exposedModules
      moduleNames = nub $ concatMap getNames db

  let target = completionTarget line pos
      matchedText = intercalate "." target

  options <- 
        case completionType line target of
          Empty -> return []

          Identifier candidate ->
            return $ filter (candidate `isPrefixOf`) unqualNames

          Qualified moduleName candidate -> do
            trueName <- getTrueModuleName moduleName
            let prefix = intercalate "." [trueName, candidate]
                completions = filter (prefix `isPrefixOf`)  qualNames
                falsifyName = replace trueName moduleName
            return $ map falsifyName completions

          ModuleName previous candidate -> do
            let prefix = if null previous
                         then candidate
                         else intercalate "." [previous, candidate]
            return $ filter (prefix `isPrefixOf`) moduleNames

          Extension ext -> do
            let extName (name, _, _) = name
                names = map extName xFlags
                nonames = map ("No" ++) names
            return $ filter (ext `isPrefixOf`) $ names ++ nonames

  return (matchedText, options)

getTrueModuleName :: GhcMonad m => String -> m String
getTrueModuleName name = do
  -- Only use the things that were actually imported
  let onlyImportDecl (IIDecl decl) = Just decl
      onlyImportDecl _ = Nothing

  -- Get all imports that we use.
  imports <- catMaybes <$> map onlyImportDecl <$> getContext

  -- Find the ones that have a qualified name attached.
  -- If this name isn't one of them, it already is the true name.
  flags <- getSessionDynFlags
  let qualifiedImports = filter (isJust . ideclAs) imports
      hasName imp = name == (showPpr flags . fromJust . ideclAs) imp
  case find hasName qualifiedImports of
    Nothing -> return name  
    Just trueImp -> return $ showPpr flags $ unLoc $ ideclName trueImp

completionType :: String -> [String] -> CompletionType
completionType line [] = Empty
completionType line target
  | startswith "import" stripped && isModName
    = ModuleName dotted candidate
  | isModName && (not . null . init) target
    = Qualified dotted candidate
  | startswith ":e" stripped
    = Extension candidate 
  | otherwise
    = Identifier candidate
  where stripped = strip line
        dotted = dots target
        candidate = last target
        dots = intercalate "." . init
        isModName = all isCapitalized (init target)
        isCapitalized = isUpper . head


-- | Get the word under a given cursor location.
completionTarget :: String -> Int -> [String]
completionTarget code cursor = expandCompletionPiece pieceToComplete
  where 
    pieceToComplete = map fst <$> find (elem cursor . map snd) pieces
    pieces = splitAlongCursor $ split splitter $ zip code [1 .. ]
    splitter = defaultSplitter {
      -- Split using only the characters, which are the first elements of
      -- the (char, index) tuple
      delimiter = Delimiter [uncurry isDelim],
      -- Condense multiple delimiters into one and then drop them.
      condensePolicy = Condense,
      delimPolicy = Drop
    }

    isDelim char idx = char `elem` neverIdent || isSymbol char

    splitAlongCursor :: [[(Char, Int)]] -> [[(Char, Int)]]
    splitAlongCursor [] = []
    splitAlongCursor (x:xs) = 
      case elemIndex cursor $  map snd x of
        Nothing -> x:splitAlongCursor xs
        Just idx -> take (idx + 1) x:drop (idx + 1) x:splitAlongCursor xs

    -- These are never part of an identifier.
    neverIdent = " \n\t(),{}[]\\'\"`"

    expandCompletionPiece Nothing = []
    expandCompletionPiece (Just str) = splitOn "." str 