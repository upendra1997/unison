{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DataKinds #-}

module Unison.Codebase.SqliteCodebase.MigrateSchema12 where

import Unison.Prelude
import Control.Monad.Reader (MonadReader)
import Control.Monad.State (MonadState)
import U.Codebase.Sqlite.Connection (Connection)
import U.Codebase.Sqlite.DbId (CausalHashId, HashId, ObjectId)
import U.Codebase.Sqlite.ObjectType (ObjectType)
import qualified U.Codebase.Sqlite.ObjectType as OT
import qualified U.Codebase.Sqlite.Queries as Q
import qualified U.Codebase.Sqlite.Reference as S.Reference
import U.Codebase.Sync (Sync (Sync))
import qualified U.Codebase.Sync as Sync
import qualified U.Codebase.WatchKind as WK
import Unison.Prelude (ByteString, Map, MonadIO)
import Unison.Reference (Pos)
import Unison.Referent (ConstructorId)
import Data.Set (Set)
import qualified U.Codebase.Sqlite.Operations as Ops
import qualified Unison.Reference as Reference
import qualified Unison.Referent as Referent
import Unison.Codebase (Codebase (Codebase))
import qualified Unison.DataDeclaration as DD
import qualified Unison.Codebase as Codebase
import qualified Unison.Codebase.SqliteCodebase.Conversions as Cv
import qualified Data.Map as Map
import Unison.Type (Type)
import qualified Unison.ABT as ABT
import Control.Monad.Trans.Writer.CPS (WriterT)
import qualified Unison.Type as Type
import qualified Data.List as List
import Control.Lens
import Control.Monad.State.Strict
import Control.Monad.Except (runExceptT, ExceptT)
import Control.Monad.Trans.Except (throwE)
import Data.Either.Extra (maybeToEither)
import Data.Generics.Product
import Data.Generics.Sum
import qualified Unison.Hash as Unison
import qualified Unison.Hashing.V2.Convert as Convert

-- lookupCtor :: ConstructorMapping -> ObjectId -> Pos -> ConstructorId -> Maybe (Pos, ConstructorId)
-- lookupCtor (ConstructorMapping cm) oid pos cid =
--   Map.lookup oid cm >>= (Vector.!? fromIntegral pos) >>= (Vector.!? cid)

-- lookupTermRef :: TermLookup -> S.Reference -> Maybe S.Reference
-- lookupTermRef _tl (ReferenceBuiltin t) = Just (ReferenceBuiltin t)
-- lookupTermRef tl (ReferenceDerived id) = ReferenceDerived <$> lookupTermRefId tl id

-- lookupTermRefId :: TermLookup -> S.Reference.Id -> Maybe S.Reference.Id
-- lookupTermRefId tl (Id oid pos) = Id oid <$> lookupTermPos tl oid pos

-- lookupTermPos :: TermLookup -> ObjectId -> Pos -> Maybe Pos
-- lookupTermPos (TermLookup tl) oid pos = Map.lookup oid tl >>= (Vector.!? fromIntegral pos)

-- newtype ConstructorMapping = ConstructorMapping (Map ObjectId (Vector (Vector (Pos, ConstructorId))))
-- newtype TermLookup = TermLookup (Map ObjectId (Vector Pos))

type TypeIdentifier = (ObjectId, Pos)
type Old a = a
type New a = a
data MigrationState = MigrationState
  -- Mapping between old cycle-position -> new cycle-position for a given Decl object.
  { -- declLookup :: Map (Old ObjectId) (Map (Old Pos) (New Pos)),
    declLookup :: Map (Old Reference.Id) (New Reference.Id),
    -- Mapping between contructor indexes for the type identified by (ObjectId, Pos)
    ctorLookup :: Map (Old TypeIdentifier) (Map (Old ConstructorId) (New ConstructorId)),
    ctorLookup' :: Map (Old Referent.Id) (New Referent.Id),
    -- This provides the info needed for rewriting a term.  You'll access it with a function :: Old
    termLookup :: Map (Old ObjectId) (New ObjectId, Map (Old Pos) (New Pos)),
    objLookup :: Map (Old ObjectId) (New ObjectId),

    --
    componentPositionMapping :: Map ObjectId (Map (Old Pos) (New Pos)),
    constructorIDMapping :: Map ObjectId (Map (Old ConstructorId) (New ConstructorId)),
    completed :: Set ObjectId
  } deriving Generic

  -- declLookup :: Map ObjectId (Map Pos (Pos, Map ConstructorId ConstructorId)),

{-
* Load entire codebase as a list
* Pick a term from the codebase
* Look up the references inside the term
* If any haven't been processed, add them to the "to process" stack, push the term you were working on back onto that stack
* Rebuild & rehash the term, store that
* For any data constructor terms inside,
  * Store a map from old ConstructorId to new, based on the old and new reference hashes
* After rebuilding a cycle, map old Pos to new
-}

-- Q: can we plan to hold the whole mapping in memory? ✅
-- Q: a) update database in-place? or b) write to separate database and then overwrite? leaning (b).
-- note: we do need to rebuild namespaces, although we don't need to rehash them.

-- cycle position index `Pos`
-- constructor index `ConstructorId`

{-
data Maybe a = (Just Bar | Nothing X)

-- changes due to missing size from ref(Y)
data X = MkX Y

-- know old hash and old cycle positions
data Y = MkY Int
-}

data Entity'
  = TComponent Unison.Hash
  | DComponent Unison.Hash
  | Patch ObjectId
  | NS ObjectId
  | C CausalHashId
  | W WK.WatchKind S.Reference.IdH -- Hash Reference.Id
  deriving (Eq, Ord, Show)


-- data Entity
--   = O ObjectId -- Hash
--   | C CausalHashId
--   | W WK.WatchKind S.Reference.IdH -- Hash Reference.Id
--   deriving (Eq, Ord, Show)

data Env = Env {db :: Connection}

--  -> m (TrySyncResult h)
migrationSync ::
  (MonadIO m, MonadState MigrationState m, MonadReader Env m) =>
  Sync m Entity
migrationSync = Sync \case
  -- To sync an object,
  --   * If we have already synced it, we are done.
  --   * Otherwise, read the object from the database and switch on its object type.
  --   * See next steps below v
  --
  -- To sync a decl component object,
  --   * If we have not already synced all dependencies, push syncing them onto the front of the work queue.
  --   * Otherwise, ???
  --
  -- To sync a term component object,
  --   * If we have not already synced all dependencies, push syncing them onto the front of the work queue.
  --   * Otherwise, ???
  --
  -- To sync a namespace object,
  --   * Deserialize it and compute its dependencies (terms, types, patches, children).
  --   * If we have not already synced all of its dependencies, push syncing them onto the front of the work queue.
  --   * To sync a 'BranchFull',
  --     * We need to make a new 'BranchFull' in memory, then insert it into the database under a new object id.
  --       * Wait, we need to preserve the ordering of the types/terms, either by not changing them (but the orderings of the
  --         reference ids used in keys is definitely not preserved by this migration), or by permuting the local id vectors,
  --         but we may be at a level too low or high for us to care?
  --     * Its 'LocalBranch' must have all references changed in-place per the (old (object id, pos) => new (object id, pos)) mapping.
  --     * The local IDs within the body _likely_ don't need to change. (why likely?)
  --     * Its 'BranchLocalIds' must be translated from the old codebase object IDs to the new object IDs,
  --       we can use our MigrationState to look these up, since they must have already been migrated.
  --   * To sync a 'BranchDiff',
  --     * These don't exist in schema v1; we can error if we encounter one.
  --
  -- To sync a patch object
  --   * Rewrite all old hashes in the patch to the new hashes.
  --
  -- To sync a watch expression
  --   * ???
  --
  -- To sync a Causal
  --- * If we haven't yet synced its parents, push them onto the work queue
  --- * If we haven't yet synced the causal's value (namespace), push it onto the work queue.
  --- * Rehash the Causal's valueHash AND CausalHash, and add the new causal, its hashes, and hash objects to the codebase under a fresh object ID
  O objId -> do
    let alreadySynced :: m Bool
        alreadySynced = undefined
    alreadySynced >>= \case
      False -> do
        (hId, objType, bytes) <- runSrc $ Q.loadObjectWithHashIdAndTypeById oId
        migrateObject objType hId bytes
      True -> pure Sync.PreviouslyDone
  -- result <- runValidateT @(Set Entity) @m @ObjectId case objType of
  -- To sync a causal,
  --   1. ???
  --   2. Synced
  C causalHashID -> undefined
  -- To sync a watch result,
  --   1. ???
  --   2. Synced
  W watchKind idH -> undefined

-- data ObjectType
--   = TermComponent -- 0
--   | DeclComponent -- 1
--   | Namespace -- 2
--   | Patch -- 3

migrateObject :: Codebase m v a -> ObjectType -> HashId -> ByteString -> m _
migrateObject codebase objType hash bytes = case objType of
  OT.TermComponent -> migrateTermComponent hash bytes
  OT.DeclComponent -> migrateDeclComponent codebase hash
  OT.Namespace -> migrateNamespace hash bytes
  OT.Patch -> migratePatch hash bytes

migratePatch :: HashId -> ByteString -> m _
migratePatch = error "not implemented"

migrateNamespace :: HashId -> ByteString -> m _
migrateNamespace = error "not implemented"

migrateTermComponent :: HashId -> ByteString -> m _
migrateTermComponent = error "not implemented"

migrateDeclComponent :: forall m v a. Codebase m v a -> Unison.Hash -> m (Sync.TrySyncResult Entity')
migrateDeclComponent Codebase{..} hash = fmap (either id id) . runExceptT $ do
  declComponent :: [DD.Decl v a] <- lift (getDeclComponent hash) >>= \case
    Nothing -> error "handle this" -- not non-fatal!
    Just dc -> pure dc

  -- type Decl = Either EffectDeclaration DataDeclaration
  let componentIDMap :: Map Reference.Id (DD.Decl v a)
      componentIDMap = Map.fromList $ Reference.componentFor hash declComponent

  let unhashed :: Map Reference.Id (v, DD.Decl v a)
      unhashed = DD.unhashComponent componentIDMap
--  data DataDeclaration v a = DataDeclaration {
--   modifier :: Modifier,
--   annotation :: a,
--   bound :: [v],
--   constructors' :: [(a, v, Type v a)]
-- } deriving (Eq, Show, Functor)

  let allTypes :: [Type v a]
      allTypes =
        unhashed
        ^.. traversed
        . _2
        . beside asDataDecl_ id
        . to DD.constructors'
        . traversed
        . _3

  let allContainedReferences :: [Reference.Id]
      allContainedReferences = foldMap (ABT.find findReferenceIds) allTypes
  -- unmigratedIds :: [Reference.Id]
  declMap <- gets declLookup
  let unmigratedIds :: [Reference.Id]
      unmigratedIds = filter (\ref -> not (Map.member ref declMap)) allContainedReferences
  when (not . null $ unmigratedIds) do
    let unmigratedHashes :: [Unison.Hash]
        unmigratedHashes =
          nubOrd (map Reference.idToHash unmigratedIds)
    throwE (Sync.Missing (map DComponent unmigratedHashes))

  -- At this point we know we have all the required mappings from old references  to new ones.
  let remapTerm :: Type v a -> Type v a
      remapTerm typ = runIdentity $ ABT.visit' (remapReferences declMap) typ

  let remappedReferences :: Map (Old Reference.Id) (v, DD.Decl v a)
      remappedReferences = unhashed
               & traversed -- Traverse map of reference IDs
               . _2 -- Select the DataDeclaration
               . beside DD.asDataDecl_ id -- Unpack effect decls
               . DD.constructors_ -- Get the data constructors
               . traversed -- traverse the list of them
               . _3 -- Select the Type term.
               %~ remapTerm
  let vToOldReference :: Map v (Old Reference.Id)
      vToOldReference = Map.fromList . fmap swap . Map.toList . fmap fst $ remappedReferences

  -- hashDecls ::
  -- Var v =>
  -- Map v (Memory.DD.DataDeclaration v a) ->
  -- ResolutionResult v a [(v, Memory.Reference.Id, Memory.DD.DataDeclaration v a)]

  let newComponent :: ([(v, Reference.Id, DD.DataDeclaration v a)])
      newComponent = Convert.hashDecls (Map.fromList $ Map.elems remappedReferences)
  for newComponent $ \(v, newReferenceId, dd) -> do
    field @"declLookup" %= Map.insert (vToReference Map.! v) newReferenceId
    putTypeDeclaration newReference (_ d)
  pure Sync.Done


structural type Ping x = P1 (Pong x)
  P1 : forall x. Pong x -> Ping x

structural type Pong x = P2 (Ping x) | P3 Nat
  P2 : forall x. Ping x -> Pong x
  P3 : forall x. Nat -> Pong x




end up with
decl Ping (Ref.Id #abc pos=0)
decl Pong (Ref.Id #abc pos=1)
ctor P1: #abc pos=0 cid=0
ctor P2: #abc pos=1 cid=0
ctor P3: #abc pos=1 cid=1

we unhashComponent and get:
{ X -> structural type X x = AAA (Y x)
, Y -> structural type Y x = BBB (X x) | CCC Nat }








remapReferences :: Map (Old Reference.Id) (New Reference.Id)
                -> Type.F (Type v a)
                -> Identity Type.F (Type v a)
remapReferences declMap = \case
  (Type.Ref (Reference.DerivedId refId)) ->
    fromMaybe
      (error $ "Expected reference to exist in decl mapping, but it wasn't found: " <> show refId)
      (Sync.Missing [DComponent Reference.idToHash refId]) (Map.lookup refId declMap)
  x -> pure x



-- get references:
--
--   references :: Term f v a -> [Reference.Id]
--
-- are all those references keys in our skymap?
--   yes => migrate term
--   no => returh those references (as Entity, though) as more work to do

-- how to turn Reference.Id into Entity?
--   need its ObjectId,

-- Term f v a -> ValidateT (Seq Reference.Id) m (Term f v a)
--
-- recordRefsInType :: MonadState MigrationState m => Type v a -> WriterT [Reference.Id] m (Type v a)
-- recordRefsInType = _

findReferenceIds :: Type v a -> ABT.FindAction Reference.Id
findReferenceIds = ABT.out >>> \case
  ABT.Tm (Type.Ref (Reference.DerivedId r)) -> ABT.Found r
  x -> ABT.Continue




-- data DataDeclaration v a = DataDeclaration {
--   modifier :: Modifier,
--   annotation :: a,
--   bound :: [v],
--   constructors' :: [(a, v, Type v a)]
-- } deriving (Eq, Show, Functor)


-- compute correspondence between `v`s in `fst <$> named` compared to `fst <$> new_references` to get a Reference.Id -> Reference.Id mapping
-- mitchell tapped out before understanding the following line
-- compute correspondence between constructors names & constructor indices in corresponding decls
-- submit/mappend these two correspondences to sky mapping

-- Swap the Reference positions according to our map of already computed swaps
-- Hydrate into the parser-typechecker version, get the new hash
-- reserialize it into the sqlite format
-- Compare the old and new sqlite versions to add those ConstructorID/Pos mappings to our context.

-- unrelated Q:
--   do we kinda have circular dependency issues here?
--   parser-typechecker depends on codebase2, but we are talking about doing things at the parser-typechecker level in this migration
--   answer: no

  -- unhashComponent
  -- :: forall v a. Var v => Map Reference.Id (Decl v a) -> Map Reference.Id (v, Decl v a)

  -- DD.unhashComponent


  -- [OldDecl] ==map==> [NewDecl] ==number==> [(NewDecl, Int)] ==sort==> [(NewDecl, Int)] ==> permutation is map snd of that


-- type List a = Nil | Cons (List a)

-- unique type Thunk = Thunk (Int ->{MakeThunk} Int)
-- ability MakeThunk where go : (Int -> Int) -> Thunk

-- What mitchell thinks unhashComponent is doing:
--
--  Take a recursive type like
--
--     Fix \myself -> Alternatives [Nil, Cons a myself]
--
--  And write it with variables in place of recursive mentions like
--
--     (Var 1, Alternatives [Nil, Cons a (Var 1)]

-- can derive `original` from Hash + [OldDecl]
-- original :: Map Reference.Id (Decl v a)

-- named, rewritten_dependencies :: Map (Reference.Id {old}) (v, Decl v a {old pos in references})
-- named = Decl.unhashComponent original

-- Mapping from the sky: (Reference.Id -> Reference.Id)

-- rewritten_dependencies = replace_dependency_pos's skymap named

-- new_references :: Map v (Reference.Id {new}, DataDeclaration v a)
-- new_references = Unison.Hashing.V2.Convert.hashDecls $ Map.toList $ Foldable.toList rewritten_dependencies





  -- let DeclFormat locallyIndexedComponent = case runGetS S.getDeclFormat declFormatBytes of
  --   Left err -> error "something went wrong"
  --   Right declFormat -> declFormat

  -- Operations.hs converts from S level to C level
  -- SqliteCodebase.hs converts from C level to


-- | migrate sqlite codebase from version 1 to 2, return False and rollback on failure
migrateSchema12 :: Applicative m => Connection -> m Bool
migrateSchema12 db = do
  -- todo: drop and recreate corrected type/mentions index schema
  -- do we want to garbage collect at this time? ✅
  -- or just convert everything without going in dependency order? ✅
  error "todo: go through "
  -- todo: double-hash all the types and produce an constructor mapping
  -- object ids will stay the same
  -- todo: rehash all the terms using the new constructor mapping
  -- and adding the type to the term
  -- do we want to diff namespaces at this time? ❌
  -- do we want to look at supporting multiple simultaneous representations of objects at this time?
  pure "todo: migrate12"
  pure True

-- -- remember that the component order might be different
-- rehashDeclComponent :: [Decl v a] -> (Hash, ConstructorMappings)
-- rehashDeclComponent decls = fmap decls <&> \case
--
--     --
--     error "todo: rehashDeclComponent"

-- rewriteDeclComponent :: DeclFormat.LocallyIndexedComponent -> (Hash, DeclFormat.LocallyIndexedComponent, ConstructorMappings)
-- rewriteDeclComponent =
--     --
--     error "todo: rehashDeclComponent"

-- rehashDeclComponent :: [Decl v a] -> (Hash, DeclFormat.LocallyIndexedComponent, ConstructorMappings)

-- rehashTermComponent :: ConstructorMappings -> TermFormat.LocallyIndexedComponent -> (Hash, TermFormat.LocallyIndexedComponent)
-- rehashTermComponent = error "todo: rehashTermComponent"

-- -- getConstructor :: ConstructorMappings -> ObjectId -> Pos -> ConstructorId
-- -- getConstructor cm
