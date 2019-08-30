{-# LANGUAGE GADTs #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}

module SAWScript.Heapster.CruUtil where

import Data.Kind
import Data.Text hiding (length)
import Data.Reflection

import Data.Binding.Hobbits

import What4.ProgramLoc
import Data.Parameterized.Context hiding ((:>), empty, take, view)
import qualified Data.Parameterized.Context as Ctx
import Data.Parameterized.TraversableFC

import Lang.Crucible.Types
import Lang.Crucible.FunctionHandle
import Lang.Crucible.CFG.Expr
import Lang.Crucible.CFG.Core
import Lang.Crucible.CFG.Extension
import Lang.Crucible.LLVM.Bytes
import Lang.Crucible.LLVM.Extension
import Lang.Crucible.LLVM.MemModel
import Lang.Crucible.LLVM.Arch.X86


----------------------------------------------------------------------
-- * Building 'NuMatching' and 'Closable' Instances for Crucible Types
----------------------------------------------------------------------

-- | Typeclass for lifting the 'NuMatching' constraint to functors on arbitrary
-- kinds that do not require any constraints on their input types
class NuMatchingAny1 (f :: k -> Type) where
  nuMatchingAny1Proof :: MbTypeRepr (f a)

instance {-# INCOHERENT #-} NuMatchingAny1 f => NuMatching (f a) where
  nuMatchingProof = nuMatchingAny1Proof


-- | A reification of an object of type @a@ at type level
data ReifiesObj a = forall s. Reifies s a => ReifiesObj (Proxy s)

$(mkNuMatching [t| forall a. ReifiesObj a |])

-- | Build a 'ReifiesObj' containing a value
mkReifiesObj :: a -> ReifiesObj a
mkReifiesObj a = reify a ReifiesObj

-- | Project out the value contained in a 'ReifiesObj'
projReifiesObj :: ReifiesObj a -> a
projReifiesObj (ReifiesObj prx) = reflect prx

-- | Builds an 'MbTypeRepr' proof for use in a 'NuMatching' instance. This proof
-- is unsafe because it does no renaming of fresh names, so should only be used
-- for types that are guaranteed not to contain any 'Name' or 'Mb' values.
unsafeMbTypeRepr :: MbTypeRepr a
unsafeMbTypeRepr = isoMbTypeRepr mkReifiesObj projReifiesObj

instance NuMatching (SymbolRepr tp) where
  nuMatchingProof = unsafeMbTypeRepr

instance NuMatching (NatRepr tp) where
  nuMatchingProof = unsafeMbTypeRepr

instance NuMatching (TypeRepr tp) where
  nuMatchingProof = unsafeMbTypeRepr

instance NuMatching (BaseTypeRepr tp) where
  nuMatchingProof = unsafeMbTypeRepr

-- NOTE: this is handled by the Assignment instance
-- instance NuMatching (CtxRepr ctx) where
--   nuMatchingProof = isoMbTypeRepr mkKnownReprObj getKnownReprObj

instance NuMatching (Index ctx a) where
  nuMatchingProof = unsafeMbTypeRepr

instance NuMatching Text where
  nuMatchingProof = unsafeMbTypeRepr

instance NuMatching ProgramLoc where
  nuMatchingProof = unsafeMbTypeRepr

instance NuMatching (FnHandle args ret) where
  nuMatchingProof = unsafeMbTypeRepr

instance NuMatching (FloatInfoRepr fi) where
  nuMatchingProof = unsafeMbTypeRepr

instance NuMatching RoundingMode where
  nuMatchingProof = unsafeMbTypeRepr

instance NuMatchingAny1 BaseTypeRepr where
  nuMatchingAny1Proof = nuMatchingProof

instance NuMatchingAny1 TypeRepr where
  nuMatchingAny1Proof = nuMatchingProof

$(mkNuMatching [t| forall f ctx . NuMatchingAny1 f => AssignView f ctx |])

viewToAssign :: AssignView f ctx -> Assignment f ctx
viewToAssign AssignEmpty = Ctx.empty
viewToAssign (AssignExtend asgn' f) = extend asgn' f

instance NuMatchingAny1 f => NuMatching (Assignment f ctx) where
  nuMatchingProof =
    -- FIXME: inefficient to map a whole Assignment step by step to ViewAssigns,
    -- freshen each element, and then map back to the Assignment again; maybe we
    -- need to figure out how to use the TraversableFC instance for Assignment
    -- here?
    isoMbTypeRepr viewAssign viewToAssign

$(mkNuMatching [t| forall f tp. NuMatchingAny1 f => BaseTerm f tp |])

instance NuMatchingAny1 f => NuMatchingAny1 (BaseTerm f) where
  nuMatchingAny1Proof = nuMatchingProof

$(mkNuMatching [t| forall ext f tp.
                (NuMatchingAny1 f, NuMatchingAny1 (ExprExtension ext f)) =>
                App ext f tp |])


-- NOTE: Crucible objects can never contain any Hobbits names, but "proving"
-- that would require introspection of opaque types like 'Index' and 'Nonce',
-- and would also be inefficient, so we just use 'unsafeClose'

instance Closable (Block ext cblocks ret args) where
  toClosed = unsafeClose

instance Closable (FnHandle args ret) where
  toClosed = unsafeClose

instance Liftable (FnHandle args ret) where
  mbLift fh = unClosed $ mbLift $ fmap toClosed fh

-- | Close an assignment whose elements are all 'Closable'
closeAssign :: (forall a. f a -> Closed (f a)) -> Assignment f ctx ->
               Closed (Assignment f ctx)
closeAssign _ (viewAssign -> AssignEmpty) = $(mkClosed [| Ctx.empty |])
closeAssign f (viewAssign -> AssignExtend asgn fa) =
  $(mkClosed [| Ctx.extend |]) `clApply` closeAssign f asgn `clApply` f fa


----------------------------------------------------------------------
-- * Contexts of Crucible Types
----------------------------------------------------------------------

-- | Convert a Crucible 'Ctx' to a Hobbits 'RList'
type family CtxToRList (ctx :: Ctx k) :: RList k where
  CtxToRList EmptyCtx = RNil
  CtxToRList (ctx' ::> x) = CtxToRList ctx' :> x

-- | Convert a Hobbits 'RList' to a Crucible 'Ctx'
type family RListToCtx (ctx :: RList k) :: Ctx k where
  RListToCtx RNil = EmptyCtx
  RListToCtx (ctx' :> x) = RListToCtx ctx' ::> x

-- | Convert a Crucible context of contexts to a Hobbits one
type family CtxCtxToRList (ctx :: Ctx (Ctx k)) :: RList (RList k) where
  CtxCtxToRList EmptyCtx = RNil
  CtxCtxToRList (ctx' ::> c) = CtxCtxToRList ctx' :> CtxToRList c

-- | Convert a Hobbits context of contexts to a Crucible one
type family RListToCtxCtx (ctx :: RList (RList k)) :: Ctx (Ctx k) where
  RListToCtxCtx RNil = EmptyCtx
  RListToCtxCtx (ctx' :> c) = RListToCtxCtx ctx' ::> RListToCtx c

-- | Convert a Crucible 'Assignment' to a Hobbits 'MapRList'
assignToRList :: Assignment f ctx -> MapRList f (CtxToRList ctx)
assignToRList asgn = case viewAssign asgn of
  AssignEmpty -> MNil
  AssignExtend asgn' f -> assignToRList asgn' :>: f

-- | Convert a Hobbits 'MapRList' to a Crucible 'Assignment'
rlistToAssign :: MapRList f ctx -> Assignment f (RListToCtx ctx)
rlistToAssign MNil = Ctx.empty
rlistToAssign (rlist :>: f) = extend (rlistToAssign rlist) f

-- | Representation types that support the 'withKnownRepr' operation
class WithKnownRepr f where
  withKnownRepr :: f a -> (KnownRepr f a => r) -> r

instance WithKnownRepr NatRepr where
  withKnownRepr = withKnownNat

instance WithKnownRepr BaseTypeRepr where
  withKnownRepr = error "FIXME HERE: write withKnownBaseType!"

instance WithKnownRepr TypeRepr where
  withKnownRepr = error "FIXME HERE: write withKnownType!"

instance WithKnownRepr CtxRepr where
  withKnownRepr = error "FIXME HERE: write withKnownCtx!"

instance WithKnownRepr (Index ctx) where
  withKnownRepr = error "FIXME HERE: write withKnownIndex!"


{-
-- | An object containing a 'KnownRepr' instance; used to build 'NuMatching'
-- instances for the various @Repr@ types
data KnownReprObj f a = KnownRepr f a => KnownReprObj

$(mkNuMatching [t| forall f a. KnownReprObj f a |])

mkKnownReprObj :: WithKnownRepr f => f a -> KnownReprObj f a
mkKnownReprObj repr = withKnownRepr repr KnownReprObj

getKnownReprObj :: KnownReprObj f a -> f a
getKnownReprObj KnownReprObj = knownRepr
-}

-- | A 'TypeRepr' that has been promoted to a constraint; this is necessary in
-- order to make a 'NuMatching' instance for it, as part of the representation
-- of 'TypeRepr' is hidden (and also this way is faster)
data CruType a where
  CruType :: KnownRepr TypeRepr a => CruType a

-- | Extract the 'TypeRepr' from a 'CruType'
unCruType :: CruType a -> TypeRepr a
unCruType CruType = knownRepr

instance TestEquality CruType where
  testEquality (CruType :: CruType a1) (CruType :: CruType a2) =
    testEquality (knownRepr :: TypeRepr a1) (knownRepr :: TypeRepr a2)

instance Liftable (CruType a) where
  mbLift [nuP| CruType |] = CruType

instance Closable (CruType a) where
  toClosed CruType = $(mkClosed [| CruType |])

-- | A context of Crucible types. NOTE: we do not use 'MapRList' here, because
-- we do not yet have a nice way to define the 'NuMatching' instance we want...
data CruCtx ctx where
  CruCtxNil :: CruCtx RNil
  CruCtxCons :: CruCtx ctx -> CruType a -> CruCtx (ctx :> a)

$(mkNuMatching [t| forall a. CruType a |])
$(mkNuMatching [t| forall ctx. CruCtx ctx |])

instance Liftable (CruCtx ctx) where
  mbLift [nuP| CruCtxNil |] = CruCtxNil
  mbLift [nuP| CruCtxCons ctx a |] = CruCtxCons (mbLift ctx) (mbLift a)

instance Closable (CruCtx ctx) where
  toClosed CruCtxNil = $(mkClosed [| CruCtxNil |])
  toClosed (CruCtxCons ctx a) =
    $(mkClosed [| CruCtxCons |]) `clApply` toClosed ctx `clApply` toClosed a

instance TestEquality CruCtx where
  testEquality CruCtxNil CruCtxNil = Just Refl
  testEquality (CruCtxCons ctx1 tp1) (CruCtxCons ctx2 tp2)
    | Just Refl <- testEquality ctx1 ctx2
    , Just Refl <- testEquality tp1 tp2
    = Just Refl
  testEquality _ _ = Nothing

instance KnownRepr TypeRepr tp => KnownRepr CruType tp where
  knownRepr = CruType

instance KnownRepr CruCtx RNil where
  knownRepr = CruCtxNil

instance (KnownRepr CruCtx tps, KnownRepr CruType tp) =>
         KnownRepr CruCtx (tps :> tp) where
  knownRepr = CruCtxCons knownRepr knownRepr

-- | Build a 'CruType' from a 'TypeRepr'
mkCruType :: TypeRepr a -> CruType a
mkCruType tp = withKnownRepr tp CruType

-- | Build a 'CruCtx' from a 'CtxRepr'
mkCruCtx :: CtxRepr ctx -> CruCtx (CtxToRList ctx)
mkCruCtx ctx = case viewAssign ctx of
  AssignEmpty -> CruCtxNil
  AssignExtend ctx' tp -> CruCtxCons (mkCruCtx ctx') (mkCruType tp)

-- | The empty context
emptyCruCtx :: CruCtx RNil
emptyCruCtx = CruCtxNil

-- | Build a singleton crucible context
singletonCruCtx :: TypeRepr tp -> CruCtx (RNil :> tp)
singletonCruCtx tp = CruCtxCons CruCtxNil (mkCruType tp)

-- | Add an element to the end of a context
extCruCtx :: KnownRepr TypeRepr a => CruCtx ctx -> CruCtx (ctx :> a)
extCruCtx ctx = CruCtxCons ctx CruType

-- | Remove an element from the end of a context
unextCruCtx :: CruCtx (ctx :> a) -> CruCtx ctx
unextCruCtx (CruCtxCons ctx _) = ctx

-- | Append two contexts
appendCruCtx :: CruCtx ctx1 -> CruCtx ctx2 -> CruCtx (ctx1 :++: ctx2)
appendCruCtx ctx1 CruCtxNil = ctx1
appendCruCtx ctx1 (CruCtxCons ctx2 tp) = CruCtxCons (appendCruCtx ctx1 ctx2) tp

ctxToMap :: CruCtx ctx -> MapRList CruType ctx
ctxToMap CruCtxNil = MNil
ctxToMap (CruCtxCons ctx tp) = ctxToMap ctx :>: tp
