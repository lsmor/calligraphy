{-# LANGUAGE ScopedTypeVariables #-}

module Filter (filterModules, FilterConfig, pFilterConfig, FilterError (..)) where

import Control.Monad.State
import Data.EnumMap (EnumMap)
import Data.EnumMap qualified as EnumMap
import Data.EnumSet (EnumSet)
import Data.EnumSet qualified as EnumSet
import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty, nonEmpty)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Maybe (catMaybes)
import Data.Monoid
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Tree
import Data.Tuple (swap)
import Options.Applicative
import Parse
import Prelude hiding (filter)

data FilterConfig = FilterConfig
  { onlyExports :: Bool,
    depRoot :: Maybe (NonEmpty String),
    revDepRoot :: Maybe (NonEmpty String),
    depDepth :: Maybe Int
  }

resolveNames :: Forest Decl -> Map String (EnumSet Key)
resolveNames forest =
  flip execState mempty $
    flip (traverse . traverse) forest $
      \(Decl name key _ _) -> modify (Map.insertWith (<>) name (EnumSet.singleton key))

transitives :: forall a. Enum a => Maybe Int -> [a] -> Set (a, a) -> EnumSet a
transitives maxDepth roots deps = go 0 mempty (EnumSet.fromList roots)
  where
    go :: Int -> EnumSet a -> EnumSet a -> EnumSet a
    go depth old new
      | EnumSet.null new = old
      | maybe False (< depth) maxDepth = old
      | otherwise =
        let old' = old <> new
            new' = EnumSet.foldr (\a -> maybe id mappend $ EnumMap.lookup a adjacencies) mempty new
         in go (depth + 1) old' (new' EnumSet.\\ old')
    adjacencies :: EnumMap a (EnumSet a)
    adjacencies = foldr (\(from, to) -> EnumMap.insertWith (<>) from (EnumSet.singleton to)) mempty deps

newtype FilterError = UnknownRootName String

filterModules :: FilterConfig -> Modules -> Either FilterError Modules
filterModules (FilterConfig exps mfw mbw maxDepth) (Modules modules calls) = do
  fwFilter <- forM mfw $ flip mkDepFilter calls
  bwFilter <- forM mbw $ flip mkDepFilter (Set.map swap calls)
  let depFilter = case (fwFilter, bwFilter) of
        (Nothing, Nothing) -> const True
        (Just fa, Nothing) -> fa
        (Nothing, Just fb) -> fb
        (Just fa, Just fb) -> \decl -> fa decl || fb decl
  let p decl = exportFilter decl && depFilter decl
      (modules', filteredKeys) = runState ((traverse . traverse . traverse) (filterTree p) modules) mempty
      calls' = Set.filter (\(a, b) -> EnumSet.member a filteredKeys && EnumSet.member b filteredKeys) calls
  pure $ Modules ((fmap . fmap) catMaybes modules') calls'
  where
    -- parentChildEdges :: Set (Key, Key)
    -- parentChildEdges = execState ((mapM_ . mapM_ . mapM_) (go . fmap declKey) modules) mempty
    --   where
    --     go :: Tree Key -> State (Set (Key, Key)) ()
    --     go (Node parent children) = do
    --       forM_ children $ \(Node child _) -> modify (Set.insert (parent, child))
    --       mapM_ go children
    names :: Map String (EnumSet Key)
    names = resolveNames (modules >>= snd)
    mkDepFilter :: NonEmpty String -> Set (Key, Key) -> Either FilterError (Decl -> Bool)
    mkDepFilter rootNames edges = do
      rootKeys <- forM rootNames $ \name -> maybe (Left $ UnknownRootName name) (pure . EnumSet.toList) (Map.lookup name names)
      let ins = transitives maxDepth (mconcat $ toList rootKeys) edges
      pure $ \decl -> EnumSet.member (declKey decl) ins
    exportFilter :: Decl -> Bool
    exportFilter
      | exps = declExported
      | otherwise = const True
    filterTree :: (Decl -> Bool) -> Tree Decl -> State (EnumSet Key) (Maybe (Tree Decl))
    filterTree p = go
      where
        go :: Tree Decl -> State (EnumSet Key) (Maybe (Tree Decl))
        go (Node decl children) = do
          children' <- catMaybes <$> mapM go children
          if not (p decl) && null children'
            then pure Nothing
            else Just (Node decl children') <$ modify (EnumSet.insert (declKey decl))

pFilterConfig :: Parser FilterConfig
pFilterConfig =
  FilterConfig
    <$> switch (long "hide-local-bindings" <> long "exports-only" <> help "Don't draw non-exported bindings.")
    <*> (fmap nonEmpty . many) (strOption (long "forward-dep-root" <> short 'f' <> help "Dependency filter root. Will hide everything that's not a (transitive) dependency of this root. Can be repeated."))
    <*> (fmap nonEmpty . many) (strOption (long "reverse-dep-root" <> short 'r' <> help "Reverse dependency filter root. Will hide everything that's not a (transitive) reverse dependency of this root. Can be repeated."))
    <*> optional (option auto (long "max-depth" <> help "Maximum search depth for transitive dependencies."))
