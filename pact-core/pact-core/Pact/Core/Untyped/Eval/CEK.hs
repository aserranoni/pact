{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE ConstraintKinds #-}

-- |
-- Module      :  Pact.Core.IR.Typecheck
-- Copyright   :  (C) 2022 Kadena
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Jose Cardona <jose@kadena.io>
--
-- CEK Evaluator for untyped core.
--

module Pact.Core.Untyped.Eval.CEK
 ( CEKTLEnv
 , CEKEnv
 , CEKValue(..)
 , BuiltinFn(..)
 , CEKState(..)
 , CEKRuntime
 , runCEK
 , runCEKCorebuiltin
 , Cont(..)
 , coreBuiltinRuntime
 ) where

import Data.Bits
import Data.Decimal(roundTo', Decimal)
import Data.Text(Text)
import Data.Vector(Vector)
import Data.List.NonEmpty(NonEmpty(..))
import Data.Primitive(Array, indexArray)
import qualified Data.Map.Strict as Map
import qualified Data.RAList as RAList
import qualified Data.Vector as V
import qualified Data.Primitive.Array as Array
import qualified Data.Text as T

import Pact.Core.Names
import Pact.Core.Builtin
import Pact.Core.Literal

import Pact.Core.Untyped.Term
import Pact.Core.Untyped.Eval.Runtime

-- Todo: exception handling? do we want labels
-- Todo: `traverse` usage should be perf tested.
-- It might be worth making `Arg` frames incremental, as opposed to a traverse call
eval
  :: CEKRuntime b i
  => CEKEnv b i
  -> EvalTerm b i
  -> EvalT b (CEKValue b i)
eval = evalCEK Mt
  where
  evalCEK
    :: CEKRuntime b i
    => Cont b i
    -> CEKEnv b i
    -> EvalTerm b i
    -> EvalT b (CEKValue b i)
  evalCEK cont env (Var n _)  =
    case _nKind n of
      NBound i -> returnCEK cont (env RAList.!! i)
      -- Top level names are not closures, so we wipe the env
      NTopLevel mname mh ->
        let !t = ?cekLoaded Map.! FullyQualifiedName mname (_nName n) mh
        in evalCEK cont RAList.Nil t
  evalCEK cont _env (Constant l _)=
    returnCEK cont (VLiteral l)
  evalCEK cont env (App fn arg _) =
    evalCEK (Arg env arg cont) env fn
  evalCEK cont env (Lam body _) =
    returnCEK cont (VClosure body env)
  evalCEK cont _env (Builtin b _) =
    returnCEK cont (VNative (indexArray ?cekBuiltins (fromEnum b)))
  evalCEK cont env (ObjectLit obj _) = do
    vs <- traverse (evalCEK Mt env) obj
    returnCEK cont (VObject vs)
  evalCEK cont env (Block (t :| ts) _) =
    evalCEK (BlockC env ts cont) env t
  evalCEK cont env (ListLit ts _) = do
    ts' <- traverse (evalCEK Mt env) ts
    returnCEK cont (VList ts')
  evalCEK cont env (ObjectOp op _) = case op of
    ObjectAccess f o -> do
      o' <- evalCEK Mt env o
      v' <- objAccess f o'
      returnCEK cont v'
    ObjectRemove f o -> do
      o' <- evalCEK Mt env o
      v' <- objRemove f o'
      returnCEK cont v'
    ObjectExtend f v o -> do
      o' <- evalCEK Mt env o
      v' <- evalCEK Mt env v
      out <- objUpdate f o' v'
      returnCEK cont out
  returnCEK
    :: CEKRuntime b i
    => Cont b i
    -> CEKValue b i
    -> EvalT b (CEKValue b i)
  returnCEK (Arg env arg cont) fn =
    evalCEK (Fn fn cont) env arg
  returnCEK (Fn fn ctx) arg =
    applyLam fn arg ctx
  returnCEK (BlockC env (t:ts) cont) _discarded =
    evalCEK (BlockC env ts cont) env t
  returnCEK (BlockC _ [] cont) v =
    returnCEK cont v
  returnCEK Mt v = return v
  applyLam (VClosure body env) arg cont =
    evalCEK cont (RAList.cons arg env) body
  applyLam (VNative (BuiltinFn b fn arity args)) arg cont
    | arity - 1 == 0 = fn (reverse (arg:args)) >>= returnCEK cont
    | otherwise = returnCEK cont (VNative (BuiltinFn b fn (arity - 1) (arg:args)))
  applyLam _ _ _ = error "applying to non-fun"
  objAccess f (VObject o) = pure (o Map.! f)
  objAccess _ _ = error "fail"
  objRemove f (VObject o) = pure (VObject (Map.delete f o))
  objRemove _ _ = error "fail"
  objUpdate f v (VObject o) = pure (VObject (Map.insert f v o))
  objUpdate _ _ _ = error "fail"

runCEK
  :: Enum b
  => CEKTLEnv b i
  -- ^ Top levels
  -> Array (BuiltinFn b i)
  -- ^ Builtins
  -> EvalTerm b i
  -- ^ Term to evaluate
  -> IO (CEKValue b i, CEKState b)
runCEK env builtins term = let
  ?cekLoaded = env
  ?cekBuiltins = builtins
  in let
    cekState = CEKState 0 (Just [])
  in runEvalT cekState (eval RAList.Nil term)
{-# SPECIALISE runCEK
  :: CEKTLEnv CoreBuiltin i
  -> Array (BuiltinFn CoreBuiltin i)
  -> EvalTerm CoreBuiltin i
  -> IO (CEKValue CoreBuiltin i, CEKState CoreBuiltin) #-}

-- | Run our CEK interpreter
--   for only our core builtins
runCEKCorebuiltin
  :: CEKTLEnv CoreBuiltin i
  -- ^ Top levels
  -> EvalTerm CoreBuiltin i
  -- ^ Term to evaluate
  -> IO (CEKValue CoreBuiltin i, CEKState CoreBuiltin)
runCEKCorebuiltin env =
  runCEK env coreBuiltinRuntime

----------------------------------------------------------------------
-- Our builtin definitions start here
----------------------------------------------------------------------
applyTwo :: CEKRuntime b i => EvalTerm b i -> CEKEnv b  i -> CEKValue b i -> CEKValue b i -> EvalT b (CEKValue b i)
applyTwo body env arg1 arg2 = eval (RAList.cons arg2 (RAList.cons arg1 env)) body

unsafeApplyOne :: CEKRuntime b i => CEKValue b i -> CEKValue b i -> EvalT b (CEKValue b i)
unsafeApplyOne (VClosure body env) arg = eval (RAList.cons arg env) body
unsafeApplyOne (VNative (BuiltinFn b fn arity args)) arg =
  if arity - 1 <= 0 then fn (reverse (arg:args))
  else pure (VNative (BuiltinFn b fn (arity -1) (arg:args)))
unsafeApplyOne _ _ = error "impossible"

unsafeApplyTwo :: CEKRuntime b i => CEKValue b i -> CEKValue b i -> CEKValue b i -> EvalT b (CEKValue b i)
unsafeApplyTwo (VClosure (Lam body _) env) arg1 arg2 = applyTwo body env arg1 arg2
unsafeApplyTwo (VNative (BuiltinFn b fn arity args)) arg1 arg2 =
  if arity - 2 <= 0 then fn (reverse (arg1:arg2:args))
  else pure $ VNative $ BuiltinFn b fn (arity - 2) (arg1:arg2:args)
unsafeApplyTwo _ _ _ = error "impossible"

mkBuiltinFn
  :: BuiltinArity b
  => (CEKRuntime b i => [CEKValue b i] -> EvalT b (CEKValue b i))
  -> b
  -> BuiltinFn b i
mkBuiltinFn fn b =
  BuiltinFn b fn (builtinArity b) []
{-# INLINE mkBuiltinFn #-}

-- -- Todo: runtime error
unaryIntFn :: BuiltinArity b => (Integer -> Integer) -> b -> BuiltinFn b i
unaryIntFn op = mkBuiltinFn \case
  [VLiteral (LInteger i)] -> pure (VLiteral (LInteger (op i)))
  _ -> fail "impossible"
{-# INLINE unaryIntFn #-}

unaryDecFn :: BuiltinArity b => (Decimal -> Decimal) -> b -> BuiltinFn b i
unaryDecFn op = mkBuiltinFn \case
  [VLiteral (LDecimal i)] -> pure (VLiteral (LDecimal (op i)))
  _ -> fail "impossible"
{-# INLINE unaryDecFn #-}

binaryIntFn
  :: BuiltinArity b
  => (Integer -> Integer -> Integer)
  -> b
  -> BuiltinFn b i
binaryIntFn op = mkBuiltinFn \case
  [VLiteral (LInteger i), VLiteral (LInteger i')] -> pure (VLiteral (LInteger (op i i')))
  _ -> fail "impossible"
{-# INLINE binaryIntFn #-}

binaryDecFn :: BuiltinArity b => (Decimal -> Decimal -> Decimal) -> b -> BuiltinFn b i
binaryDecFn op = mkBuiltinFn \case
  [VLiteral (LDecimal i), VLiteral (LDecimal i')] -> pure (VLiteral (LDecimal (op i i')))
  _ -> fail "impossible"
{-# INLINE binaryDecFn #-}

binaryBoolFn :: BuiltinArity b => (Bool -> Bool -> Bool) -> b -> BuiltinFn b i
binaryBoolFn op = mkBuiltinFn \case
  [VLiteral (LBool l), VLiteral (LBool r)] -> pure (VLiteral (LBool (op l r)))
  _ -> fail "impossible"
{-# INLINE binaryBoolFn #-}

compareIntFn :: BuiltinArity b => (Integer -> Integer -> Bool) -> b -> BuiltinFn b i
compareIntFn op = mkBuiltinFn \case
  [VLiteral (LInteger i), VLiteral (LInteger i')] -> pure (VLiteral (LBool (op i i')))
  _ -> fail "impossible"
{-# INLINE compareIntFn #-}

compareDecFn :: BuiltinArity b => (Decimal -> Decimal -> Bool) -> b -> BuiltinFn b i
compareDecFn op = mkBuiltinFn \case
  [VLiteral (LDecimal i), VLiteral (LDecimal i')] -> pure (VLiteral (LBool (op i i')))
  _ -> fail "impossible"
{-# INLINE compareDecFn #-}

compareStrFn :: BuiltinArity b => (Text -> Text -> Bool) -> b -> BuiltinFn b i
compareStrFn op = mkBuiltinFn \case
  [VLiteral (LString i), VLiteral (LString i')] -> pure (VLiteral (LBool (op i i')))
  _ -> fail "impossible"
{-# INLINE compareStrFn #-}

roundingFn :: BuiltinArity b => (Rational -> Integer) -> b -> BuiltinFn b i
roundingFn op = mkBuiltinFn \case
  [VLiteral (LDecimal i)] -> pure (VLiteral (LInteger (truncate (roundTo' op 0 i))))
  _ -> fail "impossible"
{-# INLINE roundingFn #-}

---------------------------------
-- integer ops
------------------------------
addInt :: BuiltinArity b => b -> BuiltinFn b i
addInt = binaryIntFn (+)

subInt :: BuiltinArity b => b -> BuiltinFn b i
subInt = binaryIntFn (-)

mulInt :: BuiltinArity b => b -> BuiltinFn b i
mulInt = binaryIntFn (*)

divInt :: BuiltinArity b => b -> BuiltinFn b i
divInt = binaryIntFn quot

negateInt :: BuiltinArity b => b -> BuiltinFn b i
negateInt = unaryIntFn negate

modInt :: BuiltinArity b => b -> BuiltinFn b i
modInt = binaryIntFn mod

eqInt :: BuiltinArity b => b -> BuiltinFn b i
eqInt = compareIntFn (==)

neqInt :: BuiltinArity b => b -> BuiltinFn b i
neqInt = compareIntFn (/=)

gtInt :: BuiltinArity b => b -> BuiltinFn b i
gtInt = compareIntFn (>)

ltInt :: BuiltinArity b => b -> BuiltinFn b i
ltInt = compareIntFn (<)

geqInt :: BuiltinArity b => b -> BuiltinFn b i
geqInt = compareIntFn (>=)

leqInt :: BuiltinArity b => b -> BuiltinFn b i
leqInt = compareIntFn (<=)

bitAndInt :: BuiltinArity b => b -> BuiltinFn b i
bitAndInt = binaryIntFn (.&.)

bitOrInt :: BuiltinArity b => b -> BuiltinFn b i
bitOrInt = binaryIntFn (.|.)

bitComplementInt :: BuiltinArity b => b -> BuiltinFn b i
bitComplementInt = unaryIntFn complement

bitXorInt :: BuiltinArity b => b -> BuiltinFn b i
bitXorInt = binaryIntFn xor

bitShiftInt :: BuiltinArity b => b -> BuiltinFn b i
bitShiftInt = mkBuiltinFn \case
  [VLiteral (LInteger i), VLiteral (LInteger s)] ->
    pure (VLiteral (LInteger (shift i (fromIntegral s))))
  _ -> fail "impossible"

absInt :: BuiltinArity b => b -> BuiltinFn b i
absInt = unaryIntFn abs

expInt :: BuiltinArity b => b -> BuiltinFn b i
expInt = mkBuiltinFn \case
  [VLiteral (LInteger i)] ->
    pure (VLiteral (LDecimal (f2Dec (exp (fromIntegral i)))))
  _ -> fail "impossible"

lnInt :: BuiltinArity b => b -> BuiltinFn b i
lnInt = mkBuiltinFn \case
  [VLiteral (LInteger i)] ->
    pure (VLiteral (LDecimal (f2Dec (log (fromIntegral i)))))
  _ -> fail "impossible"

sqrtInt :: BuiltinArity b => b -> BuiltinFn b i
sqrtInt = mkBuiltinFn \case
  [VLiteral (LInteger i)] ->
    pure (VLiteral (LDecimal (f2Dec (sqrt (fromIntegral i)))))
  _ -> fail "impossible"

showInt :: BuiltinArity b => b -> BuiltinFn b i
showInt = mkBuiltinFn \case
  [VLiteral (LInteger i)] ->
    pure (VLiteral (LString (T.pack (show i))))
  _ -> fail "impossible"

-- -------------------------
-- double ops
-- -------------------------

addDec :: BuiltinArity b => b -> BuiltinFn b i
addDec = binaryDecFn (+)

subDec :: BuiltinArity b => b -> BuiltinFn b i
subDec = binaryDecFn (-)

mulDec :: BuiltinArity b => b -> BuiltinFn b i
mulDec = binaryDecFn (*)

divDec :: BuiltinArity b => b -> BuiltinFn b i
divDec = binaryDecFn (/)

negateDec :: BuiltinArity b => b -> BuiltinFn b i
negateDec = unaryDecFn negate

absDec :: BuiltinArity b => b -> BuiltinFn b i
absDec = unaryDecFn abs

eqDec :: BuiltinArity b => b -> BuiltinFn b i
eqDec = compareDecFn (==)

neqDec :: BuiltinArity b => b -> BuiltinFn b i
neqDec = compareDecFn (/=)

gtDec :: BuiltinArity b => b -> BuiltinFn b i
gtDec = compareDecFn (>)

geqDec :: BuiltinArity b => b -> BuiltinFn b i
geqDec = compareDecFn (>=)

ltDec :: BuiltinArity b => b -> BuiltinFn b i
ltDec = compareDecFn (<)

leqDec :: BuiltinArity b => b -> BuiltinFn b i
leqDec = compareDecFn (<=)

showDec :: CoreBuiltin -> BuiltinFn CoreBuiltin i
showDec = mkBuiltinFn \case
  [VLiteral (LDecimal i)] ->
    pure (VLiteral (LString (T.pack (show i))))
  _ -> fail "impossible"

dec2F :: Decimal -> Double
dec2F = fromRational . toRational

f2Dec :: Double -> Decimal
f2Dec = fromRational . toRational

roundDec :: CoreBuiltin -> BuiltinFn CoreBuiltin i
roundDec = roundingFn round
floorDec :: CoreBuiltin -> BuiltinFn CoreBuiltin i
floorDec = roundingFn floor
ceilingDec :: CoreBuiltin -> BuiltinFn CoreBuiltin i
ceilingDec = roundingFn ceiling

expDec :: CoreBuiltin -> BuiltinFn CoreBuiltin i
expDec = unaryDecFn (f2Dec . exp . dec2F)

lnDec :: CoreBuiltin -> BuiltinFn CoreBuiltin i
lnDec = unaryDecFn (f2Dec . log . dec2F)

sqrtDec :: CoreBuiltin -> BuiltinFn CoreBuiltin i
sqrtDec = unaryDecFn (f2Dec . sqrt . dec2F)

---------------------------
-- bool ops
---------------------------
andBool :: CoreBuiltin -> BuiltinFn CoreBuiltin i
andBool = binaryBoolFn (&&)

orBool :: CoreBuiltin -> BuiltinFn CoreBuiltin i
orBool = binaryBoolFn (||)

notBool :: CoreBuiltin -> BuiltinFn CoreBuiltin i
notBool = mkBuiltinFn \case
  [VLiteral (LBool i)] -> pure (VLiteral (LBool (not i)))
  _ -> fail "impossible"

eqBool :: CoreBuiltin -> BuiltinFn CoreBuiltin i
eqBool = binaryBoolFn (==)

neqBool :: CoreBuiltin -> BuiltinFn CoreBuiltin i
neqBool = binaryBoolFn (/=)

showBool :: CoreBuiltin -> BuiltinFn CoreBuiltin i
showBool = mkBuiltinFn \case
  [VLiteral (LBool i)] -> do
    let out = if i then "true" else "false"
    pure (VLiteral (LString out))
  _ -> fail "impossible"

---------------------------
-- string ops
---------------------------
eqStr :: CoreBuiltin -> BuiltinFn CoreBuiltin i
eqStr = compareStrFn (==)

neqStr :: CoreBuiltin -> BuiltinFn CoreBuiltin i
neqStr = compareStrFn (/=)

gtStr :: CoreBuiltin -> BuiltinFn CoreBuiltin i
gtStr = compareStrFn (>)

geqStr :: CoreBuiltin -> BuiltinFn CoreBuiltin i
geqStr = compareStrFn (>=)

ltStr :: CoreBuiltin -> BuiltinFn CoreBuiltin i
ltStr = compareStrFn (<)

leqStr :: CoreBuiltin -> BuiltinFn CoreBuiltin i
leqStr = compareStrFn (<=)

addStr :: CoreBuiltin -> BuiltinFn CoreBuiltin i
addStr =  mkBuiltinFn \case
  [VLiteral (LString i), VLiteral (LString i')] -> pure (VLiteral (LString (i <> i')))
  _ -> fail "impossible"

takeStr :: CoreBuiltin -> BuiltinFn CoreBuiltin i
takeStr = mkBuiltinFn \case
  [VLiteral (LInteger i), VLiteral (LString t)] -> do
    pure (VLiteral (LString (T.take (fromIntegral i) t)))
  _ -> fail "impossible"

dropStr :: CoreBuiltin -> BuiltinFn CoreBuiltin i
dropStr = mkBuiltinFn \case
  [VLiteral (LInteger i), VLiteral (LString t)] -> do
    pure (VLiteral (LString (T.drop (fromIntegral i) t)))
  _ -> fail "impossible"

lengthStr :: CoreBuiltin -> BuiltinFn CoreBuiltin i
lengthStr = mkBuiltinFn \case
  [VLiteral (LString t)] -> do
    pure (VLiteral (LInteger (fromIntegral (T.length t))))
  _ -> fail "impossible"

reverseStr :: CoreBuiltin -> BuiltinFn CoreBuiltin i
reverseStr = mkBuiltinFn \case
  [VLiteral (LString t)] -> do
    pure (VLiteral (LString (T.reverse t)))
  _ -> fail "impossible"

showStr :: CoreBuiltin -> BuiltinFn CoreBuiltin i
showStr = mkBuiltinFn \case
  [VLiteral (LString t)] -> do
    let out = "\"" <> t <> "\""
    pure (VLiteral (LString out))
  _ -> fail "impossible"

concatStr :: CoreBuiltin -> BuiltinFn CoreBuiltin i
concatStr = mkBuiltinFn \case
  [VList li] -> do
    li' <- traverse asString li
    pure (VLiteral (LString (T.concat (V.toList li'))))
  _ -> fail "impossible"


---------------------------
-- Unit ops
---------------------------

eqUnit :: CoreBuiltin -> BuiltinFn CoreBuiltin i
eqUnit = mkBuiltinFn \case
  [VLiteral LUnit, VLiteral LUnit] -> pure (VLiteral (LBool True))
  _ -> fail "impossible"

neqUnit :: CoreBuiltin -> BuiltinFn CoreBuiltin i
neqUnit = mkBuiltinFn \case
  [VLiteral LUnit, VLiteral LUnit] -> pure (VLiteral (LBool False))
  _ -> fail "impossible"

showUnit :: CoreBuiltin -> BuiltinFn CoreBuiltin i
showUnit = mkBuiltinFn \case
  [VLiteral LUnit] -> pure (VLiteral (LString "()"))
  _ -> fail "impossible"

---------------------------
-- Object ops
---------------------------

eqObj :: CoreBuiltin -> BuiltinFn CoreBuiltin i
eqObj = mkBuiltinFn \case
  [l@VObject{}, r@VObject{}] -> pure (VLiteral (LBool (unsafeEqCEKValue l r)))
  _ -> fail "impossible"

neqObj :: CoreBuiltin -> BuiltinFn CoreBuiltin i
neqObj = mkBuiltinFn \case
  [l@VObject{}, r@VObject{}] -> pure (VLiteral (LBool (unsafeNeqCEKValue l r)))
  _ -> fail "impossible"


------------------------------
--- conversions + unsafe ops
------------------------------
asBool :: CEKValue b i -> EvalT b Bool
asBool (VLiteral (LBool b)) = pure b
asBool _ = fail "impossible"

asString :: CEKValue b i -> EvalT b Text
asString (VLiteral (LString b)) = pure b
asString _ = fail "impossible"

asList :: CEKValue b i -> EvalT b (Vector (CEKValue b i))
asList (VList l) = pure l
asList _ = fail "impossible"

unsafeEqLiteral :: Literal -> Literal -> Bool
unsafeEqLiteral (LString i) (LString i') = i == i'
unsafeEqLiteral (LInteger i) (LInteger i') = i == i'
unsafeEqLiteral (LDecimal i) (LDecimal i') = i == i'
unsafeEqLiteral LUnit LUnit = True
unsafeEqLiteral (LBool i) (LBool i') = i == i'
unsafeEqLiteral (LTime i) (LTime i') = i == i'
unsafeEqLiteral _ _ = error "todo: throw invariant failure exception"

-- unsafeNeqLiteral :: Literal -> Literal -> Bool
-- unsafeNeqLiteral a b = not (unsafeEqLiteral a b)

unsafeEqCEKValue :: CEKValue b i -> CEKValue b i -> Bool
unsafeEqCEKValue (VLiteral l) (VLiteral l') = unsafeEqLiteral l l'
unsafeEqCEKValue (VObject o) (VObject o') = and (Map.intersectionWith unsafeEqCEKValue o o')
unsafeEqCEKValue (VList l) (VList l') =  V.length l == V.length l' &&  and (V.zipWith unsafeEqCEKValue l l')
unsafeEqCEKValue _ _ = error "todo: throw invariant failure exception"

unsafeNeqCEKValue :: CEKValue b i -> CEKValue b i -> Bool
unsafeNeqCEKValue a b = not (unsafeEqCEKValue a b)

---------------------------
-- list ops
---------------------------
eqList :: CoreBuiltin -> BuiltinFn CoreBuiltin i
eqList = mkBuiltinFn \case
  [eqClo, VList l, VList r] ->
    if V.length l /= V.length r then
      pure (VLiteral (LBool False))
    else do
      v' <- V.zipWithM (\a b -> asBool =<< unsafeApplyTwo eqClo a b) l r
      pure (VLiteral (LBool (and v')))
  _ -> fail "impossible"

neqList :: CoreBuiltin -> BuiltinFn CoreBuiltin i
neqList = mkBuiltinFn \case
  [neqClo, VList l, VList r] ->
    if V.length l /= V.length r then
      pure (VLiteral (LBool True))
    else do
      v' <- V.zipWithM (\a b -> asBool =<< unsafeApplyTwo neqClo a b) l r
      pure (VLiteral (LBool (or v')))
  _ -> fail "impossible"

zipList :: CoreBuiltin -> BuiltinFn CoreBuiltin i
zipList = mkBuiltinFn \case
  [clo, VList l, VList r] -> do
    v' <- V.zipWithM (unsafeApplyTwo clo) l r
    pure (VList v')
  _ -> fail "impossible"

addList :: CoreBuiltin -> BuiltinFn CoreBuiltin i
addList = mkBuiltinFn \case
  [VList l, VList r] -> pure (VList (l <> r))
  _ -> fail "impossible"

pcShowList :: CoreBuiltin -> BuiltinFn CoreBuiltin i
pcShowList = mkBuiltinFn \case
  [showFn, VList l1] -> do
    strli <- traverse ((=<<) asString  . unsafeApplyOne showFn) (V.toList l1)
    let out = "[" <> T.intercalate ", " strli <> "]"
    pure (VLiteral (LString out))
  _ -> fail "impossible"

coreMap :: CoreBuiltin -> BuiltinFn CoreBuiltin i
coreMap = mkBuiltinFn \case
  [fn, VList li] -> do
    li' <- traverse (unsafeApplyOne fn) li
    pure (VList li')
  _ -> fail "impossible"

coreFilter :: CoreBuiltin -> BuiltinFn CoreBuiltin i
coreFilter = mkBuiltinFn \case
  [fn, VList li] -> do
    let applyOne' arg = unsafeApplyOne fn arg >>= asBool
    li' <- V.filterM applyOne' li
    pure (VList li')
  _ -> fail "impossible"

coreFold :: CoreBuiltin -> BuiltinFn CoreBuiltin i
coreFold = mkBuiltinFn \case
  [fn, initElem, VList li] -> V.foldM' (unsafeApplyTwo fn) initElem li
  _ -> fail "impossible"

lengthList :: CoreBuiltin -> BuiltinFn CoreBuiltin i
lengthList = mkBuiltinFn \case
  [VList li] -> pure (VLiteral (LInteger (fromIntegral (V.length li))))
  _ -> fail "impossible"

takeList :: CoreBuiltin -> BuiltinFn CoreBuiltin i
takeList = mkBuiltinFn \case
  [VLiteral (LInteger i), VList li] ->
    pure (VList (V.take (fromIntegral i) li))
  _ -> fail "impossible"

dropList :: CoreBuiltin -> BuiltinFn CoreBuiltin i
dropList = mkBuiltinFn \case
  [VLiteral (LInteger i), VList li] ->
    pure (VList (V.drop (fromIntegral i) li))
  _ -> fail "impossible"

reverseList :: CoreBuiltin -> BuiltinFn CoreBuiltin i
reverseList = mkBuiltinFn \case
  [VList li] ->
    pure (VList (V.reverse li))
  _ -> fail "impossible"

coreEnumerate :: CoreBuiltin -> BuiltinFn CoreBuiltin i
coreEnumerate = mkBuiltinFn \case
  [VLiteral (LInteger from), VLiteral (LInteger to)] -> enum' from to
  _ -> fail "impossible"
  where
  toVecList = VList . fmap (VLiteral . LInteger)
  enum' from to
    | to >= from = pure $ toVecList $ V.enumFromN from (fromIntegral (to - from + 1))
    | otherwise = pure $ toVecList $ V.enumFromStepN from (-1) (fromIntegral (from - to + 1))

coreEnumerateStepN :: CoreBuiltin -> BuiltinFn CoreBuiltin i
coreEnumerateStepN = mkBuiltinFn \case
  [VLiteral (LInteger from), VLiteral (LInteger to), VLiteral (LInteger step)] -> enum' from to step
  _ -> fail "impossible"
  where
  toVecList = VList . fmap (VLiteral . LInteger)
  enum' from to step
    | to > from && step > 0 = pure $ toVecList $ V.enumFromStepN from step (fromIntegral ((to - from + 1) `quot` step))
    | from > to && step < 0 = pure $ toVecList $ V.enumFromStepN from step (fromIntegral ((from - to + 1) `quot` step))
    | from == to && step == 0 = pure $ toVecList $ V.singleton from
    | otherwise = fail "enumerate outside interval bounds"

concatList :: CoreBuiltin -> BuiltinFn CoreBuiltin i
concatList = mkBuiltinFn \case
  [VList li] -> do
    li' <- traverse asList li
    pure (VList (V.concat (V.toList li')))
  _ -> fail "impossible"

-----------------------------------
-- Other Core forms
-----------------------------------

coreIf :: CoreBuiltin -> BuiltinFn CoreBuiltin i
coreIf = mkBuiltinFn \case
  [VLiteral (LBool b), VClosure tbody tenv, VClosure fbody fenv] ->
    if b then eval tenv tbody else  eval fenv fbody
  _ -> fail "impossible"

unimplemented :: BuiltinFn CoreBuiltin i
unimplemented = error "unimplemented"

coreBuiltinFn :: CoreBuiltin -> BuiltinFn CoreBuiltin i
coreBuiltinFn = \case
  -- Int Add + num ops
  AddInt -> addInt AddInt
  SubInt -> subInt SubInt
  DivInt -> divInt DivInt
  MulInt -> mulInt MulInt
  NegateInt -> negateInt NegateInt
  AbsInt -> absInt AbsInt
  -- Int fractional
  ExpInt -> expInt ExpInt
  LnInt -> lnInt LnInt
  SqrtInt -> sqrtInt SqrtInt
  LogBaseInt -> unimplemented
  -- Geenral int ops
  ModInt -> modInt ModInt
  BitAndInt -> bitAndInt BitAndInt
  BitOrInt -> bitOrInt BitOrInt
  BitXorInt ->  bitXorInt BitXorInt
  BitShiftInt -> bitShiftInt BitShiftInt
  BitComplementInt -> bitComplementInt BitComplementInt
  -- Int Equality + Ord
  EqInt -> eqInt EqInt
  NeqInt -> neqInt NeqInt
  GTInt -> gtInt GTInt
  GEQInt -> geqInt GEQInt
  LTInt -> ltInt LTInt
  LEQInt -> leqInt LEQInt
  -- IntShow inst
  ShowInt -> showInt ShowInt
  -- If
  IfElse -> coreIf IfElse
  -- Decimal ops
  -- Add + Num
  AddDec -> addDec AddDec
  SubDec -> subDec SubDec
  DivDec -> divDec DivDec
  MulDec -> mulDec MulDec
  NegateDec -> negateDec NegateDec
  AbsDec -> absDec AbsDec
  -- Decimal rounding ops
  RoundDec -> roundDec RoundDec
  CeilingDec -> ceilingDec CeilingDec
  FloorDec -> floorDec FloorDec
  -- Decimal fractional
  ExpDec -> expDec ExpDec
  LnDec -> lnDec LnDec
  LogBaseDec -> unimplemented
  SqrtDec -> sqrtDec SqrtDec
  -- Decimal show
  ShowDec -> showDec ShowDec
  -- Decimal Equality + Ord
  EqDec -> eqDec EqDec
  NeqDec -> neqDec NeqDec
  GTDec -> gtDec GTDec
  GEQDec -> geqDec GEQDec
  LTDec -> ltDec LTDec
  LEQDec -> leqDec LEQDec
  -- Bool Ops
  AndBool -> andBool AndBool
  OrBool -> orBool OrBool
  NotBool -> notBool NotBool
  -- Bool Equality
  EqBool -> eqBool EqBool
  NeqBool -> neqBool NeqBool
  ShowBool -> showBool ShowBool
  -- String Equality + Ord
  EqStr -> eqStr EqStr
  NeqStr -> neqStr NeqStr
  GTStr -> gtStr GTStr
  GEQStr -> geqStr GEQStr
  LTStr -> ltStr LTStr
  LEQStr -> leqStr LEQStr
  -- String Ops
  AddStr -> addStr AddStr
  -- String listlike
  ConcatStr -> concatStr ConcatStr
  DropStr -> dropStr DropStr
  TakeStr -> takeStr TakeStr
  LengthStr -> lengthStr LengthStr
  ReverseStr -> reverseStr ReverseStr
  -- String show
  ShowStr -> showStr ShowStr
  -- Object equality
  EqObj -> eqObj EqObj
  NeqObj -> neqObj NeqObj
  -- List Equality + Ord
  EqList -> eqList EqList
  NeqList -> neqList NeqList
  GTList -> unimplemented
  GEQList -> unimplemented
  LTList -> unimplemented
  LEQList -> unimplemented
  -- List Show
  ShowList -> pcShowList ShowList
  -- ListAdd
  AddList -> addList AddList
  -- List ListlLike
  TakeList -> takeList TakeList
  DropList -> dropList DropList
  LengthList -> lengthList LengthList
  ConcatList -> concatList ConcatList
  ReverseList -> reverseList ReverseList
  -- misc list ops
  FilterList -> coreFilter FilterList
  DistinctList -> unimplemented
  ZipList -> zipList ZipList
  MapList -> coreMap MapList
  FoldList -> coreFold FoldList
  -- Unit ops
  EqUnit -> eqUnit EqUnit
  NeqUnit -> neqUnit NeqUnit
  ShowUnit -> showUnit ShowUnit
  Enforce -> unimplemented
  EnforceOne -> unimplemented
  Enumerate -> coreEnumerate Enumerate
  EnumerateStepN -> coreEnumerateStepN EnumerateStepN

coreBuiltinRuntime :: Array.Array (BuiltinFn CoreBuiltin i)
coreBuiltinRuntime = Array.arrayFromList (coreBuiltinFn <$> [minBound .. maxBound])
