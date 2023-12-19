module Unison.Codebase.Editor.HandleInput.AddRun
  ( handleAddRun,
  )
where

import Control.Lens (use)
import Control.Monad.Reader (ask)
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Unison.Cli.Monad (Cli)
import Unison.Cli.Monad qualified as Cli
import Unison.Cli.MonadUtils qualified as Cli
import Unison.Cli.NamesUtils (displayNames)
import Unison.Cli.PrettyPrintUtils (prettyPrintEnvDecl)
import Unison.Codebase qualified as Codebase
import Unison.Codebase.Branch.Names qualified as Branch
import Unison.Codebase.Editor.HandleInput.Update (doSlurpAdds)
import Unison.Codebase.Editor.Input (Input)
import Unison.Codebase.Editor.Output (Output (NoLastRunResult, SaveTermNameConflict, SlurpOutput))
import Unison.Codebase.Editor.Slurp qualified as Slurp
import Unison.Codebase.Editor.SlurpResult qualified as SlurpResult
import Unison.Codebase.Path qualified as Path
import Unison.CommandLine.InputPattern qualified as InputPattern
import Unison.CommandLine.InputPatterns qualified as InputPatterns
import Unison.Name (Name)
import Unison.Parser.Ann (Ann (External))
import Unison.Prelude
import Unison.PrettyPrintEnvDecl qualified as PPE
import Unison.Symbol (Symbol)
import Unison.Syntax.Name qualified as Name
import Unison.UnisonFile (TypecheckedUnisonFile)
import Unison.UnisonFile qualified as UF

handleAddRun :: Input -> Name -> Cli ()
handleAddRun input resultName = do
  let resultVar = Name.toVar resultName
  uf <- addSavedTermToUnisonFile resultName
  Cli.Env {codebase} <- ask
  currentPath <- Cli.getCurrentPath
  currentNames <- Branch.toNames <$> Cli.getCurrentBranch0
  let sr = Slurp.slurpFile uf (Set.singleton resultVar) Slurp.AddOp currentNames
  let adds = SlurpResult.adds sr
  Cli.stepAtNoSync (Path.unabsolute currentPath, doSlurpAdds adds uf)
  Cli.runTransaction . Codebase.addDefsToCodebase codebase . SlurpResult.filterUnisonFile sr $ uf
  ppe <- prettyPrintEnvDecl =<< displayNames uf
  Cli.syncRoot (Text.pack (InputPattern.patternName InputPatterns.saveExecuteResult) <> " " <> Name.toText resultName)
  Cli.respond $ SlurpOutput input (PPE.suffixifiedPPE ppe) sr

addSavedTermToUnisonFile :: Name -> Cli (TypecheckedUnisonFile Symbol Ann)
addSavedTermToUnisonFile resultName = do
  let resultSymbol = Name.toVar resultName
  (trm, typ, uf) <-
    use #lastRunResult >>= \case
      Nothing -> Cli.returnEarly NoLastRunResult
      Just x -> pure x
  case Map.lookup resultSymbol (UF.hashTermsId uf) of
    Just _ -> Cli.returnEarly (SaveTermNameConflict resultName)
    Nothing -> pure ()
  pure $
    UF.typecheckedUnisonFile
      (UF.dataDeclarationsId' uf)
      (UF.effectDeclarationsId' uf)
      ([(resultSymbol, External, trm, typ)] : UF.topLevelComponents' uf)
      (UF.watchComponents uf)
