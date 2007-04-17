-----------------------------------------------------------------------------
--
-- GHC Interactive support for inspecting arbitrary closures at runtime
--
-- Pepe Iborra (supported by Google SoC) 2006
--
-----------------------------------------------------------------------------

module RtClosureInspect(
  
     cvObtainTerm,       -- :: HscEnv -> Bool -> Maybe Type -> HValue -> IO Term

     ClosureType(..), 
     getClosureData,     -- :: a -> IO Closure
     Closure ( tipe, infoPtr, ptrs, nonPtrs ), 
     isConstr,           -- :: ClosureType -> Bool
     isIndirection,      -- :: ClosureType -> Bool

     Term(..), 
     printTerm, 
     customPrintTerm, 
     customPrintTermBase,
     termType,
     foldTerm, 
     TermFold(..), 
     idTermFold, 
     idTermFoldM,
     isFullyEvaluated, 
     isPointed,
     isFullyEvaluatedTerm,
--     unsafeDeepSeq, 
 ) where 

#include "HsVersions.h"

import ByteCodeItbls    ( StgInfoTable )
import qualified ByteCodeItbls as BCI( StgInfoTable(..) )
import ByteCodeLink     ( HValue )
import HscTypes         ( HscEnv )

import DataCon          
import Type             
import TcRnMonad        ( TcM, initTcPrintErrors, ioToTcRn, recoverM, writeMutVar )
import TcType
import TcMType
import TcUnify
import TcGadt
import TyCon		
import Var
import Name 
import VarEnv
import OccName
import VarSet
import {-#SOURCE#-} TcRnDriver ( tcRnRecoverDataCon )

import TysPrim		
import PrelNames
import TysWiredIn

import Constants        ( wORD_SIZE )
import Outputable
import Maybes
import Panic
import FiniteMap

import GHC.Arr          ( Array(..) )
import GHC.Ptr          ( Ptr(..), castPtr )
import GHC.Exts         
import GHC.Int          ( Int32(..),  Int64(..) )
import GHC.Word         ( Word32(..), Word64(..) )

import Control.Monad
import Data.Maybe
import Data.Array.Base
import Data.List        ( partition )
import Foreign.Storable

import IO

---------------------------------------------
-- * A representation of semi evaluated Terms
---------------------------------------------
{-
  A few examples in this representation:

  > Just 10 = Term Data.Maybe Data.Maybe.Just (Just 10) [Term Int I# (10) "10"]

  > (('a',_,_),_,('b',_,_)) = 
      Term ((Char,b,c),d,(Char,e,f)) (,,) (('a',_,_),_,('b',_,_))
          [ Term (Char, b, c) (,,) ('a',_,_) [Term Char C# "a", Thunk, Thunk]
          , Thunk
          , Term (Char, e, f) (,,) ('b',_,_) [Term Char C# "b", Thunk, Thunk]]
-}

data Term = Term { ty        :: Type 
                 , dc        :: DataCon 
                 , val       :: HValue 
                 , subTerms  :: [Term] }

          | Prim { ty        :: Type
                 , value     :: String }

          | Suspension { ctype    :: ClosureType
                       , mb_ty    :: Maybe Type
                       , val      :: HValue
                       , bound_to :: Maybe Name   -- Useful for printing
                       }

isTerm Term{} = True
isTerm   _    = False
isSuspension Suspension{} = True
isSuspension      _       = False
isPrim Prim{} = True
isPrim   _    = False

termType t@(Suspension {}) = mb_ty t
termType t = Just$ ty t

isFullyEvaluatedTerm :: Term -> Bool
isFullyEvaluatedTerm Term {subTerms=tt} = all isFullyEvaluatedTerm tt
isFullyEvaluatedTerm Suspension {}      = False
isFullyEvaluatedTerm Prim {}            = True

instance Outputable (Term) where
 ppr = head . customPrintTerm customPrintTermBase

-------------------------------------------------------------------------
-- Runtime Closure Datatype and functions for retrieving closure related stuff
-------------------------------------------------------------------------
data ClosureType = Constr 
                 | Fun 
                 | Thunk Int 
                 | ThunkSelector
                 | Blackhole 
                 | AP 
                 | PAP 
                 | Indirection Int 
                 | Other Int
 deriving (Show, Eq)

data Closure = Closure { tipe         :: ClosureType 
                       , infoPtr      :: Ptr ()
                       , infoTable    :: StgInfoTable
                       , ptrs         :: Array Int HValue
                        -- What would be the type here? HValue is ok? Should I build a Ptr?
                       , nonPtrs      :: ByteArray# 
                       }

instance Outputable ClosureType where
  ppr = text . show 

#include "../includes/ClosureTypes.h"

aP_CODE = AP
pAP_CODE = PAP
#undef AP
#undef PAP

getClosureData :: a -> IO Closure
getClosureData a =
   case unpackClosure# a of 
     (# iptr, ptrs, nptrs #) -> do
           itbl <- peek (Ptr iptr)
           let tipe = readCType (BCI.tipe itbl)
               elems = BCI.ptrs itbl 
               ptrsList = Array 0 (fromIntegral$ elems) ptrs
           ptrsList `seq` return (Closure tipe (Ptr iptr) itbl ptrsList nptrs)

readCType :: Integral a => a -> ClosureType
readCType i
 | i >= CONSTR && i <= CONSTR_NOCAF_STATIC = Constr
 | i >= FUN    && i <= FUN_STATIC          = Fun
 | i >= THUNK  && i < THUNK_SELECTOR       = Thunk (fromIntegral i)
 | i == THUNK_SELECTOR                     = ThunkSelector
 | i == BLACKHOLE                          = Blackhole
 | i >= IND    && i <= IND_STATIC          = Indirection (fromIntegral i)
 | fromIntegral i == aP_CODE               = AP
 | fromIntegral i == pAP_CODE              = PAP
 | otherwise                               = Other (fromIntegral i)

isConstr, isIndirection :: ClosureType -> Bool
isConstr Constr = True
isConstr    _   = False

isIndirection (Indirection _) = True
--isIndirection ThunkSelector = True
isIndirection _ = False

isFullyEvaluated :: a -> IO Bool
isFullyEvaluated a = do 
  closure <- getClosureData a 
  case tipe closure of
    Constr -> do are_subs_evaluated <- amapM isFullyEvaluated (ptrs closure)
                 return$ and are_subs_evaluated
    otherwise -> return False
  where amapM f = sequence . amap' f

amap' f (Array i0 i arr#) = map (\(I# i#) -> case indexArray# arr# i# of
                                   (# e #) -> f e)
                                [0 .. i - i0]

-- TODO: Fix it. Probably the otherwise case is failing, trace/debug it
{-
unsafeDeepSeq :: a -> b -> b
unsafeDeepSeq = unsafeDeepSeq1 2
 where unsafeDeepSeq1 0 a b = seq a $! b
       unsafeDeepSeq1 i a b                -- 1st case avoids infinite loops for non reducible thunks
        | not (isConstr tipe) = seq a $! unsafeDeepSeq1 (i-1) a b     
     -- | unsafePerformIO (isFullyEvaluated a) = b
        | otherwise = case unsafePerformIO (getClosureData a) of
                        closure -> foldl' (flip unsafeDeepSeq) b (ptrs closure)
        where tipe = unsafePerformIO (getClosureType a)
-}
isPointed :: Type -> Bool
isPointed t | Just (t, _) <- splitTyConApp_maybe t = not$ isUnliftedTypeKind (tyConKind t)
isPointed _ = True

#define MKDECODER(offset,cons,builder) (offset, show$ cons (builder addr 0#))

extractUnboxed  :: [Type] -> ByteArray# -> [String]
extractUnboxed tt ba = helper tt (byteArrayContents# ba)
   where helper :: [Type] -> Addr# -> [String]
         helper (t:tt) addr 
          | Just ( tycon,_) <- splitTyConApp_maybe t 
          =  let (offset, txt) = decode tycon addr
                 (I# word_offset)   = offset*wORD_SIZE
             in txt : helper tt (plusAddr# addr word_offset)
          | otherwise 
          = -- ["extractUnboxed.helper: Urk. I got a " ++ showSDoc (ppr t)]
            panic$ "extractUnboxed.helper: Urk. I got a " ++ showSDoc (ppr t)
         helper [] addr = []
         decode :: TyCon -> Addr# -> (Int, String)
         decode t addr                             
           | t == charPrimTyCon   = MKDECODER(1,C#,indexCharOffAddr#)
           | t == intPrimTyCon    = MKDECODER(1,I#,indexIntOffAddr#)
           | t == wordPrimTyCon   = MKDECODER(1,W#,indexWordOffAddr#)
           | t == floatPrimTyCon  = MKDECODER(1,F#,indexFloatOffAddr#)
           | t == doublePrimTyCon = MKDECODER(2,D#,indexDoubleOffAddr#)
           | t == int32PrimTyCon  = MKDECODER(1,I32#,indexInt32OffAddr#)
           | t == word32PrimTyCon = MKDECODER(1,W32#,indexWord32OffAddr#)
           | t == int64PrimTyCon  = MKDECODER(2,I64#,indexInt64OffAddr#)
           | t == word64PrimTyCon = MKDECODER(2,W64#,indexWord64OffAddr#)
           | t == addrPrimTyCon   = MKDECODER(1,I#,(\x off-> addr2Int# (indexAddrOffAddr# x off)))  --OPT Improve the presentation of addresses
           | t == stablePtrPrimTyCon  = (1, "<stablePtr>")
           | t == stableNamePrimTyCon = (1, "<stableName>")
           | t == statePrimTyCon      = (1, "<statethread>")
           | t == realWorldTyCon      = (1, "<realworld>")
           | t == threadIdPrimTyCon   = (1, "<ThreadId>")
           | t == weakPrimTyCon       = (1, "<Weak>")
           | t == arrayPrimTyCon      = (1,"<array>")
           | t == byteArrayPrimTyCon  = (1,"<bytearray>")
           | t == mutableArrayPrimTyCon = (1, "<mutableArray>")
           | t == mutableByteArrayPrimTyCon = (1, "<mutableByteArray>")
           | t == mutVarPrimTyCon= (1, "<mutVar>")
           | t == mVarPrimTyCon  = (1, "<mVar>")
           | t == tVarPrimTyCon  = (1, "<tVar>")
           | otherwise = (1, showSDoc (char '<' <> ppr t <> char '>')) 
                 -- We cannot know the right offset in the otherwise case, so 1 is just a wild dangerous guess!
           -- TODO: Improve the offset handling in decode (make it machine dependant)

-----------------------------------
-- * Traversals for Terms
-----------------------------------

data TermFold a = TermFold { fTerm :: Type -> DataCon -> HValue -> [a] -> a
                           , fPrim :: Type -> String -> a
                           , fSuspension :: ClosureType -> Maybe Type -> HValue -> Maybe Name -> a
                           }

foldTerm :: TermFold a -> Term -> a
foldTerm tf (Term ty dc v tt) = fTerm tf ty dc v (map (foldTerm tf) tt)
foldTerm tf (Prim ty    v   ) = fPrim tf ty v
foldTerm tf (Suspension ct ty v b) = fSuspension tf ct ty v b

idTermFold :: TermFold Term
idTermFold = TermFold {
              fTerm = Term,
              fPrim = Prim,
              fSuspension = Suspension
                      }
idTermFoldM :: Monad m => TermFold (m Term)
idTermFoldM = TermFold {
              fTerm       = \ty dc v tt -> sequence tt >>= return . Term ty dc v,
              fPrim       = (return.). Prim,
              fSuspension = (((return.).).). Suspension
                       }

----------------------------------
-- Pretty printing of terms
----------------------------------

parensCond True  = parens
parensCond False = id
app_prec::Int
app_prec = 10

printTerm :: Term -> SDoc
printTerm Prim{value=value} = text value 
printTerm t@Term{} = printTerm1 0 t 
printTerm Suspension{bound_to=Nothing} =  char '_' -- <> ppr ct <> char '_'
printTerm Suspension{mb_ty=Just ty, bound_to=Just n}
  | Just _ <- splitFunTy_maybe ty = text "<function>"
  | otherwise = parens$ ppr n <> text "::" <> ppr ty 

printTerm1 p Term{dc=dc, subTerms=tt} 
{-  | dataConIsInfix dc, (t1:t2:tt') <- tt 
  = parens (printTerm1 True t1 <+> ppr dc <+> printTerm1 True ppr t2) 
    <+> hsep (map (printTerm1 True) tt) 
-}
  | null tt   = ppr dc
  | otherwise = parensCond (p > app_prec) 
                     (ppr dc <+> sep (map (printTerm1 (app_prec+1)) tt))

  where fixity   = undefined 

printTerm1 _ t = printTerm t

customPrintTerm :: Monad m => ((Int->Term->m SDoc)->[Term->m (Maybe SDoc)]) -> Term -> m SDoc
customPrintTerm custom = let 
--  go :: Monad m => Int -> Term -> m SDoc
  go prec t@Term{subTerms=tt, dc=dc} = do
    mb_customDocs <- sequence$ sequence (custom go) t  -- Inner sequence is List monad
    case msum mb_customDocs of        -- msum is in Maybe monad
      Just doc -> return$ parensCond (prec>app_prec+1) doc
--    | dataConIsInfix dc, (t1:t2:tt') <- tt =
      Nothing  -> do pprSubterms <- mapM (go (app_prec+1)) tt
                     return$ parensCond (prec>app_prec+1) 
                                        (ppr dc <+> sep pprSubterms)
  go _ t = return$ printTerm t
  in go 0 
   where fixity = undefined 

customPrintTermBase :: Monad m => (Int->Term-> m SDoc)->[Term->m (Maybe SDoc)]
customPrintTermBase showP =
  [ 
    test isTupleDC (liftM (parens . hcat . punctuate comma) . mapM (showP 0) . subTerms)
  , test (isDC consDataCon) (\Term{subTerms=[h,t]} -> doList h t)
  , test (isDC intDataCon)  (coerceShow$ \(a::Int)->a)
  , test (isDC charDataCon) (coerceShow$ \(a::Char)->a)
--  , test (isDC wordDataCon) (coerceShow$ \(a::Word)->a)
  , test (isDC floatDataCon) (coerceShow$ \(a::Float)->a)
  , test (isDC doubleDataCon) (coerceShow$ \(a::Double)->a)
  , test isIntegerDC (coerceShow$ \(a::Integer)->a)
  ] 
     where test pred f t = if pred t then liftM Just (f t) else return Nothing
           isIntegerDC Term{dc=dc} = 
              dataConName dc `elem` [ smallIntegerDataConName
                                    , largeIntegerDataConName] 
           isTupleDC Term{dc=dc}   = dc `elem` snd (unzip (elems boxedTupleArr))
           isDC a_dc Term{dc=dc}   = a_dc == dc
           coerceShow f = return . text . show . f . unsafeCoerce# . val
           --TODO pprinting of list terms is not lazy
           doList h t = do
               let elems = h : getListTerms t
                   isConsLast = isSuspension (last elems) && 
                                (mb_ty$ last elems) /= (termType h)
               init <- mapM (showP 0) (init elems) 
               last0 <- showP 0 (last elems)
               let last = case length elems of 
                            1 -> last0 
                            _ | isConsLast -> text " | " <> last0
                            _ -> comma <> last0
               return$ brackets (hcat (punctuate comma init ++ [last]))

                where Just a /= Just b = not (a `coreEqType` b)
                      _      /=   _    = True
                      getListTerms Term{subTerms=[h,t]} = h : getListTerms t
                      getListTerms t@Term{subTerms=[]}  = []
                      getListTerms t@Suspension{}       = [t]
                      getListTerms t = pprPanic "getListTerms" (ppr t)

-----------------------------------
-- Type Reconstruction
-----------------------------------

-- The Type Reconstruction monad
type TR a = TcM a

runTR :: HscEnv -> TR Term -> IO Term
runTR hsc_env c = do 
  mb_term <- initTcPrintErrors hsc_env iNTERACTIVE (c >>= zonkTerm)
  case mb_term of 
    Nothing -> panic "Can't unify"
    Just term -> return term

trIO :: IO a -> TR a 
trIO = liftTcM . ioToTcRn

addConstraint :: TcType -> TcType -> TR ()
addConstraint t1 t2  = congruenceNewtypes t1 t2 >>= uncurry unifyType 

{-
   A parallel fold over two Type values, 
 compensating for missing newtypes on both sides. 
 This is necessary because newtypes are not present 
 in runtime, but since sometimes there is evidence 
 available we do our best to reconstruct them. 
   Evidence can come from DataCon signatures or 
 from compile-time type inference.
   I am using the words congruence and rewriting 
 because what we are doing here is an approximation 
 of unification modulo a set of equations, which would 
 come from newtype definitions. These should be the 
 equality coercions seen in System Fc. Rewriting 
 is performed, taking those equations as rules, 
 before launching unification.

   It doesn't make sense to rewrite everywhere, 
 or we would end up with all newtypes. So we rewrite 
 only in presence of evidence.
   The lhs comes from the heap structure of ptrs,nptrs. 
   The rhs comes from a DataCon type signature. 
 Rewriting in the rhs is restricted to the result type.

   Note that it is very tricky to make this 'rewriting'
 work with the unification implemented by TcM, where
 substitutions are 'inlined'. The order in which 
 constraints are unified is vital for this (or I am 
 using TcM wrongly).
-}
congruenceNewtypes ::  TcType -> TcType -> TcM (TcType,TcType)
congruenceNewtypes = go True
  where 
   go rewriteRHS lhs rhs  
 -- TyVar lhs inductive case
    | Just tv <- getTyVar_maybe lhs 
    = recoverM (return (lhs,rhs)) $ do  
         Indirect ty_v <- readMetaTyVar tv
         (lhs', rhs') <- go rewriteRHS ty_v rhs
         writeMutVar (metaTvRef tv) (Indirect lhs')
         return (lhs, rhs')
 -- TyVar rhs inductive case
    | Just tv <- getTyVar_maybe rhs 
    = recoverM (return (lhs,rhs)) $ do  
         Indirect ty_v <- readMetaTyVar tv
         (lhs', rhs') <- go rewriteRHS lhs ty_v
         writeMutVar (metaTvRef tv) (Indirect rhs')
         return (lhs', rhs)
-- FunTy inductive case
    | Just (l1,l2) <- splitFunTy_maybe lhs
    , Just (r1,r2) <- splitFunTy_maybe rhs
    = do (l2',r2') <- go True l2 r2
         (l1',r1') <- go False l1 r1
         return (mkFunTy l1' l2', mkFunTy r1' r2')
-- TyconApp Inductive case; this is the interesting bit.
    | Just (tycon_l, args_l) <- splitNewTyConApp_maybe lhs
    , Just (tycon_r, args_r) <- splitNewTyConApp_maybe rhs = do

      let (tycon_l',args_l') = if isNewTyCon tycon_r && not(isNewTyCon tycon_l)
                                then (tycon_r, rewrite tycon_r lhs)
                                else (tycon_l, args_l)
          (tycon_r',args_r') = if rewriteRHS && isNewTyCon tycon_l && not(isNewTyCon tycon_r)
                                then (tycon_l, rewrite tycon_l rhs)
                                else (tycon_r, args_r)
      (args_l'', args_r'') <- unzip `liftM` zipWithM (go rewriteRHS) args_l' args_r'
      return (mkTyConApp tycon_l' args_l'', mkTyConApp tycon_r' args_r'') 

    | otherwise = return (lhs,rhs)

    where rewrite newtyped_tc lame_tipe
           | (tvs, tipe) <- newTyConRep newtyped_tc 
           = case tcUnifyTys (const BindMe) [tipe] [lame_tipe] of
               Just subst -> substTys subst (map mkTyVarTy tvs)
               otherwise  -> panic "congruenceNewtypes: Can't unify a newtype"

newVar :: Kind -> TR TcTyVar
newVar = liftTcM . newFlexiTyVar

liftTcM = id

instScheme :: Type -> TR TcType
instScheme ty = liftTcM$ liftM trd (tcInstType (liftM fst3 . tcInstTyVars) ty)
    where fst3 (x,y,z) = x
          trd  (x,y,z) = z

cvObtainTerm :: HscEnv -> Bool -> Maybe Type -> HValue -> IO Term
cvObtainTerm hsc_env force mb_ty a = do
   -- Obtain the term and tidy the type before returning it
   term <- cvObtainTerm1 hsc_env force mb_ty a
   return $ tidyTypes term
   where 
         tidyTypes = foldTerm idTermFold {
            fTerm = \ty dc hval tt -> Term (tidy ty) dc hval tt,
            fSuspension = \ct mb_ty hval n -> 
                          Suspension ct (fmap tidy mb_ty) hval n
            }
         tidy ty = tidyType (emptyTidyOccEnv, tidyVarEnv ty) ty  
         tidyVarEnv ty = 

             mkVarEnv$ [ (v, setTyVarName v (tyVarName tv))
                         | (tv,v) <- zip alphaTyVars vars]
             where vars = varSetElems$ tyVarsOfType ty

cvObtainTerm1 :: HscEnv -> Bool -> Maybe Type -> HValue -> IO Term
cvObtainTerm1 hsc_env force mb_ty hval = runTR hsc_env $ do
   tv   <- liftM mkTyVarTy (newVar argTypeKind)
   when (isJust mb_ty) $ 
        instScheme (sigmaType$ fromJust mb_ty) >>= addConstraint tv
   go tv hval
    where 
  go tv a = do 
    clos <- trIO $ getClosureData a
    case tipe clos of
-- Thunks we may want to force
      Thunk _ | force -> seq a $ go tv a
-- We always follow indirections 
      Indirection _ -> go tv $! (ptrs clos ! 0)
 -- The interesting case
      Constr -> do
        m_dc <- trIO$ tcRnRecoverDataCon hsc_env (infoPtr clos)
        case m_dc of
          Nothing -> panic "Can't find the DataCon for a term"
          Just dc -> do 
            let extra_args = length(dataConRepArgTys dc) - length(dataConOrigArgTys dc)
                subTtypes  = drop extra_args (dataConRepArgTys dc)
                (subTtypesP, subTtypesNP) = partition isPointed subTtypes
                n_subtermsP= length subTtypesP
            subTermTvs    <- mapM (liftM mkTyVarTy . newVar ) (map typeKind subTtypesP)
            baseType      <- instScheme (dataConRepType dc)
            let myType     = mkFunTys (reOrderTerms subTermTvs subTtypesNP subTtypes) tv
            addConstraint myType baseType
            subTermsP <- sequence [ extractSubterm i tv (ptrs clos) 
                                   | (i,tv) <- zip [extra_args..extra_args + n_subtermsP - 1]
                                                   subTermTvs ]
            let unboxeds   = extractUnboxed subTtypesNP (nonPtrs clos)
                subTermsNP = map (uncurry Prim) (zip subTtypesNP unboxeds)      
                subTerms   = reOrderTerms subTermsP subTermsNP subTtypes
            return (Term tv dc a subTerms)
-- The otherwise case: can be a Thunk,AP,PAP,etc.
      otherwise -> do
         return (Suspension (tipe clos) (Just tv) a Nothing)

-- Access the array of pointers and recurse down. Needs to be done with
-- care of no introducing a thunk! or go will fail to do its job 
  extractSubterm (I# i#) tv ptrs = case ptrs of 
                 (Array _ _ ptrs#) -> case indexArray# ptrs# i# of 
                       (# e #) -> go tv e

-- This is used to put together pointed and nonpointed subterms in the 
--  correct order.
  reOrderTerms _ _ [] = []
  reOrderTerms pointed unpointed (ty:tys) 
   | isPointed ty = head pointed : reOrderTerms (tail pointed) unpointed tys
   | otherwise    = head unpointed : reOrderTerms pointed (tail unpointed) tys

zonkTerm :: Term -> TcM Term
zonkTerm = foldTerm idTermFoldM {
              fTerm = \ty dc v tt -> sequence tt      >>= \tt ->
                                     zonkTcType ty    >>= \ty' ->
                                     return (Term ty' dc v tt)
             ,fSuspension = \ct ty v b -> fmapMMaybe zonkTcType ty >>= \ty ->
                                          return (Suspension ct ty v b)}  


-- Is this defined elsewhere?
-- Generalize the type: find all free tyvars and wrap in the appropiate ForAll.
sigmaType ty = mkForAllTys (varSetElems$ tyVarsOfType (dropForAlls ty)) ty

{-
Example of Type Reconstruction
--------------------------------
Suppose we have an existential type such as

data Opaque = forall a. Opaque a

And we have a term built as:

t = Opaque (map Just [[1,1],[2,2]])

The type of t as far as the typechecker goes is t :: Opaque
If we seq the head of t, we obtain:

t - O (_1::a) 

seq _1 ()

t - O ( (_3::b) : (_4::[b]) ) 

seq _3 ()

t - O ( (Just (_5::c)) : (_4::[b]) ) 

At this point, we know that b = (Maybe c)

seq _5 ()

t - O ( (Just ((_6::d) : (_7::[d]) )) : (_4::[b]) )

At this point, we know that c = [d]

seq _6 ()

t - O ( (Just (1 : (_7::[d]) )) : (_4::[b]) )

At this point, we know that d = Integer

The fully reconstructed expressions, with propagation, would be:

t - O ( (Just (_5::c)) : (_4::[Maybe c]) ) 
t - O ( (Just ((_6::d) : (_7::[d]) )) : (_4::[Maybe [d]]) )
t - O ( (Just (1 : (_7::[Integer]) )) : (_4::[Maybe [Integer]]) )


For reference, the type of the thing inside the opaque is 
map Just [[1,1],[2,2]] :: [Maybe [Integer]]

NOTE: (Num t) contexts have been manually replaced by Integer for clarity
-}
