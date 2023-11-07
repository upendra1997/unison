{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ViewPatterns #-}

module Unison.UnisonFile.Summary
  ( UnisonFileVars (..),
    fromUnisonFile,
  )
where

import Data.Foldable (toList)
import Data.Map qualified as Map
import U.Codebase.Decl qualified as DeclType
import Unison.UnisonFile (UnisonFile)
import Unison.UnisonFile.Type qualified as UF
import Unison.WatchKind (WatchKind)

data UnisonFileVars v = UnisonFileVars
  { decls :: [(DeclType.DeclType, v)],
    terms :: [v],
    watches :: [(WatchKind, v)]
  }
  deriving stock (Show)

fromUnisonFile :: UnisonFile v a -> UnisonFileVars v
fromUnisonFile uf = UnisonFileVars decls terms watches
  where
    decls =
      ((DeclType.Effect,) <$> toList (Map.keys uf.effectDeclarationsId))
        <> ((DeclType.Data,) <$> toList (Map.keys uf.dataDeclarationsId))
    terms = (\(v, _a, _tm) -> v) <$> uf.terms
    watches =
      [ (wk, v) | (wk, vs) <- Map.toList uf.watches, (v, _a, _tm) <- vs
      ]
