{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}

module Pact.Core.Typed.Renamer where

import Control.Lens hiding (ix)
import Control.Monad.Reader
import Data.Text(Text)
import Data.Map.Strict(Map)
import qualified Data.Map.Strict as Map
import qualified Data.List.NonEmpty as NE

import Pact.Core.Type
import Pact.Core.Names
import Pact.Core.Typed.Term

data RenamerState
  = RenamerState
  { _rnArgBinds :: Map Text DeBruijn
  , _rnTyBinds :: Map Unique DeBruijn
  , _rnArgDepth :: DeBruijn
  , _rnTyDepth :: DeBruijn
  } deriving Show

makeLenses ''RenamerState

type RenamerT m = ReaderT RenamerState m

lamNameToDebruijn :: DeBruijn -> IRName -> Name
lamNameToDebruijn dix (IRName n nk _) = Name n $ case nk of
  IRLocallyBoundName -> LocallyBoundName dix
  _ -> undefined

tnToDebruijn :: DeBruijn -> TypeName -> NamedDeBruijn
tnToDebruijn dix tn = NamedDeBruijn dix (_tyname tn)

renameTerm :: Monad m => Term IRName TypeName b i -> RenamerT m (Term Name NamedDeBruijn b i)
renameTerm = \case
  Var n i -> case _irNameKind n of
    IRLocallyBoundName -> do
      depth <- view rnArgDepth
      views rnArgBinds (Map.lookup (_irName n)) >>= \case
        Just db -> do
          let n' = Name (_irName n) (LocallyBoundName (depth - db))
          pure (Var n' i)
        Nothing -> error "unbound local"
    _ -> error "todo: support tl names and module names"
  Lam n nts body i -> do
    depth <- view rnArgDepth
    let (ns, tys) = NE.unzip nts
        names = _irName <$> ns
        len = fromIntegral $ NE.length ns
        newDepth = depth + len
        ixs = NE.fromList [depth + 1.. newDepth]
        m = Map.fromList $ NE.toList $ NE.zip names ixs
        n' = lamNameToDebruijn 0 n
        ns' = NE.zipWith (\irn ix -> lamNameToDebruijn (newDepth - ix) irn) ns ixs
    tys' <- traverse renameType tys
    body' <- varsInEnv m newDepth $ renameTerm body
    pure (Lam n' (NE.zip ns' tys') body' i)
  App l nel i ->
    App <$> renameTerm l <*> traverse renameTerm nel <*> pure i
  Let n e1 e2 i -> do
    e1' <- renameTerm e1
    let n0 = lamNameToDebruijn 0 n
    e2' <- varInEnv (_irName n) $ renameTerm e2
    pure (Let n0 e1' e2' i)
  TyApp e tyapps i -> do
    e' <- renameTerm e
    tyapps' <- (traversed._1) renameType tyapps
    pure (TyApp e' tyapps' i)
  TyAbs tyabs e i -> do
    depth <- view rnTyDepth
    let tynames = _tynameUnique . fst <$> tyabs
        len = fromIntegral $ NE.length tynames
        newDepth = depth + len
        ixs = NE.fromList [depth + 1 .. newDepth]
        m = Map.fromList $ NE.toList $ NE.zip tynames ixs
        tyabs' = NE.zipWith (\o ix -> over _1 (tnToDebruijn (newDepth - ix)) o) tyabs ixs
    e' <- tyVarsInEnv m newDepth $ renameTerm e
    pure (TyAbs tyabs' e' i)
  Block nel i ->
    Block <$> traverse renameTerm nel <*> pure i
  ObjectLit obj i ->
    ObjectLit <$> traverse renameTerm obj <*> pure i
  ListLit t li i ->
    ListLit <$> renameType t <*> traverse renameTerm li <*> pure i
  Error e t i ->
    Error e <$> renameType t <*> pure i
  Builtin b i -> pure (Builtin b i)
  Constant l i -> pure (Constant l i)
  where
  tyVarsInEnv m newDepth = local (set rnTyDepth newDepth . over rnTyBinds (Map.union m))
  varInEnv n = local $ \env ->
    let newD = _rnArgDepth env + 1
    in set rnArgDepth newD $ over rnArgBinds (Map.insert n newD) env
  varsInEnv m newDepth = local (set rnArgDepth newDepth . over rnArgBinds (Map.union m))

renameType :: Monad m => Type TypeName -> RenamerT m (Type NamedDeBruijn)
renameType = \case
  TyVar n -> do
    depth <- view rnTyDepth
    views rnTyBinds (Map.lookup (_tynameUnique n)) >>= \case
      Just d -> pure (TyVar (tnToDebruijn (depth - d) n))
      Nothing -> error "found unbound type var"
  TyPrim p -> pure (TyPrim p)
  TyFun l r ->
    TyFun <$> renameType l <*> renameType r
  TyRow r ->
    TyRow <$> renameRow r
  TyList t -> TyList <$> renameType t
  TyTable t -> TyTable <$> renameRow t
  TyCap -> pure TyCap
  TyForall ts rs ty -> do
    depth <- view rnTyDepth
    let newDepth = depth + fromIntegral (length ts) + fromIntegral (length rs)
        ixs = [depth + 1 .. newDepth]
        m = Map.fromList $ zip (_tynameUnique <$> (ts ++ rs)) ixs
        dbTy tn ix = tnToDebruijn (newDepth - ix) tn
        ts' = zipWith dbTy ts ixs
        rs' = zipWith dbTy rs (drop (length ts) ixs)
    ty' <- locally rnTyBinds (Map.union m) $ local (set rnTyDepth newDepth) $ renameType ty
    pure (TyForall ts' rs' ty')
  where
  renameRow EmptyRow = pure EmptyRow
  renameRow (RowVar n) = do
    depth <- view rnTyDepth
    views rnTyBinds (Map.lookup (_tynameUnique n)) >>= \case
      Just d -> pure (RowVar (tnToDebruijn (depth - d) n))
      Nothing -> error "found unbound row var"
  renameRow (RowTy obj (Just n)) = do
    depth <- view rnTyDepth
    views rnTyBinds (Map.lookup (_tynameUnique n)) >>= \case
      Just d -> RowTy <$> traverse renameType obj <*> pure (Just (tnToDebruijn (depth - d) n))
      Nothing -> error "found unbound type var"
  renameRow (RowTy obj Nothing) =
    RowTy <$> traverse renameType obj <*> pure Nothing
