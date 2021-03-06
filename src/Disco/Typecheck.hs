{-# LANGUAGE FlexibleContexts         #-}
{-# LANGUAGE FlexibleInstances        #-}
{-# LANGUAGE GADTs                    #-}
{-# LANGUAGE MultiParamTypeClasses    #-}
{-# LANGUAGE NondecreasingIndentation #-}
{-# LANGUAGE RankNTypes               #-}
{-# LANGUAGE TemplateHaskell          #-}
{-# LANGUAGE TupleSections            #-}
{-# LANGUAGE TypeFamilies             #-}
{-# LANGUAGE UndecidableInstances     #-}
{-# LANGUAGE ViewPatterns             #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Disco.Typecheck
-- Copyright   :  (c) 2016 disco team (see LICENSE)
-- License     :  BSD-style (see LICENSE)
-- Maintainer  :  byorgey@gmail.com
--
-- Typecheck the Disco surface language and transform it into a
-- type-annotated AST.
--
-----------------------------------------------------------------------------

module Disco.Typecheck
       ( -- * Type checking monad
         TCM, TyCtx, runTCM, evalTCM, execTCM
         -- ** Definitions
       , Defn, DefnCtx
         -- ** Errors
       , TCError(..)

         -- * Type checking
       , check, checkPattern, ok, checkDefn
       , checkProperties, checkProperty

         -- ** Whole modules
       , checkModule, withTypeDecls
         -- ** Subtyping
       , checkSub, isSub, lub, numLub
         -- ** Decidability
       , checkDecidable
       , checkOrdered

       , requireSameTy
       , getFunTy
       , checkNumTy

         -- * Type inference
       , infer
       , inferComp
         -- ** Case analysis
       , inferCase, inferBranch

         -- * Erasure
       , erase
       , eraseBinding, eraseBranch, eraseGuard
       , eraseLink, eraseQual, eraseProperty
       )
       where

import           Prelude                                 hiding (lookup)

import           Control.Applicative                     ((<|>))
import           Control.Arrow                           ((&&&))
import           Control.Lens                            ((%~), (&), _1)
import           Control.Monad.Except
import           Control.Monad.Reader
import           Control.Monad.State
import           Data.Bifunctor                          (first)
import           Data.Coerce
import           Data.List                               (group, partition,
                                                          sort)
import qualified Data.Map                                as M

import           Unbound.Generics.LocallyNameless
import           Unbound.Generics.LocallyNameless.Unsafe (unsafeUnbind)

import           Disco.AST.Surface
import           Disco.AST.Typed
import           Disco.Context
import           Disco.Syntax.Operators
import           Disco.Types

-- | A definition is a group of clauses, each having a list of
--   patterns that bind names in a term, without the name of the
--   function being defined.  For example, given the concrete syntax
--   @f n (x,y) = n*x + y@, the corresponding 'Defn' would be
--   something like @[n, (x,y)] (n*x + y)@.
type Defn  = [Bind [Pattern] ATerm]

-- | A map from names to definitions.
type DefnCtx = Ctx ATerm Defn

-- | A typing context is a mapping from term names to types.
type TyCtx = Ctx Term Type

-- | Potential typechecking errors.
data TCError
  = Unbound (Name Term)    -- ^ Encountered an unbound variable
  | NotArrow Term Type     -- ^ The type of a lambda should be an arrow type but isn't
  | NotFun   ATerm         -- ^ The term should be a function but has a non-arrow type
  | NotSum Term Type       -- ^ The term is an injection but is
                           --   expected to have some type other than
                           --   a sum type
  | NotTuple Term Type     -- ^ The term is a tuple but has a type
                           --   which is not an appropriate product type
  | NotTuplePattern Pattern Type
  | Mismatch Type ATerm    -- ^ Simple type mismatch: expected, actual
  | CantInfer Term         -- ^ We were asked to infer the type of the
                           --   term, but its type cannot be inferred
  | NotNum ATerm           -- ^ The term is expected to have a numeric type but it doesn't
  | NotNumTy Type          -- ^ The type should be numeric, but is not.
  | IncompatibleTypes Type Type  -- ^ The types should have a lub
                                 -- (i.e. common supertype) but they
                                 -- don't.
  | Juxtaposition ATerm Term
                           -- ^ The first term is juxtaposed with the
                           --   second, but typechecks as neither
                           --   function application nor
                           --   multiplication
  | Undecidable Type       -- ^ The type should be decidable so we can
                           --   check equality, but it isn't.
  | Unordered Type         -- ^ The type should be totally ordered so
                           --   we can check less than, but it isn't.
  | Infinite Type
  | EmptyCase              -- ^ Case analyses cannot be empty.
  | NoLub Type Type        -- ^ The given types have no lub.
  | PatternType Pattern Type  -- ^ The given pattern should have the type, but it doesn't.
  | ModQ                   -- ^ Can't do mod on rationals.
  | ExpQ                   -- ^ Can't exponentiate by a rational.
  | DuplicateDecls (Name Term)  -- ^ Duplicate declarations.
  | DuplicateDefns (Name Term)  -- ^ Duplicate definitions.
  | NumPatterns            -- ^ # of patterns does not match type in definition
  | NotList Term Type      -- ^ Should have a list type, but expected to have some other type
  | NotSubtractive Type
  | NotFractional Type
  | NoError                -- ^ Not an error.  The identity of the
                           --   @Monoid TCError@ instance.
  deriving Show

-- | 'TCError' is a monoid where we simply discard the first error.
instance Monoid TCError where
  mempty = NoError
  mappend _ r = r

-- | Type checking monad. Maintains a context of variable types and a
--   set of definitions, and can throw @TCError@s and generate fresh
--   names.
type TCM = StateT DefnCtx (ReaderT TyCtx (ExceptT TCError LFreshM))

-- | Run a 'TCM' computation starting in the empty context.
runTCM :: TCM a -> Either TCError (a, DefnCtx)
runTCM = runLFreshM . runExceptT . flip runReaderT emptyCtx . flip runStateT M.empty

-- | Run a 'TCM' computation starting in the empty context, returning
--   only the result of the computation.
evalTCM :: TCM a -> Either TCError a
evalTCM = fmap fst . runTCM

-- | Run a 'TCM' computation starting in the empty context, returning
--   only the resulting definitions.
execTCM :: TCM a -> Either TCError DefnCtx
execTCM = fmap snd . runTCM

-- | Add a definition to the set of current definitions.
addDefn :: Name Term -> [Bind [Pattern] ATerm] -> TCM ()
addDefn x b = modify (M.insert (coerce x) b)

-- | Look up the type of a variable in the context.  Throw an "unbound
--   variable" error if it is not found.
lookupTy :: Name Term -> TCM Type
lookupTy x = lookup x >>= maybe (throwError (Unbound x)) return

-- | Check that a term has the given type.  Either throws an error, or
--   returns the term annotated with types for all subterms.
check :: Term -> Type -> TCM ATerm

check (TParens t) ty = check t ty

check (TTup ts) ty = do
  ats <- checkTuple ts ty
  return $ ATTup ty ats

check (TList xs ell) ty@(TyList eltTy) = do
  axs  <- mapM (flip check eltTy) xs
  aell <- checkEllipsis ell eltTy
  return $ ATList ty axs aell

check l@(TList _ _) ty            = throwError (NotList l ty)

check (TBin Cons x xs) ty@(TyList eltTy) = do
  ax  <- check x  eltTy
  axs <- check xs ty
  return $ ATBin ty Cons ax axs

check t@(TBin Cons _ _) ty     = throwError (NotList t ty)

check (TListComp bqt) ty@(TyList eltTy) = do
  lunbind bqt $ \(qs,t) -> do
  (aqs, cx) <- inferTelescope inferQual qs
  extends cx $ do
  at <- check t eltTy
  return $ ATListComp ty (bind aqs at)

check (TListComp bqt) ty    = throwError (NotList (TListComp bqt) ty)

-- To check an abstraction:
check (TAbs lam) ty = do
  lunbind lam $ \(args, t) -> do
    -- First check that the given type is of the form ty1 -> ty2 ->
    -- ... -> resTy, where the types ty1, ty2 ... match up with any
    -- types declared for the arguments to the lambda (e.g.  (x:tyA)
    -- (y:tyB) -> ...).
    (ctx, resTy) <- checkArgs args ty

    -- Then check the type of the body under a context extended with
    -- types for all the arguments.
    extends ctx $ do
    at <- check t resTy
    return $ ATAbs ty (bind ((map . first) coerce args) at)

-- To check an injection has a sum type, recursively check the
-- relevant type.
check (TInj L t) ty@(TySum ty1 _) = do
  at <- check t ty1
  return $ ATInj ty L at
check (TInj R t) ty@(TySum _ ty2) = do
  at <- check t ty2
  return $ ATInj ty R at

-- Trying to check an injection under a non-sum type: error.
check t@(TInj _ _) ty = throwError (NotSum t ty)

-- To check a let expression:
check (TLet l) ty =
  lunbind l $ \(bs, t2) -> do

    -- Infer the types of all the variables bound by the let...
    (as, ctx) <- inferTelescope inferBinding bs

    -- ...then check the body under an extended context.
    extends ctx $ do
      at2 <- check t2 ty
      return $ ATLet ty (bind as at2)

check (TCase bs) ty = do
  bs' <- mapM (checkBranch ty) bs
  return (ATCase ty bs')

-- Once upon a time, when we only had types N, Z, Q+, and Q, we could
-- always infer the type of anything numeric, so we didn't need
-- checking cases for Add, Mul, etc.  But now we could have e.g.  (a +
-- b) : Z13, in which case we need to push the checking type (in the
-- example, Z13) through the operator to check the arguments.

-- Checking addition and multiplication is the same.
check (TBin op t1 t2) ty | op `elem` [Add, Mul] =
  if (isNumTy ty)
    then do
      at1 <- check t1 ty
      at2 <- check t2 ty
      return $ ATBin ty op at1 at2
    else throwError (NotNumTy ty)

check (TBin Div t1 t2) ty = do
  _ <- checkFractional ty
  at1 <- check t1 ty
  at2 <- check t2 ty
  return $ ATBin ty Div at1 at2

check (TBin IDiv t1 t2) ty = do
  if (isNumTy ty)
    then do
      -- We are trying to check that (x // y) has type @ty@. Checking
      -- that x and y in turn have type @ty@ would be too restrictive:
      -- For example, for (x // y) to have type Nat it need not be the
      -- case that x and y also have type Nat.  It is enough in this
      -- case for them to have type Q+.  On the other hand, if (x //
      -- y) : Z5 then x and y must also have type Z5.  So we check at
      -- the lub of ty and Q+ if it exists, or ty otherwise.
      ty' <- lub ty TyQP <|> return ty

      at1 <- check t1 ty'
      at2 <- check t2 ty'
      return $ ATBin ty IDiv at1 at2
    else throwError (NotNumTy ty)

check (TBin Exp t1 t2) ty =
  if (isNumTy ty)
    then do
      -- if a^b :: fractional t, then a :: t, b :: Z
      -- else if a^b :: non-fractional t, then a :: t, b :: N
      at1 <- check t1 ty
      at2 <- check t2 (if isFractional ty then TyZ else TyN)
      return $ ATBin ty Exp at1 at2
    else throwError (NotNumTy ty)

-- Notice here we only check that ty is numeric, *not* that it is
-- subtractive.  As a special case, we allow subtraction to typecheck
-- at any numeric type; when a subtraction is performed at type N or
-- Q+, it incurs a runtime check that the result is positive.

-- XXX should make this an opt-in feature rather than on by default.
check (TBin Sub t1 t2) ty = do
  when (not (isNumTy ty)) $ throwError (NotNumTy ty)

  -- when (not (isSubtractive ty)) $ do
  --   traceM $ "Warning: checking subtraction at type " ++ show ty
  --   traceShowM $ (TBin Sub t1 t2)
    -- XXX emit a proper warning re: subtraction on N or Q+
  at1 <- check t1 ty
  at2 <- check t2 ty
  return $ ATBin ty Sub at1 at2

-- Note, we don't have the same special case for Neg as for Sub, since
-- unlike subtraction, which can sometimes make sense on N or QP, it
-- never makes sense to negate a value of type N or QP.
check (TUn Neg t) ty = do
  _ <- checkSubtractive ty
  at <- check t ty
  return $ ATUn ty Neg at

check (TNat x) (TyFin n) =
  return $ ATNat (TyFin n) x


-- Finally, to check anything else, we can fall back to inferring its
-- type and then check that the inferred type is a *subtype* of the
-- given type.
check t ty = do
  at <- infer t
  checkSub at ty


-- | Given the variables and their optional type annotations in the
--   head of a lambda (e.g.  @x (y:Z) (f : N -> N) -> ...@), and the
--   type at which we are checking the lambda, ensure that the type is
--   of the form @ty1 -> ty2 -> ... -> resTy@, and that there are
--   enough @ty1@, @ty2@, ... to match all the arguments.  Also check
--   that each binding with a type annotation matches the
--   corresponding ty_i component from the checking type: in
--   particular, the ty_i must be a subtype of the type annotation.
--   If it succeeds, return a context binding variables to their types
--   (taken either from their annotation or from the type to be
--   checked, as appropriate) which we can use to extend when checking
--   the body, along with the result type of the function.
checkArgs :: [(Name Term, Embed (Maybe Type))] -> Type -> TCM (TyCtx, Type)

-- If we're all out of arguments, the remaining checking type is the
-- result, and there are no variables to bind in the context.
checkArgs [] ty = return (emptyCtx, ty)

-- Take the next variable and its annotation; the checking type must
-- be a function type ty1 -> ty2.
checkArgs ((x, unembed -> mty) : args) (TyArr ty1 ty2) = do

  -- Figure out the type of x:
  xTy <- case mty of

    -- If it has no annotation, just take the input type ty1.
    Nothing    -> return ty1

    -- If it does have an annotation, make sure the input type is a
    -- subtype of it.
    Just annTy ->
      case isSub ty1 annTy of
        False -> throwError $ Mismatch ty1 (ATVar annTy (coerce x))
        True  -> return annTy

  -- Check the rest of the arguments under the type ty2, returning a
  -- context with the rest of the arguments and the final result type.
  (ctx, resTy) <- checkArgs args ty2

  -- Pass the result type through, and add x with its type to the
  -- generated context.
  return (singleCtx x xTy `joinCtx` ctx, resTy)

-- Otherwise, we are trying to check some lambda arguments under a
-- non-arrow type.
checkArgs _args _ty = error $ "checkArgs --- Make a better error here!"


-- | Check the types of terms in a tuple against a nested
--   pair type.
checkTuple :: [Term] -> Type -> TCM [ATerm]
checkTuple [] _   = error "Impossible! checkTuple []"
checkTuple [t] ty = do     -- (:[]) <$> check t ty
  at <- check t ty
  return [at]
checkTuple (t:ts) (TyPair ty1 ty2) = do
  at  <- check t ty1
  ats <- checkTuple ts ty2
  return (at:ats)
checkTuple ts ty = throwError $ NotTuple (TTup ts) ty

checkEllipsis :: Maybe (Ellipsis Term) -> Type -> TCM (Maybe (Ellipsis ATerm))
checkEllipsis Nothing          _  = return Nothing
checkEllipsis (Just Forever)   _  = return (Just Forever)
checkEllipsis (Just (Until t)) ty = (Just . Until) <$> check t ty

-- | Check the type of a branch, returning a type-annotated branch.
checkBranch :: Type -> Branch -> TCM ABranch
checkBranch ty b =
  lunbind b $ \(gs, t) -> do
  (ags, ctx) <- inferTelescope inferGuard gs
  extends ctx $ do
  at <- check t ty
  return $ bind ags at

-- | Check that the given annotated term has a type which is a subtype
--   of the given type.  The returned annotated term may be the same
--   as the input, or it may be wrapped in 'ATSub' if we made a
--   nontrivial use of subtyping.
checkSub :: ATerm -> Type -> TCM ATerm
checkSub at ty =
  case isSub (getType at) ty of
    True  -> return at
    False -> throwError (Mismatch ty at)

-- | Check whether one type is a subtype of another (we have decidable
--   subtyping).
isSub :: Type -> Type -> Bool
isSub ty1 ty2 | ty1 == ty2 = True
isSub TyVoid _ = True
isSub TyN TyZ  = True
isSub TyN TyQP = True
isSub TyN TyQ  = True
isSub TyZ TyQ  = True
isSub TyQP TyQ = True
isSub (TyArr t1 t2) (TyArr t1' t2')   = isSub t1' t1 && isSub t2 t2'
isSub (TyPair t1 t2) (TyPair t1' t2') = isSub t1 t1' && isSub t2 t2'
isSub (TySum  t1 t2) (TySum  t1' t2') = isSub t1 t1' && isSub t2 t2'
isSub _ _ = False

-- | Compute the least upper bound (least common supertype) of two
--   types.  Return the LUB, or throw an error if there isn't one.
lub :: Type -> Type -> TCM Type
lub ty1 ty2
  | isSub ty1 ty2 = return ty2
  | isSub ty2 ty1 = return ty1
lub TyQP TyZ = return TyQ
lub TyZ TyQP = return TyQ
lub (TyArr t1 t2) (TyArr t1' t2') = do
  requireSameTy t1 t1'
  t2'' <- lub t2 t2'
  return $ TyArr t1 t2''
lub (TyPair t1 t2) (TyPair t1' t2') = do
  t1'' <- lub t1 t1'
  t2'' <- lub t2 t2'
  return $ TyPair t1'' t2''
lub (TySum t1 t2) (TySum t1' t2') = do
  t1'' <- lub t1 t1'
  t2'' <- lub t2 t2'
  return $ TySum t1'' t2''
lub (TyList t1) (TyList t2) = do
  t' <- lub t1 t2
  return $ TyList t'
lub ty1 ty2 = throwError $ NoLub ty1 ty2

-- | Recursively computes the least upper bound of a list of Types.
lubs :: [Type] -> TCM Type
lubs [ty]     = return $ ty
lubs (ty:tys) = do
  lubstys  <- lubs tys
  lubty    <- lub ty lubstys
  return $ lubty
lubs []       = error "Impossible! Called lubs on an empty list"

-- | Convenience function that ensures the given annotated terms have
--   numeric types, AND computes their LUB.
numLub :: ATerm -> ATerm -> TCM Type
numLub at1 at2 = do
  checkNumTy at1
  checkNumTy at2
  lub (getType at1) (getType at2)

-- | Check whether the given type supports division, and throw an
--   error if not.
checkFractional :: Type -> TCM Type
checkFractional ty =
  if (isNumTy ty)
    then case isFractional ty of
      True  -> return ty
      False -> throwError $ NotFractional ty
    else throwError $ NotNumTy ty

-- | Check whether the given type supports subtraction, and throw an
--   error if not.
checkSubtractive :: Type -> TCM Type
checkSubtractive ty =
  if (isNumTy ty)
    then case isSubtractive ty of
      True  -> return ty
      False -> throwError $ NotSubtractive ty
  else throwError $ NotNumTy ty

-- | Check whether the given type is finite, and throw an error if not.
checkFinite :: Type -> TCM ()
checkFinite ty
  | isFinite ty = return ()
  | otherwise   = throwError $ Infinite ty

-- | Check whether the given type has decidable equality, and throw an
--   error if not.
checkDecidable :: Type -> TCM ()
checkDecidable ty
  | isDecidable ty = return ()
  | otherwise      = throwError $ Undecidable ty

-- | Check whether the given type has a total order, and throw an
--   error if not.
checkOrdered :: Type -> TCM ()
checkOrdered ty
  | isOrdered ty = return ()
  | otherwise    = throwError $ Unordered ty

-- | Require two types to be equal.
requireSameTy :: Type -> Type -> TCM ()
requireSameTy ty1 ty2
  | ty1 == ty2 = return ()
  | otherwise  = throwError $ IncompatibleTypes ty1 ty2

-- | Require a term to have a function type, returning the decomposed
--   type if it does, throwing an error if not.
getFunTy :: ATerm -> TCM (Type, Type)
getFunTy (getType -> TyArr ty1 ty2) = return (ty1, ty2)
getFunTy at = throwError (NotFun at)

-- | Check that an annotated term has a numeric type.  Throw an error
--   if not.
checkNumTy :: ATerm -> TCM ()
checkNumTy at =
  if (isNumTy $ getType at)
     then return ()
     else throwError (NotNum at)

-- | Convert a numeric type to its greatest subtype that does not
--   support division.  In particular this is used for the typing rule
--   of the floor and ceiling functions.
integralizeTy :: Type -> Type
integralizeTy TyQ   = TyZ
integralizeTy TyQP  = TyN
integralizeTy t     = t

-- | Convert a numeric type to its greatest subtype that does not
--   support subtraction.  In particular this is used for the typing
--   rule of the absolute value function.
positivizeTy :: Type -> Type
positivizeTy TyZ  = TyN
positivizeTy TyQ  = TyQP
positivizeTy t    = t

-- | Infer the type of a term.  If it succeeds, it returns the term
--   with all subterms annotated.
infer :: Term -> TCM ATerm

infer (TParens t)   = infer t

  -- To infer the type of a variable, just look it up in the context.
infer (TVar x)      = do
  ty <- lookupTy x
  return $ ATVar ty (coerce x)

  -- A few trivial cases.
infer TUnit         = return ATUnit
infer (TBool b)     = return $ ATBool b
infer (TNat n)      = return $ ATNat TyN n
infer (TRat r)      = return $ ATRat r

  -- We can infer the type of a lambda if the variable is annotated
  -- with a type.
infer (TAbs lam)    =
  lunbind lam $ \(args, t) -> do
    let (xs, mtys) = unzip args
    case sequence (map unembed mtys) of
      Nothing  -> throwError (CantInfer (TAbs lam))
      Just tys -> extends (M.fromList $ zip xs tys) $ do
        at <- infer t
        return $ ATAbs (mkFunTy tys (getType at))
                       (bind (zip (map coerce xs) (map (embed . Just) tys)) at)
  where
    -- mkFunTy [ty1, ..., tyn] out = ty1 -> (ty2 -> ... (tyn -> out))
    mkFunTy :: [Type] -> Type -> Type
    mkFunTy tys out = foldr TyArr out tys

  -- Infer the type of a function application by inferring the
  -- function type and then checking the argument type.
infer (TApp t t')   = do
  at <- infer t
  (ty1, ty2) <- getFunTy at
  at' <- check t' ty1
  return $ ATApp ty2 at at'

  -- To infer the type of a pair, just infer the types of both components.
infer (TTup ts) = do
  (ty, ats) <- inferTuple ts
  return $ ATTup ty ats

  -- To infer the type of addition or multiplication, infer the types
  -- of the subterms, check that they are numeric, and return their
  -- lub.
infer (TBin Add t1 t2) = do
  at1 <- infer t1
  at2 <- infer t2
  num3 <- numLub at1 at2
  return $ ATBin num3 Add at1 at2
infer (TBin Mul t1 t2) = do
  at1 <- infer t1
  at2 <- infer t2
  num3 <- numLub at1 at2
  return $ ATBin num3 Mul at1 at2

  -- Subtraction is similar, except that we must also lub with Z (a
  -- Nat minus a Nat is not a Nat, it is an Int).
infer (TBin Sub t1 t2) = do
  at1 <- infer t1
  at2 <- infer t2
  num3 <- numLub at1 at2
  num4 <- lub num3 TyZ <|> checkSubtractive num3
  return $ ATBin num4 Sub at1 at2

  -- Negation is similar to subtraction.
infer (TUn Neg t) = do
  at <- infer t
  checkNumTy at
  let ty = getType at
  num2 <- lub ty TyZ <|> checkSubtractive ty
  return $ ATUn num2 Neg at

infer (TUn Sqrt t) = do
  at <- check t TyN
  return $ ATUn TyN Sqrt at

infer (TUn Lg t)  = do
  at <- check t TyN
  return $ ATUn TyN Lg at

infer (TUn Floor t) = do
  at <- infer t
  checkNumTy at
  let num2 = getType at
  return $ ATUn (integralizeTy num2) Floor at

infer (TUn Ceil t) = do
  at <- infer t
  checkNumTy at
  let num2 = getType at
  return $ ATUn (integralizeTy num2) Ceil at

infer (TUn Abs t) = do
  at <- infer t
  checkNumTy at
  return $ ATUn (positivizeTy (getType at)) Abs at

  -- Division is similar to subtraction; we must take the lub with Q+.
infer (TBin Div t1 t2) = do
  at1 <- infer t1
  at2 <- infer t2
  num3 <- numLub at1 at2
  num4 <- lub num3 TyQP <|> checkFractional num3
  return $ ATBin num4 Div at1 at2

 -- Very similar to division
infer (TBin IDiv t1 t2) = do
  at1 <- infer t1
  at2 <- infer t2
  num3 <- numLub at1 at2
  let num4 = integralizeTy num3
  return $ ATBin num4 IDiv at1 at2

infer (TBin Exp t1 t2) = do
  at1 <- infer t1
  at2 <- infer t2
  checkNumTy at1
  checkNumTy at2
  case getType at2 of

    -- t1^n has the same type as t1 when n : Nat.
    TyN -> return $ ATBin (getType at1) Exp at1 at2

    -- t1^z has type (lub ty1 Q+) when t1 : ty1 and z : Z.
    -- For example, (-3)^(-5) has type Q (= lub Z Q+)
    -- but 3^(-5) has type Q+.
    TyZ -> do
      res <- lub (getType at1) TyQP <|> checkFractional (getType at1)
      return $ ATBin res Exp at1 at2
    TyQ -> throwError ExpQ
    _   -> error "Impossible! getType at2 is not num type after checkNumTy"

  -- An equality or inequality test always has type Bool, but we need
  -- to check a few things first. We infer the types of both subterms
  -- and check that (1) they have a common supertype which (2) has
  -- decidable equality.
infer (TBin eqOp t1 t2) | eqOp `elem` [Eq, Neq] = do
  at1 <- infer t1
  at2 <- infer t2
  ty3 <- lub (getType at1) (getType at2)
  checkDecidable ty3
  return $ ATBin TyBool eqOp at1 at2

infer (TBin op t1 t2)
  | op `elem` [Lt, Gt, Leq, Geq] = inferComp op t1 t2

  -- &&, ||, and not always have type Bool, and the subterms must have type
  -- Bool as well.
infer (TBin And t1 t2) = do
  at1 <- check t1 TyBool
  at2 <- check t2 TyBool
  return $ ATBin TyBool And at1 at2
infer (TBin Or t1 t2) = do
  at1 <- check t1 TyBool
  at2 <- check t2 TyBool
  return $ ATBin TyBool Or at1 at2
infer (TUn Not t) = do
  at <- check t TyBool
  return $ ATUn TyBool Not at

infer (TBin Mod t1 t2) = do
  at1 <- infer t1
  at2 <- infer t2
  ty <- numLub at1 at2
  if (isSub ty TyZ)
    then return (ATBin ty Mod at1 at2)
    else throwError ModQ

infer (TBin Divides t1 t2) = do
  at1 <- infer t1
  at2 <- infer t2
  _ <- numLub at1 at2
  return (ATBin TyBool Divides at1 at2)

-- For now, a simple typing rule for multinomial coefficients that
-- requires everything to be Nat.  However, they can be extended to
-- handle negative or fractional arguments.
infer (TBin Choose t1 t2) = do
  at1 <- check t1 TyN

  -- t2 can be either a Nat (a binomial coefficient)
  -- or a list of Nat (a multinomial coefficient).
  at2 <- check t2 TyN <|> check t2 (TyList TyN)
  return $ ATBin TyN Choose at1 at2

-- To infer the type of a cons:
infer (TBin Cons t1 t2) = do

  -- First, infer the type of the first argument (a list element).
  at1 <- infer t1

  case t2 of
    -- If the second argument is the empty list, just assign it the
    -- type inferred from the first element.
    TList [] Nothing -> do
      let ty1 = getType at1
      return $ ATBin (TyList ty1) Cons at1 (ATList (TyList ty1) [] Nothing)

    -- Otherwise, infer the type of the second argument...
    _ -> do
      at2 <- infer t2
      case (getType at2) of

        -- ...make sure it is a list, and find the lub of the element types.
        TyList ty2 -> do
          elTy <- lub (getType at1) ty2
          return $ ATBin (TyList elTy) Cons at1 at2
        ty -> throwError (NotList t2 ty)

infer (TUn Fact t) = do
  at <- check t TyN
  return $ ATUn TyN Fact at

infer (TChain t1 links) = do
  at1 <- infer t1
  alinks <- inferChain t1 links
  return $ ATChain TyBool at1 alinks

infer (TList es@(_:_) ell)  = do
  ates <- mapM infer es
  aell <- inferEllipsis ell
  let tys = [ getType at | Just (Until at) <- [aell] ] ++ (map getType) ates
  ty  <- lubs tys
  return $ ATList (TyList ty) ates aell

infer (TListComp bqt) = do
  lunbind bqt $ \(qs,t) -> do
  (aqs, cx) <- inferTelescope inferQual qs
  extends cx $ do
  at <- infer t
  let ty = getType at
  return $ ATListComp (TyList ty) (bind aqs at)

infer (TTyOp Enumerate t) = do
  checkFinite t
  return $ ATTyOp (TyList t) Enumerate t

infer (TTyOp Count t) = do
  checkFinite t
  return $ ATTyOp TyN Count t

  -- To infer the type of (let x = t1 in t2), assuming it is
  -- NON-RECURSIVE, infer the type of t1, and then infer the type of
  -- t2 in an extended context.
infer (TLet l) = do
  lunbind l $ \(bs, t2) -> do
  (as, ctx) <- inferTelescope inferBinding bs
  extends ctx $ do
  at2 <- infer t2
  return $ ATLet (getType at2) (bind as at2)

  -- Ascriptions are what let us flip from inference mode into
  -- checking mode.
infer (TAscr t ty) = do
  at <- check t ty
  return $ ATAscr at ty

infer (TCase []) = throwError EmptyCase
infer (TCase bs) = inferCase bs

  -- Catch-all case at the end: if we made it here, we can't infer it.
infer t = throwError (CantInfer t)

-- | Infer the type of a binding (@x [: ty] = t@), returning a
--   type-annotated binding along with a (singleton) context for the
--   bound variable.  The optional type annotation on the variable
--   determines whether we use inference or checking mode for the
--   body.
inferBinding :: Binding -> TCM (ABinding, TyCtx)
inferBinding (Binding mty x (unembed -> t)) = do
  at <- case mty of
    Just ty -> check t ty
    Nothing -> infer t
  return $ (ABinding mty (coerce x) (embed at), singleCtx x (getType at))

-- | Infer the type of a comparison. A comparison always has type
--   Bool, but we have to make sure the subterms are OK. We must check
--   that their types are compatible and have a total order.
inferComp :: BOp -> Term -> Term -> TCM ATerm
inferComp comp t1 t2 = do
  at1 <- infer t1
  at2 <- infer t2
  ty3 <- lub (getType at1) (getType at2)
  checkOrdered ty3
  return $ ATBin TyBool comp at1 at2

inferChain :: Term -> [Link] -> TCM [ALink]
inferChain _  [] = return []
inferChain t1 (TLink op t2 : links) = do
  at2 <- infer t2
  _   <- check (TBin op t1 t2) TyBool
  (ATLink op at2 :) <$> inferChain t2 links

inferEllipsis :: Maybe (Ellipsis Term) -> TCM (Maybe (Ellipsis ATerm))
inferEllipsis (Just (Until t)) = (Just . Until) <$> infer t
inferEllipsis (Just Forever)   = return $ Just Forever
inferEllipsis Nothing          = return Nothing

inferTuple :: [Term] -> TCM (Type, [ATerm])
inferTuple []     = error "Impossible! inferTuple []"
inferTuple [t]    = do
  at <- infer t
  return (getType at, [at])
inferTuple (t:ts) = do
  at <- infer t
  (ty, ats) <- inferTuple ts
  return (TyPair (getType at) ty, at:ats)

-- | Infer the type of a case expression.  The result type is the
--   least upper bound (if it exists) of all the branches.
inferCase :: [Branch] -> TCM ATerm
inferCase bs = do
  bs' <- mapM inferBranch bs
  let (branchTys, abs') = unzip bs'
  resTy <- foldM lub TyVoid branchTys
  return $ ATCase resTy abs'

-- | Infer the type of a case branch, returning the type along with a
--   type-annotated branch.
inferBranch :: Branch -> TCM (Type, ABranch)
inferBranch b =
  lunbind b $ \(gs, t) -> do
  (ags, ctx) <- inferTelescope inferGuard gs
  extends ctx $ do
  at <- infer t
  return $ (getType at, bind ags at)

-- | Infer the type of a telescope, given a way to infer the type of
--   each item along with a context of variables it binds; each such
--   context is then added to the overall context when inferring
--   subsequent items in the telescope.
inferTelescope
  :: (Alpha b, Alpha tyb)
  => (b -> TCM (tyb, TyCtx)) -> Telescope b -> TCM (Telescope tyb, TyCtx)
inferTelescope inferOne tel = first toTelescope <$> go (fromTelescope tel)
  where
    go []     = return ([], emptyCtx)
    go (b:bs) = do
      (tyb, ctx) <- inferOne b
      extends ctx $ do
      (tybs, ctx') <- go bs
      return (tyb:tybs, ctx `joinCtx` ctx')

-- | Infer the type of a guard, returning the type-annotated guard
--   along with a context of types for any variables bound by the guard.
inferGuard :: Guard -> TCM (AGuard, TyCtx)
inferGuard (GBool (unembed -> t)) = do
  at <- check t TyBool
  return (AGBool (embed at), emptyCtx)
inferGuard (GPat (unembed -> t) p) = do
  at <- infer t
  ctx <- checkPattern p (getType at)
  return (AGPat (embed at) p, ctx)

inferQual :: Qual -> TCM (AQual, TyCtx)
inferQual (QBind x (unembed -> t))  = do
  at <- infer t
  case getType at of
    TyList ty -> return (AQBind (coerce x) (embed at), singleCtx x ty)
    wrongTy   -> throwError $ NotList t wrongTy
inferQual (QGuard (unembed -> t))   = do
  at <- check t TyBool
  return (AQGuard (embed at), emptyCtx)

-- | Check that a pattern has the given type, and return a context of
--   pattern variables bound in the pattern along with their types.
checkPattern :: Pattern -> Type -> TCM TyCtx
checkPattern (PVar x) ty                    = return $ singleCtx x ty
checkPattern PWild    _                     = ok
checkPattern PUnit TyUnit                   = ok
checkPattern (PBool _) TyBool               = ok
checkPattern (PTup ps) ty                   =
  joinCtxs <$> checkTuplePat ps ty
checkPattern (PInj L p) (TySum ty1 _)       = checkPattern p ty1
checkPattern (PInj R p) (TySum _ ty2)       = checkPattern p ty2

-- we can match any supertype of TyN against a Nat pattern, OR
-- any TyFin.
checkPattern (PNat _) ty | isSub TyN ty = ok
checkPattern (PNat _) (TyFin _)         = ok

checkPattern (PSucc p)  TyN                 = checkPattern p TyN
checkPattern (PCons p1 p2) (TyList ty)      =
  joinCtx <$> checkPattern p1 ty <*> checkPattern p2 (TyList ty)
checkPattern (PList ps) (TyList ty) =
  joinCtxs <$> mapM (flip checkPattern ty) ps

checkPattern p ty = throwError (PatternType p ty)

checkTuplePat :: [Pattern] -> Type -> TCM [TyCtx]
checkTuplePat [] _   = error "Impossible! checkTuplePat []"
checkTuplePat [p] ty = do     -- (:[]) <$> check t ty
  ctx <- checkPattern p ty
  return [ctx]
checkTuplePat (p:ps) (TyPair ty1 ty2) = do
  ctx  <- checkPattern p ty1
  ctxs <- checkTuplePat ps ty2
  return (ctx:ctxs)
checkTuplePat ps ty = throwError $ NotTuplePattern (PTup ps) ty

-- | Successfully return the empty context.  A convenience method for
--   checking patterns that bind no variables.
ok :: TCM TyCtx
ok = return emptyCtx

-- | Check all the types in a module, returning a context of types for
--   top-level definitions.
checkModule :: Module -> TCM (Ctx Term Docs, Ctx ATerm [AProperty], TyCtx)
checkModule (Module m docs) = do
  let (defns, typeDecls) = partition isDefn m
  withTypeDecls typeDecls $ do
    mapM_ checkDefn defns
    aprops <- checkProperties docs
    (docs,aprops,) <$> ask

-- | Run a type checking computation in the context of some type
--   declarations. First check that there are no duplicate type
--   declarations; then run the computation in a context extended with
--   the declared types.
--
--   Precondition: only called on 'DType's.
withTypeDecls :: [Decl] -> TCM a -> TCM a
withTypeDecls decls k = do
  let dups :: [(Name Term, Int)]
      dups = filter ((>1) . snd) . map (head &&& length) . group . sort . map declName $ decls
  case dups of
    ((x,_):_) -> throwError (DuplicateDecls x)
    []        -> extends declCtx k
  where
    declCtx = M.fromList $ map getDType decls

    getDType (DType x ty) = (x,ty)
    getDType d            = error $ "Impossible! withTypeDecls.getDType called on non-DType: " ++ show d

-- | Type check a top-level definition. Precondition: only called on
--   'DDefn's.
checkDefn :: Decl -> TCM ()
checkDefn (DDefn x clauses) = do
  ty <- lookupTy x
  prevDefn <- gets (M.lookup (coerce x))
  case prevDefn of
    Just _ -> throwError (DuplicateDefns x)
    Nothing -> do
      checkNumPats clauses
      aclauses <- mapM (checkClause ty) clauses
      addDefn x aclauses
  where
    numPats = length . fst . unsafeUnbind

    checkNumPats []     = return ()   -- This can't happen, but meh
    checkNumPats [_]    = return ()
    checkNumPats (c:cs)
      | all ((==0) . numPats) (c:cs) = throwError (DuplicateDefns x)
      | not (all (== numPats c) (map numPats cs)) = throwError NumPatterns
               -- XXX more info, this error actually means # of
               -- patterns don't match across different clauses
      | otherwise = return ()

    checkClause ty clause =
      lunbind clause $ \(pats, body) -> do
      at <- go pats ty body
      return $ bind pats at

    go [] ty body = check body ty
    go (p:ps) (TyArr ty1 ty2) body = do
      ctx <- checkPattern p ty1
      extends ctx $ go ps ty2 body
    go _ _ _ = throwError NumPatterns   -- XXX include more info

checkDefn d = error $ "Impossible! checkDefn called on non-Defn: " ++ show d

-- | Given a context mapping names to documentation, extract the
--   properties attached to each name and typecheck them.
checkProperties :: Ctx Term Docs -> TCM (Ctx ATerm [AProperty])
checkProperties docs =
  (M.mapKeys coerce . M.filter (not.null))
    <$> (traverse . traverse) checkProperty properties
  where
    properties :: Ctx Term [Property]
    properties = M.map (\ds -> [p | DocProperty p <- ds]) docs

-- | Check the types of the terms embedded in a property.
checkProperty :: Property -> TCM AProperty
checkProperty prop = do

  -- A property looks like  forall (x1:ty1) ... (xn:tyn). term.
  lunbind prop $ \(binds, t) -> do

  -- Extend the context with (x1:ty1) ... (xn:tyn) ...
  extends (M.fromList binds) $ do

  -- ... and check that the term has type Bool.
  at <- check t TyBool

  -- We just have to fix up the types of the variables.
  return $ bind (binds & traverse . _1 %~ coerce) at

------------------------------------------------------------
-- Erasure
------------------------------------------------------------

-- | Erase all the type annotations from a term.
erase :: ATerm -> Term
erase (ATVar _ x)           = TVar (coerce x)
erase (ATLet _ bs)          = TLet $ bind (mapTelescope eraseBinding tel) (erase at)
  where (tel,at) = unsafeUnbind bs
erase ATUnit                = TUnit
erase (ATBool b)            = TBool b
erase (ATNat _ i)           = TNat i
erase (ATRat r)             = TRat r
erase (ATAbs _ b)           = TAbs $ bind (coerce x) (erase at)
  where (x,at) = unsafeUnbind b
erase (ATApp _ t1 t2)       = TApp (erase t1) (erase t2)
erase (ATTup _ ats)         = TTup (map erase ats)
erase (ATInj _ s at)        = TInj s (erase at)
erase (ATCase _ brs)        = TCase (map eraseBranch brs)
erase (ATUn _ uop at)       = TUn uop (erase at)
erase (ATBin _ bop at1 at2) = TBin bop (erase at1) (erase at2)
erase (ATChain _ at lnks)   = TChain (erase at) (map eraseLink lnks)
erase (ATTyOp _ op ty)      = TTyOp op ty
erase (ATList _ ats aell)   = TList (map erase ats) ((fmap . fmap) erase aell)
erase (ATListComp _ b)      = TListComp $ bind (mapTelescope eraseQual tel) (erase at)
  where (tel,at) = unsafeUnbind b
erase (ATAscr at ty)        = TAscr (erase at) ty

eraseBinding :: ABinding -> Binding
eraseBinding (ABinding mty x (unembed -> at)) = Binding mty (coerce x) (embed (erase at))

eraseBranch :: ABranch -> Branch
eraseBranch b = bind (mapTelescope eraseGuard tel) (erase at)
  where (tel,at) = unsafeUnbind b

eraseGuard :: AGuard -> Guard
eraseGuard (AGBool (unembed -> at))  = GBool (embed (erase at))
eraseGuard (AGPat (unembed -> at) p) = GPat (embed (erase at)) p

eraseLink :: ALink -> Link
eraseLink (ATLink bop at) = TLink bop (erase at)

eraseQual :: AQual -> Qual
eraseQual (AQBind x (unembed -> at)) = QBind (coerce x) (embed (erase at))
eraseQual (AQGuard (unembed -> at))  = QGuard (embed (erase at))

eraseProperty :: AProperty -> Property
eraseProperty b = bind ((map . first) coerce xs) (erase at)
  where (xs, at) = unsafeUnbind b
