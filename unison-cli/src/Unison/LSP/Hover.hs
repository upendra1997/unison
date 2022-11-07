{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PolyKinds #-}

module Unison.LSP.Hover where

import Control.Lens hiding (List)
import Control.Monad.Reader
import qualified Data.IntervalMap.Lazy as IM
import qualified Data.Map as Map
import qualified Data.Text as Text
import Language.LSP.Types
import Language.LSP.Types.Lens hiding (only, to)
import qualified Unison.ABT as ABT
import qualified Unison.Codebase as Codebase
import qualified Unison.ConstructorType as CT
import qualified Unison.Debug as Debug
import Unison.LSP.Conversions (annToInterval)
import Unison.LSP.FileAnalysis (getFileAnalysis, getFileDefLocations, getFileSummary)
import Unison.LSP.Types
import Unison.Prelude
import qualified Unison.PrettyPrintEnvDecl as PPED
import Unison.Referent (Referent)
import qualified Unison.Referent as Referent
import Unison.Symbol (Symbol)
import qualified Unison.Syntax.Lexer as Lex
import qualified Unison.Syntax.Parser as Parser
import qualified Unison.Syntax.TypePrinter as TypePrinter
import qualified Unison.Term as Term
import qualified Unison.UnisonFile as UF
import Unison.Util.List (safeHead)

-- | Hover help handler
--
-- TODO:
--   * Add docs
--   * Resolve fqn on hover
hoverHandler :: RequestMessage 'TextDocumentHover -> (Either ResponseError (ResponseResult 'TextDocumentHover) -> Lsp ()) -> Lsp ()
hoverHandler m respond =
  respond . Right =<< runMaybeT do
    let pos = (m ^. params . position)
    hoverTxt <- hoverInfo (m ^. params . textDocument . uri) pos
    pure $
      Hover
        { _contents = HoverContents (MarkupContent MkMarkdown hoverTxt),
          _range = Nothing -- TODO add range info
        }

hoverInfo :: Uri -> Position -> MaybeT Lsp Text
hoverInfo uri p = do
  Debug.debugM Debug.LSP "POINT" p
  FileAnalysis {tokenMap, typecheckedFile} <- MaybeT $ getFileAnalysis uri
  FileSummary {termSummary, testWatchSummary, exprWatchSummary} <- getFileSummary uri
  fileDefLocations <- getFileDefLocations uri
  Debug.debugM Debug.LSP "TYPECHECKED" typecheckedFile
  subTermMap <- mkSubTermMap fileDefLocations <$> MaybeT (pure typecheckedFile)
  Debug.debugM Debug.LSP "SubTerms" subTermMap
  let matchingHoverInfos = concat . IM.elems $ IM.containing subTermMap p
  let matchingLexeme = IM.elems $ IM.containing tokenMap p

  Debug.debugM Debug.LSP "Matching" matchingHoverInfos
  ppe <- lift $ globalPPE
  let renderType typ = Text.pack $ TypePrinter.prettyStr (Just 40) (PPED.suffixifiedPPE ppe) typ
  renderedTypes <- for matchingHoverInfos \info -> do
    case info of
      BuiltinType txt -> pure txt
      LocalVar _v -> pure $ "<local>"
      FileDef v ->
        pure . maybe "<file>" renderType $
          termSummary ^? ix v . _3 . _Just
            <|> testWatchSummary ^? folded . filteredBy (_1 . _Just . only v) . _4 . _Just
            <|> exprWatchSummary ^? folded . filteredBy (_1 . _Just . only v) . _4 . _Just
      Ref ref -> do
        Env {codebase} <- ask
        typ <- MaybeT . liftIO $ Codebase.getTypeOfReferent codebase ref
        pure $ renderType typ
  Debug.debugM Debug.LSP "Rendered" renderedTypes
  -- Due to the way hover info is computed, there should be at most one.
  typ <- MaybeT . pure $ safeHead renderedTypes
  let typeSig = case listToMaybe matchingLexeme of
        Just (Lex.WordyId n _) -> Text.pack n <> " : " <> typ
        Just (Lex.SymbolyId n _) -> Text.pack n <> " : " <> typ
        -- TODO: add other lexemes
        _ -> ": " <> typ
  pure $ Text.unlines ["```unison", typeSig, "```"]

mkSubTermMap :: (Parser.Annotated a, Show a) => Map Symbol a -> UF.TypecheckedUnisonFile Symbol a -> IM.IntervalMap Position [HoverInfo]
mkSubTermMap fileDefs (UF.TypecheckedUnisonFileId {hashTermsId}) =
  hashTermsId ^@.. (folded . _3 . subTerms . (reindexed ABT.annotation selfIndex) <. termHoverInfo fileDefs)
    & Debug.debug Debug.LSP "Cosmos'd"
    & map (\(a, info) -> IM.singleton <$> annToInterval (Parser.ann a) <*> pure [info])
    & Debug.debug Debug.LSP "Converted1"
    & mapMaybe Prelude.id
    & Debug.debug Debug.LSP "Converted2"
    & IM.unionsWith (<>)

subTerms :: Fold (Term.Term v a) (Term.Term v a)
subTerms =
  cosmosOf (to ABT.out . folded)

data HoverInfo
  = BuiltinType Text
  | LocalVar Symbol
  | FileDef Symbol
  | Ref Referent
  deriving stock (Show, Eq, Ord)

termHoverInfo :: (Map Symbol a) -> Fold (Term.Term Symbol a) HoverInfo
termHoverInfo fileDefs = folding \term ->
  case ABT.out term of
    ABT.Tm f -> case f of
      Term.Int {} -> Just (BuiltinType "Int")
      Term.Nat {} -> Just (BuiltinType "Nat")
      Term.Float {} -> Just (BuiltinType "Float")
      Term.Boolean {} -> Just (BuiltinType "Boolean")
      Term.Text {} -> Just (BuiltinType "Text")
      Term.Char {} -> Just (BuiltinType "Char")
      Term.Blank {} -> Nothing
      Term.Ref ref -> Just (Ref $ Referent.Ref ref)
      Term.Constructor cRef -> Just (Ref $ Referent.Con cRef CT.Data)
      Term.Request cRef -> Just (Ref $ Referent.Con cRef CT.Effect)
      Term.Handle {} -> Nothing
      Term.App {} -> Nothing
      Term.Ann {} -> Nothing
      Term.List {} -> Nothing
      Term.If {} -> Nothing
      Term.And {} -> Nothing
      Term.Or {} -> Nothing
      Term.Lam {} -> Nothing
      Term.LetRec {} -> Nothing
      Term.Let {} -> Nothing
      Term.Match {} -> Nothing
      Term.TermLink {} -> Nothing
      Term.TypeLink {} -> Nothing
    ABT.Var v ->
      case Map.lookup v fileDefs of
        Nothing -> Just (LocalVar v)
        Just _ -> Just (FileDef v)
    _ -> Nothing
