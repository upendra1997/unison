module Unison.CommandLine.FZFResolvers
  ( FZFResolver (..),
    definitionOptions,
    termDefinitionOptions,
    typeDefinitionOptions,
    namespaceOptions,
    projectNameOptions,
    projectBranchOptions,
    projectBranchOptionsWithinCurrentProject,
    fuzzySelectFromList,
    multiResolver,
  )
where

import Control.Lens
import Data.List.Extra qualified as List
import Data.Set qualified as Set
import U.Codebase.Sqlite.Project as SqliteProject
import U.Codebase.Sqlite.Queries qualified as Q
import Unison.Codebase (Codebase)
import Unison.Codebase qualified as Codebase
import Unison.Codebase.Branch (Branch0)
import Unison.Codebase.Branch qualified as Branch
import Unison.Codebase.Path (Path, Path' (..))
import Unison.Codebase.Path qualified as Path
import Unison.Name qualified as Name
import Unison.Names qualified as Names
import Unison.Parser.Ann (Ann)
import Unison.Position (Position (..))
import Unison.Prelude
import Unison.Project.Util (ProjectContext (..))
import Unison.Symbol (Symbol)
import Unison.Syntax.HashQualified qualified as HQ (toText)
import Unison.Util.Monoid (foldMapM)
import Unison.Util.Monoid qualified as Monoid
import Unison.Util.Relation qualified as Relation

type OptionFetcher = Codebase IO Symbol Ann -> ProjectContext -> Branch0 IO -> IO [Text]

data FZFResolver = FZFResolver
  { argDescription :: Text,
    getOptions :: OptionFetcher
  }

instance Show FZFResolver where
  show _ = "<FZFResolver>"

-- | Select a definition from the given branch.
-- Returned names will match the provided 'Position' type.
genericDefinitionOptions :: Bool -> Bool -> Position -> OptionFetcher
genericDefinitionOptions includeTerms includeTypes pos _codebase _projCtx searchBranch0 = liftIO do
  let termsAndTypes =
        Monoid.whenM includeTerms Relation.dom (Names.hashQualifyTermsRelation (Relation.swap $ Branch.deepTerms searchBranch0))
          <> Monoid.whenM includeTypes Relation.dom (Names.hashQualifyTypesRelation (Relation.swap $ Branch.deepTypes searchBranch0))
  termsAndTypes
    & Set.toList
    & map (HQ.toText . fmap (Name.setPosition pos))
    & pure

-- | Select a definition from the given branch.
-- Returned names will match the provided 'Position' type.
definitionOptions :: Position -> OptionFetcher
definitionOptions = genericDefinitionOptions True True

-- | Select a term definition from the given branch.
-- Returned names will match the provided 'Position' type.
termDefinitionOptions :: Position -> OptionFetcher
termDefinitionOptions = genericDefinitionOptions True False

-- | Select a type definition from the given branch.
-- Returned names will match the provided 'Position' type.
typeDefinitionOptions :: Position -> OptionFetcher
typeDefinitionOptions = genericDefinitionOptions False True

-- | Select a namespace from the given branch.
-- Returned Path's will match the provided 'Position' type.
namespaceOptions :: Position -> OptionFetcher
namespaceOptions pos _codebase _projCtx searchBranch0 = do
  let intoPath' :: Path -> Path'
      intoPath' = case pos of
        Relative -> Path' . Right . Path.Relative
        Absolute -> Path' . Left . Path.Absolute
  searchBranch0
    & Branch.deepPaths
    & Set.delete (Path.empty {- The current path just renders as an empty string which isn't a valid arg -})
    & Set.toList
    & map (Path.toText' . intoPath')
    & pure

-- | Select a namespace from the given branch.
-- Returned Path's will match the provided 'Position' type.
fuzzySelectFromList :: Text -> [Text] -> FZFResolver
fuzzySelectFromList argDescription options =
  (FZFResolver {argDescription, getOptions = \_codebase _projCtx _branch -> pure options})

-- | Combine multiple option fetchers into one resolver.
multiResolver :: Text -> [OptionFetcher] -> FZFResolver
multiResolver argDescription resolvers =
  let getOptions :: Codebase IO Symbol Ann -> ProjectContext -> Branch0 IO -> IO [Text]
      getOptions codebase projCtx searchBranch0 = do
        List.nubOrd <$> foldMapM (\f -> f codebase projCtx searchBranch0) resolvers
   in (FZFResolver {argDescription, getOptions})

-- | All possible local project names
-- E.g. '@unison/base'
projectNameOptions :: OptionFetcher
projectNameOptions codebase _projCtx _searchBranch0 = do
  fmap (into @Text . SqliteProject.name) <$> Codebase.runTransaction codebase Q.loadAllProjects

-- | All possible local project/branch names.
-- E.g. '@unison/base/main'
projectBranchOptions :: OptionFetcher
projectBranchOptions codebase _projCtx _searchBranch0 = do
  Codebase.runTransaction codebase Q.loadAllProjectBranchNamePairs
    <&> fmap (into @Text . fst)

-- | All possible local branch names within the current project.
-- E.g. '@unison/base/main'
projectBranchOptionsWithinCurrentProject :: OptionFetcher
projectBranchOptionsWithinCurrentProject codebase projCtx _searchBranch0 = do
  case projCtx of
    LooseCodePath _ -> pure []
    ProjectBranchPath currentProjectId _projectBranchId _path -> do
      Codebase.runTransaction codebase (Q.loadAllProjectBranchesBeginningWith currentProjectId Nothing)
        <&> fmap (into @Text . snd)
