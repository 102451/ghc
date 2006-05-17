%
% (c) The GRASP/AQUA Project, Glasgow University, 1993-1998
%
%************************************************************************
%*									*
\section[HsCore]{Core-syntax unfoldings in Haskell interface files}
%*									*
%************************************************************************

We could either use this, or parameterise @GenCoreExpr@ on @Types@ and
@TyVars@ as well.  Currently trying the former... MEGA SIGH.

\begin{code}
module IfaceSyn (
	module IfaceType,		-- Re-export all this

	IfaceDecl(..), IfaceClassOp(..), IfaceConDecl(..), IfaceConDecls(..),
	IfaceExpr(..), IfaceAlt, IfaceNote(..),
	IfaceBinding(..), IfaceConAlt(..), IfaceIdInfo(..),
	IfaceInfoItem(..), IfaceRule(..), IfaceInst(..), 

	-- Misc
	visibleIfConDecls,

	-- Converting things to IfaceSyn
	tyThingToIfaceDecl, instanceToIfaceInst, coreRuleToIfaceRule, 

	-- Equality
	IfaceEq(..), (&&&), bool, eqListBy, eqMaybeBy,
	eqIfDecl, eqIfInst, eqIfRule, 
	
	-- Pretty printing
	pprIfaceExpr, pprIfaceDecl, pprIfaceDeclHead 
    ) where

#include "HsVersions.h"

import CoreSyn
import IfaceType

import FunDeps		( pprFundeps )
import NewDemand	( StrictSig, pprIfaceStrictSig )
import TcType		( deNoteType )
import Type		( TyThing(..), splitForAllTys, funResultTy )
import InstEnv		( Instance(..), OverlapFlag )
import Id		( Id, idName, idType, idInfo, idArity, isDataConWorkId_maybe, isFCallId_maybe )
import NewDemand	( isTopSig )
import IdInfo		( IdInfo, CafInfo(..), WorkerInfo(..), 
			  arityInfo, cafInfo, newStrictnessInfo, 
			  workerInfo, unfoldingInfo, inlinePragInfo )
import TyCon		( TyCon, ArgVrcs, AlgTyConRhs(..), isRecursiveTyCon, isForeignTyCon,
			  isSynTyCon, isAlgTyCon, isPrimTyCon, isFunTyCon,
			  isTupleTyCon, tupleTyConBoxity, tyConStupidTheta,
			  tyConHasGenerics, tyConArgVrcs, synTyConRhs,
			  tyConArity, tyConTyVars, algTyConRhs, tyConExtName  )
import DataCon		( dataConName, dataConSig, dataConFieldLabels, dataConStrictMarks,
			  dataConTyCon, dataConIsInfix, isVanillaDataCon )
import Class		( FunDep, DefMeth, classExtraBigSig, classTyCon )
import OccName		( OccName, OccEnv, emptyOccEnv, 
			  lookupOccEnv, extendOccEnv, parenSymOcc,
			  OccSet, unionOccSets, unitOccSet )
import Name		( Name, NamedThing(..), nameOccName, isExternalName )
import CostCentre	( CostCentre, pprCostCentreCore )
import Literal		( Literal )
import ForeignCall	( ForeignCall )
import TysPrim		( alphaTyVars )
import BasicTypes	( Arity, Activation(..), StrictnessMark, 
			  RecFlag(..), boolToRecFlag, Boxity(..), 
			  tupleParens )
import Outputable
import FastString
import Maybes		( catMaybes )
import Util		( lengthIs )

infixl 3 &&&
infix  4 `eqIfExt`, `eqIfIdInfo`, `eqIfType`
\end{code}


%************************************************************************
%*									*
		Data type declarations
%*									*
%************************************************************************

\begin{code}
data IfaceDecl 
  = IfaceId { ifName   :: OccName,
	      ifType   :: IfaceType, 
	      ifIdInfo :: IfaceIdInfo }

  | IfaceData { ifName     :: OccName,		-- Type constructor
		ifTyVars   :: [IfaceTvBndr],	-- Type variables
		ifCtxt	   :: IfaceContext,	-- The "stupid theta"
		ifCons	   :: IfaceConDecls,	-- Includes new/data info
	        ifRec	   :: RecFlag,		-- Recursive or not?
		ifVrcs     :: ArgVrcs,
		ifGeneric  :: Bool		-- True <=> generic converter functions available
    }						-- We need this for imported data decls, since the
						-- imported modules may have been compiled with
						-- different flags to the current compilation unit

  | IfaceSyn  {	ifName   :: OccName,		-- Type constructor
		ifTyVars :: [IfaceTvBndr],	-- Type variables
		ifVrcs   :: ArgVrcs,
		ifSynRhs :: IfaceType		-- synonym expansion
    }

  | IfaceClass { ifCtxt    :: IfaceContext, 	-- Context...
		 ifName    :: OccName,		-- Name of the class
		 ifTyVars  :: [IfaceTvBndr],	-- Type variables
		 ifFDs     :: [FunDep OccName],	-- Functional dependencies
		 ifSigs    :: [IfaceClassOp],	-- Method signatures
	         ifRec	   :: RecFlag,		-- Is newtype/datatype associated with the class recursive?
		 ifVrcs    :: ArgVrcs		-- ... and what are its argument variances ...
    }

  | IfaceForeign { ifName :: OccName,		-- Needs expanding when we move beyond .NET
		   ifExtName :: Maybe FastString }

data IfaceClassOp = IfaceClassOp OccName DefMeth IfaceType
	-- Nothing    => no default method
	-- Just False => ordinary polymorphic default method
	-- Just True  => generic default method

data IfaceConDecls
  = IfAbstractTyCon		-- No info
  | IfDataTyCon [IfaceConDecl]	-- data type decls
  | IfNewTyCon  IfaceConDecl	-- newtype decls

visibleIfConDecls :: IfaceConDecls -> [IfaceConDecl]
visibleIfConDecls IfAbstractTyCon  = []
visibleIfConDecls (IfDataTyCon cs) = cs
visibleIfConDecls (IfNewTyCon c)   = [c]

data IfaceConDecl 
  = IfVanillaCon {
	ifConOcc     :: OccName,		-- Constructor name
	ifConInfix   :: Bool,			-- True <=> declared infix
	ifConArgTys  :: [IfaceType],		-- Arg types
	ifConStricts :: [StrictnessMark],	-- Empty (meaning all lazy), or 1-1 corresp with arg types
	ifConFields  :: [OccName] }		-- ...ditto... (field labels)
  | IfGadtCon {
	ifConOcc     :: OccName,		-- Constructor name
	ifConTyVars  :: [IfaceTvBndr],		-- All tyvars
	ifConCtxt    :: IfaceContext,		-- Non-stupid context
	ifConArgTys  :: [IfaceType],		-- Arg types
	ifConResTys  :: [IfaceType],		-- Result type args
	ifConStricts :: [StrictnessMark] }	-- Empty (meaning all lazy), or 1-1 corresp with arg types
			
data IfaceInst 
  = IfaceInst { ifInstCls  :: IfaceExtName,		-- See comments with
		ifInstTys  :: [Maybe IfaceTyCon],	-- the defn of Instance
		ifDFun     :: OccName, 			-- The dfun
		ifOFlag    :: OverlapFlag,		-- Overlap flag
		ifInstOrph :: Maybe OccName }		-- See is_orph in defn of Instance
	-- There's always a separate IfaceDecl for the DFun, which gives 
	-- its IdInfo with its full type and version number.
	-- The instance declarations taken together have a version number,
	-- and we don't want that to wobble gratuitously
	-- If this instance decl is *used*, we'll record a usage on the dfun;
	-- and if the head does not change it won't be used if it wasn't before

data IfaceRule
  = IfaceRule { 
	ifRuleName   :: RuleName,
	ifActivation :: Activation,
	ifRuleBndrs  :: [IfaceBndr],	-- Tyvars and term vars
	ifRuleHead   :: IfaceExtName,	-- Head of lhs
	ifRuleArgs   :: [IfaceExpr],	-- Args of LHS
	ifRuleRhs    :: IfaceExpr,
	ifRuleOrph   :: Maybe OccName	-- Just like IfaceInst
    }

data IfaceIdInfo
  = NoInfo			-- When writing interface file without -O
  | HasInfo [IfaceInfoItem]	-- Has info, and here it is

-- Here's a tricky case:
--   * Compile with -O module A, and B which imports A.f
--   * Change function f in A, and recompile without -O
--   * When we read in old A.hi we read in its IdInfo (as a thunk)
--	(In earlier GHCs we used to drop IdInfo immediately on reading,
--	 but we do not do that now.  Instead it's discarded when the
--	 ModIface is read into the various decl pools.)
--   * The version comparsion sees that new (=NoInfo) differs from old (=HasInfo *)
--	and so gives a new version.

data IfaceInfoItem
  = HsArity	 Arity
  | HsStrictness StrictSig
  | HsUnfold	 Activation IfaceExpr
  | HsNoCafRefs
  | HsWorker	 IfaceExtName Arity	-- Worker, if any see IdInfo.WorkerInfo
					-- for why we want arity here.
	-- NB: we need IfaceExtName (not just OccName) because the worker
	--     can simplify to a function in another module.
-- NB: Specialisations and rules come in separately and are
-- only later attached to the Id.  Partial reason: some are orphans.

--------------------------------
data IfaceExpr
  = IfaceLcl 	OccName
  | IfaceExt    IfaceExtName
  | IfaceType   IfaceType
  | IfaceTuple 	Boxity [IfaceExpr]		-- Saturated; type arguments omitted
  | IfaceLam 	IfaceBndr IfaceExpr
  | IfaceApp 	IfaceExpr IfaceExpr
  | IfaceCase	IfaceExpr OccName IfaceType [IfaceAlt]
  | IfaceLet	IfaceBinding  IfaceExpr
  | IfaceNote	IfaceNote IfaceExpr
  | IfaceLit	Literal
  | IfaceFCall	ForeignCall IfaceType

data IfaceNote = IfaceSCC CostCentre
	       | IfaceCoerce IfaceType
	       | IfaceInlineCall
	       | IfaceInlineMe
               | IfaceCoreNote String

type IfaceAlt = (IfaceConAlt, [OccName], IfaceExpr)
	-- Note: OccName, not IfaceBndr (and same with the case binder)
	-- We reconstruct the kind/type of the thing from the context
	-- thus saving bulk in interface files

data IfaceConAlt = IfaceDefault
 		 | IfaceDataAlt OccName
		 | IfaceTupleAlt Boxity
		 | IfaceLitAlt Literal

data IfaceBinding
  = IfaceNonRec	IfaceIdBndr IfaceExpr
  | IfaceRec 	[(IfaceIdBndr, IfaceExpr)]
\end{code}


%************************************************************************
%*									*
\subsection[HsCore-print]{Printing Core unfoldings}
%*									*
%************************************************************************

----------------------------- Printing IfaceDecl ------------------------------------

\begin{code}
instance Outputable IfaceDecl where
  ppr = pprIfaceDecl

pprIfaceDecl (IfaceId {ifName = var, ifType = ty, ifIdInfo = info})
  = sep [ ppr var <+> dcolon <+> ppr ty, 
	  nest 2 (ppr info) ]

pprIfaceDecl (IfaceForeign {ifName = tycon})
  = hsep [ptext SLIT("foreign import type dotnet"), ppr tycon]

pprIfaceDecl (IfaceSyn {ifName = tycon, ifTyVars = tyvars, ifSynRhs = mono_ty, ifVrcs = vrcs})
  = hang (ptext SLIT("type") <+> pprIfaceDeclHead [] tycon tyvars)
       4 (vcat [equals <+> ppr mono_ty,
		pprVrcs vrcs])

pprIfaceDecl (IfaceData {ifName = tycon, ifGeneric = gen, ifCtxt = context,
			 ifTyVars = tyvars, ifCons = condecls, 
			 ifRec = isrec, ifVrcs = vrcs})
  = hang (pp_nd <+> pprIfaceDeclHead context tycon tyvars)
       4 (vcat [pprVrcs vrcs, pprRec isrec, pprGen gen, pp_condecls tycon condecls])
  where
    pp_nd = case condecls of
		IfAbstractTyCon -> ptext SLIT("data")
		IfDataTyCon _   -> ptext SLIT("data")
		IfNewTyCon _  	-> ptext SLIT("newtype")

pprIfaceDecl (IfaceClass {ifCtxt = context, ifName = clas, ifTyVars = tyvars, 
			  ifFDs = fds, ifSigs = sigs, ifVrcs = vrcs, ifRec = isrec})
  = hang (ptext SLIT("class") <+> pprIfaceDeclHead context clas tyvars <+> pprFundeps fds)
       4 (vcat [pprVrcs vrcs, 
		pprRec isrec,
	        sep (map ppr sigs)])

pprVrcs vrcs = ptext SLIT("Variances") <+> ppr vrcs
pprRec isrec = ptext SLIT("RecFlag") <+> ppr isrec
pprGen True  = ptext SLIT("Generics: yes")
pprGen False = ptext SLIT("Generics: no")

instance Outputable IfaceClassOp where
   ppr (IfaceClassOp n dm ty) = ppr n <+> ppr dm <+> dcolon <+> ppr ty

pprIfaceDeclHead :: IfaceContext -> OccName -> [IfaceTvBndr] -> SDoc
pprIfaceDeclHead context thing tyvars 
  = hsep [pprIfaceContext context, parenSymOcc thing (ppr thing), pprIfaceTvBndrs tyvars]

pp_condecls tc IfAbstractTyCon  = ptext SLIT("{- abstract -}")
pp_condecls tc (IfNewTyCon c)   = equals <+> pprIfaceConDecl tc c
pp_condecls tc (IfDataTyCon cs) = equals <+> sep (punctuate (ptext SLIT(" |"))
						     (map (pprIfaceConDecl tc) cs))

pprIfaceConDecl tc (IfVanillaCon { 
		      ifConOcc = name, ifConInfix = is_infix, 
		      ifConArgTys = arg_tys, 
		      ifConStricts = strs, ifConFields = fields })
    = sep [ppr name <+> sep (map pprParendIfaceType arg_tys),
	   if is_infix then ptext SLIT("Infix") else empty,
	   if null strs then empty 
	      else nest 4 (ptext SLIT("Stricts:") <+> hsep (map ppr strs)),
	   if null fields then empty
	      else nest 4 (ptext SLIT("Fields:") <+> hsep (map ppr fields))]

pprIfaceConDecl tc (IfGadtCon { 
		      ifConOcc = name, 
		      ifConTyVars = tvs, ifConCtxt = ctxt,
		      ifConArgTys = arg_tys, ifConResTys = res_tys, 
		      ifConStricts = strs })
    = sep [ppr name <+> dcolon <+> pprIfaceForAllPart tvs ctxt (ppr con_tau),
	   if null strs then empty 
	      else nest 4 (ptext SLIT("Stricts:") <+> hsep (map ppr strs))]
    where
      con_tau = foldr1 IfaceFunTy (arg_tys ++ [tc_app])
      tc_app  = IfaceTyConApp (IfaceTc (LocalTop tc)) res_tys	
	-- Gruesome, but jsut for debug print

instance Outputable IfaceRule where
  ppr (IfaceRule { ifRuleName = name, ifActivation = act, ifRuleBndrs = bndrs,
		   ifRuleHead = fn, ifRuleArgs = args, ifRuleRhs = rhs }) 
    = sep [hsep [doubleQuotes (ftext name), ppr act,
		 ptext SLIT("forall") <+> pprIfaceBndrs bndrs],
	   nest 2 (sep [ppr fn <+> sep (map (pprIfaceExpr parens) args),
		        ptext SLIT("=") <+> ppr rhs])
      ]

instance Outputable IfaceInst where
  ppr (IfaceInst {ifDFun = dfun_id, ifOFlag = flag, 
		  ifInstCls = cls, ifInstTys = mb_tcs})
    = hang (ptext SLIT("instance") <+> ppr flag 
		<+> ppr cls <+> brackets (pprWithCommas ppr_mb mb_tcs))
         2 (equals <+> ppr dfun_id)
    where
      ppr_mb Nothing   = dot
      ppr_mb (Just tc) = ppr tc
\end{code}


----------------------------- Printing IfaceExpr ------------------------------------

\begin{code}
instance Outputable IfaceExpr where
    ppr e = pprIfaceExpr noParens e

pprIfaceExpr :: (SDoc -> SDoc) -> IfaceExpr -> SDoc
	-- The function adds parens in context that need
	-- an atomic value (e.g. function args)

pprIfaceExpr add_par (IfaceLcl v)       = ppr v
pprIfaceExpr add_par (IfaceExt v)       = ppr v
pprIfaceExpr add_par (IfaceLit l)       = ppr l
pprIfaceExpr add_par (IfaceFCall cc ty) = braces (ppr cc <+> ppr ty)
pprIfaceExpr add_par (IfaceType ty)     = char '@' <+> pprParendIfaceType ty

pprIfaceExpr add_par app@(IfaceApp _ _) = add_par (pprIfaceApp app [])
pprIfaceExpr add_par (IfaceTuple c as)  = tupleParens c (interpp'SP as)

pprIfaceExpr add_par e@(IfaceLam _ _)   
  = add_par (sep [char '\\' <+> sep (map ppr bndrs) <+> arrow,
		  pprIfaceExpr noParens body])
  where 
    (bndrs,body) = collect [] e
    collect bs (IfaceLam b e) = collect (b:bs) e
    collect bs e              = (reverse bs, e)

-- gaw 2004 
pprIfaceExpr add_par (IfaceCase scrut bndr ty [(con, bs, rhs)])
-- gaw 2004
  = add_par (sep [ptext SLIT("case") <+> char '@' <+> pprParendIfaceType ty <+> pprIfaceExpr noParens scrut <+> ptext SLIT("of") 
			<+> ppr bndr <+> char '{' <+> ppr_con_bs con bs <+> arrow,
  		  pprIfaceExpr noParens rhs <+> char '}'])

-- gaw 2004
pprIfaceExpr add_par (IfaceCase scrut bndr ty alts)
-- gaw 2004
  = add_par (sep [ptext SLIT("case") <+> char '@' <+> pprParendIfaceType ty <+> pprIfaceExpr noParens scrut <+> ptext SLIT("of") 
			<+> ppr bndr <+> char '{',
  		  nest 2 (sep (map ppr_alt alts)) <+> char '}'])

pprIfaceExpr add_par (IfaceLet (IfaceNonRec b rhs) body)
  = add_par (sep [ptext SLIT("let {"), 
		  nest 2 (ppr_bind (b, rhs)),
		  ptext SLIT("} in"), 
		  pprIfaceExpr noParens body])

pprIfaceExpr add_par (IfaceLet (IfaceRec pairs) body)
  = add_par (sep [ptext SLIT("letrec {"),
		  nest 2 (sep (map ppr_bind pairs)), 
		  ptext SLIT("} in"),
		  pprIfaceExpr noParens body])

pprIfaceExpr add_par (IfaceNote note body) = add_par (ppr note <+> pprIfaceExpr parens body)

ppr_alt (con, bs, rhs) = sep [ppr_con_bs con bs, 
			      arrow <+> pprIfaceExpr noParens rhs]

ppr_con_bs (IfaceTupleAlt tup_con) bs = tupleParens tup_con (interpp'SP bs)
ppr_con_bs con bs		      = ppr con <+> hsep (map ppr bs)
  
ppr_bind ((b,ty),rhs) = sep [ppr b <+> dcolon <+> ppr ty, 
			     equals <+> pprIfaceExpr noParens rhs]

------------------
pprIfaceApp (IfaceApp fun arg) args = pprIfaceApp fun (nest 2 (pprIfaceExpr parens arg) : args)
pprIfaceApp fun	 	       args = sep (pprIfaceExpr parens fun : args)

------------------
instance Outputable IfaceNote where
    ppr (IfaceSCC cc)     = pprCostCentreCore cc
    ppr (IfaceCoerce ty)  = ptext SLIT("__coerce") <+> pprParendIfaceType ty
    ppr IfaceInlineCall   = ptext SLIT("__inline_call")
    ppr IfaceInlineMe     = ptext SLIT("__inline_me")
    ppr (IfaceCoreNote s) = ptext SLIT("__core_note") <+> pprHsString (mkFastString s)

instance Outputable IfaceConAlt where
    ppr IfaceDefault	  = text "DEFAULT"
    ppr (IfaceLitAlt l)   = ppr l
    ppr (IfaceDataAlt d)  = ppr d
    ppr (IfaceTupleAlt b) = panic "ppr IfaceConAlt" 
	-- IfaceTupleAlt is handled by the case-alternative printer

------------------
instance Outputable IfaceIdInfo where
   ppr NoInfo       = empty
   ppr (HasInfo is) = ptext SLIT("{-") <+> fsep (map ppr_hs_info is) <+> ptext SLIT("-}")

ppr_hs_info (HsUnfold prag unf) = sep [ptext SLIT("Unfolding: ") <> ppr prag,
				       parens (pprIfaceExpr noParens unf)]
ppr_hs_info (HsArity arity)     = ptext SLIT("Arity:") <+> int arity
ppr_hs_info (HsStrictness str)  = ptext SLIT("Strictness:") <+> pprIfaceStrictSig str
ppr_hs_info HsNoCafRefs		= ptext SLIT("HasNoCafRefs")
ppr_hs_info (HsWorker w a)	= ptext SLIT("Worker:") <+> ppr w <+> int a
\end{code}


%************************************************************************
%*									*
	Converting things to their Iface equivalents
%*									*
%************************************************************************

		 
\begin{code}
tyThingToIfaceDecl :: (Name -> IfaceExtName) -> TyThing -> IfaceDecl
-- Assumption: the thing is already tidied, so that locally-bound names
-- 	       (lambdas, for-alls) already have non-clashing OccNames
-- Reason: Iface stuff uses OccNames, and the conversion here does
--	   not do tidying on the way
tyThingToIfaceDecl ext (AnId id)
  = IfaceId { ifName   = getOccName id, 
	      ifType   = toIfaceType ext (idType id),
	      ifIdInfo = info }
  where
    info = case toIfaceIdInfo ext (idInfo id) of
		[]    -> NoInfo
		items -> HasInfo items

tyThingToIfaceDecl ext (AClass clas)
  = IfaceClass { ifCtxt	  = toIfaceContext ext sc_theta,
		 ifName	  = getOccName clas,
		 ifTyVars = toIfaceTvBndrs clas_tyvars,
		 ifFDs    = map toIfaceFD clas_fds,
		 ifSigs	  = map toIfaceClassOp op_stuff,
	  	 ifRec    = boolToRecFlag (isRecursiveTyCon tycon),
		 ifVrcs   = tyConArgVrcs tycon }
  where
    (clas_tyvars, clas_fds, sc_theta, _, op_stuff) = classExtraBigSig clas
    tycon = classTyCon clas

    toIfaceClassOp (sel_id, def_meth)
	= ASSERT(sel_tyvars == clas_tyvars)
	  IfaceClassOp (getOccName sel_id) def_meth (toIfaceType ext op_ty)
	where
		-- Be careful when splitting the type, because of things
		-- like  	class Foo a where
		--		  op :: (?x :: String) => a -> a
		-- and  	class Baz a where
		--		  op :: (Ord a) => a -> a
	  (sel_tyvars, rho_ty) = splitForAllTys (idType sel_id)
	  op_ty		       = funResultTy rho_ty

    toIfaceFD (tvs1, tvs2) = (map getOccName tvs1, map getOccName tvs2)

tyThingToIfaceDecl ext (ATyCon tycon)
  | isSynTyCon tycon
  = IfaceSyn {	ifName   = getOccName tycon,
		ifTyVars = toIfaceTvBndrs tyvars,
		ifVrcs    = tyConArgVrcs tycon,
		ifSynRhs = toIfaceType ext syn_ty }

  | isAlgTyCon tycon
  = IfaceData {	ifName    = getOccName tycon,
		ifTyVars  = toIfaceTvBndrs tyvars,
		ifCtxt    = toIfaceContext ext (tyConStupidTheta tycon),
		ifCons    = ifaceConDecls (algTyConRhs tycon),
	  	ifRec     = boolToRecFlag (isRecursiveTyCon tycon),
		ifVrcs    = tyConArgVrcs tycon,
		ifGeneric = tyConHasGenerics tycon }

  | isForeignTyCon tycon
  = IfaceForeign { ifName    = getOccName tycon,
	    	   ifExtName = tyConExtName tycon }

  | isPrimTyCon tycon || isFunTyCon tycon
	-- Needed in GHCi for ':info Int#', for example
  = IfaceData { ifName    = getOccName tycon,
	  	ifTyVars  = toIfaceTvBndrs (take (tyConArity tycon) alphaTyVars),
		ifCtxt	  = [],
		ifCons    = IfAbstractTyCon,
		ifGeneric = False,
		ifRec     = NonRecursive,
		ifVrcs    = tyConArgVrcs tycon }

  | otherwise = pprPanic "toIfaceDecl" (ppr tycon)
  where
    tyvars = tyConTyVars tycon
    syn_ty = synTyConRhs tycon

    ifaceConDecls (NewTyCon { data_con = con })    = IfNewTyCon  (ifaceConDecl con)
    ifaceConDecls (DataTyCon { data_cons = cons }) = IfDataTyCon (map ifaceConDecl cons)
    ifaceConDecls AbstractTyCon			   = IfAbstractTyCon
	-- The last case happens when a TyCon has been trimmed during tidying
	-- Furthermore, tyThingToIfaceDecl is also used
	-- in TcRnDriver for GHCi, when browsing a module, in which case the
	-- AbstractTyCon case is perfectly sensible.

    ifaceConDecl data_con 
	| isVanillaDataCon data_con
	= IfVanillaCon {ifConOcc = getOccName (dataConName data_con),
			ifConInfix = dataConIsInfix data_con,
			ifConArgTys = map (toIfaceType ext) arg_tys,
			ifConStricts = strict_marks,
			ifConFields = map getOccName field_labels }
	| otherwise
	= IfGadtCon   { ifConOcc = getOccName (dataConName data_con),
			ifConTyVars = toIfaceTvBndrs tyvars,
			ifConCtxt = toIfaceContext ext theta,
			ifConArgTys = map (toIfaceType ext) arg_tys,
			ifConResTys = map (toIfaceType ext) res_tys,
			ifConStricts = strict_marks }
	where
	  (tyvars, theta, arg_tys, _, res_tys) = dataConSig data_con
          field_labels = dataConFieldLabels data_con
          strict_marks = dataConStrictMarks data_con

tyThingToIfaceDecl ext (ADataCon dc)
 = pprPanic "toIfaceDecl" (ppr dc)	-- Should be trimmed out earlier


--------------------------
instanceToIfaceInst :: (Name -> IfaceExtName) -> Instance -> IfaceInst
instanceToIfaceInst ext_lhs ispec@(Instance { is_dfun = dfun_id, is_flag = oflag,
					      is_cls = cls, is_tcs = mb_tcs, 
					      is_orph = orph })
  = IfaceInst { ifDFun    = getOccName dfun_id, 
		ifOFlag   = oflag,
		ifInstCls = ext_lhs cls,
		ifInstTys = map do_rough mb_tcs,
		ifInstOrph = orph }
  where
    do_rough Nothing  = Nothing
    do_rough (Just n) = Just (toIfaceTyCon_name ext_lhs n)

--------------------------
toIfaceIdInfo :: (Name -> IfaceExtName) -> IdInfo -> [IfaceInfoItem]
toIfaceIdInfo ext id_info
  = catMaybes [arity_hsinfo, caf_hsinfo, strict_hsinfo, 
	       wrkr_hsinfo,  unfold_hsinfo] 
  where
    ------------  Arity  --------------
    arity_info = arityInfo id_info
    arity_hsinfo | arity_info == 0 = Nothing
		 | otherwise       = Just (HsArity arity_info)

    ------------ Caf Info --------------
    caf_info   = cafInfo id_info
    caf_hsinfo = case caf_info of
		   NoCafRefs -> Just HsNoCafRefs
		   _other    -> Nothing

    ------------  Strictness  --------------
	-- No point in explicitly exporting TopSig
    strict_hsinfo = case newStrictnessInfo id_info of
			Just sig | not (isTopSig sig) -> Just (HsStrictness sig)
			_other			      -> Nothing

    ------------  Worker  --------------
    work_info   = workerInfo id_info
    has_worker  = case work_info of { HasWorker _ _ -> True; other -> False }
    wrkr_hsinfo = case work_info of
		    HasWorker work_id wrap_arity -> 
			Just (HsWorker (ext (idName work_id)) wrap_arity)
		    NoWorker -> Nothing

    ------------  Unfolding  --------------
    -- The unfolding is redundant if there is a worker
    unfold_info = unfoldingInfo id_info
    inline_prag = inlinePragInfo id_info
    rhs		= unfoldingTemplate unfold_info
    unfold_hsinfo |  neverUnfold unfold_info 	-- The CoreTidy phase retains unfolding info iff
		  || has_worker = Nothing	-- we want to expose the unfolding, taking into account
						-- unconditional NOINLINE, etc.  See TidyPgm.addExternal
		  | otherwise	= Just (HsUnfold inline_prag (toIfaceExpr ext rhs))

--------------------------
coreRuleToIfaceRule :: (Name -> IfaceExtName) 	-- For the LHS names
		    -> (Name -> IfaceExtName) 	-- For the RHS names
		    -> CoreRule -> IfaceRule
coreRuleToIfaceRule ext_lhs ext_rhs (BuiltinRule { ru_fn = fn})
  = pprTrace "toHsRule: builtin" (ppr fn) $
    bogusIfaceRule (mkIfaceExtName fn)

coreRuleToIfaceRule ext_lhs ext_rhs
    (Rule { ru_name = name, ru_fn = fn, ru_act = act, ru_bndrs = bndrs,
	    ru_args = args, ru_rhs = rhs, ru_orph = orph })
  = IfaceRule { ifRuleName  = name, ifActivation = act, 
		ifRuleBndrs = map (toIfaceBndr ext_lhs) bndrs,
		ifRuleHead  = ext_lhs fn, 
		ifRuleArgs  = map do_arg args,
		ifRuleRhs   = toIfaceExpr ext_rhs rhs,
		ifRuleOrph  = orph }
  where
	-- For type args we must remove synonyms from the outermost
	-- level.  Reason: so that when we read it back in we'll
	-- construct the same ru_rough field as we have right now;
	-- see tcIfaceRule
    do_arg (Type ty) = IfaceType (toIfaceType ext_lhs (deNoteType ty))
    do_arg arg       = toIfaceExpr ext_lhs arg

bogusIfaceRule :: IfaceExtName -> IfaceRule
bogusIfaceRule id_name
  = IfaceRule { ifRuleName = FSLIT("bogus"), ifActivation = NeverActive,  
	ifRuleBndrs = [], ifRuleHead = id_name, ifRuleArgs = [], 
	ifRuleRhs = IfaceExt id_name, ifRuleOrph = Nothing }

---------------------
toIfaceExpr :: (Name -> IfaceExtName) -> CoreExpr -> IfaceExpr
toIfaceExpr ext (Var v)       = toIfaceVar ext v
toIfaceExpr ext (Lit l)       = IfaceLit l
toIfaceExpr ext (Type ty)     = IfaceType (toIfaceType ext ty)
toIfaceExpr ext (Lam x b)     = IfaceLam (toIfaceBndr ext x) (toIfaceExpr ext b)
toIfaceExpr ext (App f a)     = toIfaceApp ext f [a]
-- gaw 2004
toIfaceExpr ext (Case s x ty as) = IfaceCase (toIfaceExpr ext s) (getOccName x) (toIfaceType ext ty) (map (toIfaceAlt ext) as)
toIfaceExpr ext (Let b e)     = IfaceLet (toIfaceBind ext b) (toIfaceExpr ext e)
toIfaceExpr ext (Note n e)    = IfaceNote (toIfaceNote ext n) (toIfaceExpr ext e)

---------------------
toIfaceNote ext (SCC cc)      = IfaceSCC cc
toIfaceNote ext (Coerce t1 _) = IfaceCoerce (toIfaceType ext t1)
toIfaceNote ext InlineCall    = IfaceInlineCall
toIfaceNote ext InlineMe      = IfaceInlineMe
toIfaceNote ext (CoreNote s)  = IfaceCoreNote s

---------------------
toIfaceBind ext (NonRec b r) = IfaceNonRec (toIfaceIdBndr ext b) (toIfaceExpr ext r)
toIfaceBind ext (Rec prs)    = IfaceRec [(toIfaceIdBndr ext b, toIfaceExpr ext r) | (b,r) <- prs]

---------------------
toIfaceAlt ext (c,bs,r) = (toIfaceCon c, map getOccName bs, toIfaceExpr ext r)

---------------------
toIfaceCon (DataAlt dc) | isTupleTyCon tc = IfaceTupleAlt (tupleTyConBoxity tc)
	   		| otherwise       = IfaceDataAlt (getOccName dc)
	   		where
	   		  tc = dataConTyCon dc
	   
toIfaceCon (LitAlt l) = IfaceLitAlt l
toIfaceCon DEFAULT    = IfaceDefault

---------------------
toIfaceApp ext (App f a) as = toIfaceApp ext f (a:as)
toIfaceApp ext (Var v) as
  = case isDataConWorkId_maybe v of
	-- We convert the *worker* for tuples into IfaceTuples
	Just dc |  isTupleTyCon tc && saturated 
		-> IfaceTuple (tupleTyConBoxity tc) tup_args
	  where
	    val_args  = dropWhile isTypeArg as
	    saturated = val_args `lengthIs` idArity v
	    tup_args  = map (toIfaceExpr ext) val_args
	    tc	      = dataConTyCon dc

        other -> mkIfaceApps ext (toIfaceVar ext v) as

toIfaceApp ext e as = mkIfaceApps ext (toIfaceExpr ext e) as

mkIfaceApps ext f as = foldl (\f a -> IfaceApp f (toIfaceExpr ext a)) f as

---------------------
toIfaceVar :: (Name -> IfaceExtName) -> Id -> IfaceExpr
toIfaceVar ext v 
  | Just fcall <- isFCallId_maybe v = IfaceFCall fcall (toIfaceType ext (idType v))
	  -- Foreign calls have special syntax
  | isExternalName name		    = IfaceExt (ext name)
  | otherwise			    = IfaceLcl (nameOccName name)
  where
    name = idName v
\end{code}


%************************************************************************
%*									*
	Equality, for interface file version generaion only
%*									*
%************************************************************************

Equality over IfaceSyn returns an IfaceEq, not a Bool.  The new constructor is
EqBut, which gives the set of *locally-defined* things whose version must be equal
for the whole thing to be equal.  So the key function is eqIfExt, which compares
IfaceExtNames.

Of course, equality is also done modulo alpha conversion.

\begin{code}
data IfaceEq 
  = Equal 		-- Definitely exactly the same
  | NotEqual		-- Definitely different
  | EqBut OccSet	-- The same provided these local things have not changed

bool :: Bool -> IfaceEq
bool True  = Equal
bool False = NotEqual

zapEq :: IfaceEq -> IfaceEq	-- Used to forget EqBut information
zapEq (EqBut _) = Equal
zapEq other	= other

(&&&) :: IfaceEq -> IfaceEq -> IfaceEq
Equal       &&& x 	    = x
NotEqual    &&& x	    = NotEqual
EqBut occs  &&& Equal       = EqBut occs
EqBut occs  &&& NotEqual    = NotEqual
EqBut occs1 &&& EqBut occs2 = EqBut (occs1 `unionOccSets` occs2)

---------------------
eqIfExt :: IfaceExtName -> IfaceExtName -> IfaceEq
-- This function is the core of the EqBut stuff
eqIfExt (ExtPkg mod1 occ1)     (ExtPkg mod2 occ2)     = bool (mod1==mod2 && occ1==occ2)
eqIfExt (HomePkg mod1 occ1 v1) (HomePkg mod2 occ2 v2) = bool (mod1==mod2 && occ1==occ2 && v1==v2)
eqIfExt (LocalTop occ1)       (LocalTop occ2)      | occ1 == occ2 = EqBut (unitOccSet occ1)
eqIfExt (LocalTopSub occ1 p1) (LocalTop occ2)      | occ1 == occ2 = EqBut (unitOccSet p1)
eqIfExt (LocalTopSub occ1 p1) (LocalTopSub occ2 _) | occ1 == occ2 = EqBut (unitOccSet p1)
eqIfExt n1 n2 = NotEqual
\end{code}


\begin{code}
---------------------
eqIfDecl :: IfaceDecl -> IfaceDecl -> IfaceEq
eqIfDecl (IfaceId s1 t1 i1) (IfaceId s2 t2 i2)
  = bool (s1 == s2) &&& (t1 `eqIfType` t2) &&& (i1 `eqIfIdInfo` i2)

eqIfDecl d1@(IfaceForeign {}) d2@(IfaceForeign {})
  = bool (ifName d1 == ifName d2 && ifExtName d1 == ifExtName d2)

eqIfDecl d1@(IfaceData {}) d2@(IfaceData {})
  = bool (ifName d1    == ifName d2 && 
	  ifRec d1     == ifRec   d2 && 
	  ifVrcs d1    == ifVrcs   d2 && 
	  ifGeneric d1 == ifGeneric d2) &&&
    eqWith (ifTyVars d1) (ifTyVars d2) (\ env -> 
	    eq_ifContext env (ifCtxt d1) (ifCtxt d2) &&& 
    	    eq_hsCD env (ifCons d1) (ifCons d2) 
	)
	-- The type variables of the data type do not scope
	-- over the constructors (any more), but they do scope
	-- over the stupid context in the IfaceConDecls

eqIfDecl d1@(IfaceSyn {}) d2@(IfaceSyn {})
  = bool (ifName d1 == ifName d2) &&&
    eqWith (ifTyVars d1) (ifTyVars d2) (\ env -> 
          eq_ifType env (ifSynRhs d1) (ifSynRhs d2)
        )

eqIfDecl d1@(IfaceClass {}) d2@(IfaceClass {})
  = bool (ifName d1 == ifName d2 && 
	  ifRec d1  == ifRec  d2 && 
	  ifVrcs d1 == ifVrcs d2) &&&
    eqWith (ifTyVars d1) (ifTyVars d2) (\ env -> 
   	  eq_ifContext env (ifCtxt d1) (ifCtxt d2)  &&&
	  eqListBy (eq_hsFD env)    (ifFDs d1)  (ifFDs d2) &&&
	  eqListBy (eq_cls_sig env) (ifSigs d1) (ifSigs d2)
       )

eqIfDecl _ _ = NotEqual	-- default case

-- Helper
eqWith :: [IfaceTvBndr] -> [IfaceTvBndr] -> (EqEnv -> IfaceEq) -> IfaceEq
eqWith = eq_ifTvBndrs emptyEqEnv

-----------------------
eqIfInst d1 d2 = bool (ifDFun d1 == ifDFun d2)
-- All other changes are handled via the version info on the dfun

eqIfRule (IfaceRule n1 a1 bs1 f1 es1 rhs1 o1)
	 (IfaceRule n2 a2 bs2 f2 es2 rhs2 o2)
       = bool (n1==n2 && a1==a2 && o1 == o2) &&&
	 f1 `eqIfExt` f2 &&&
         eq_ifBndrs emptyEqEnv bs1 bs2 (\env -> 
	 zapEq (eqListBy (eq_ifaceExpr env) es1 es2) &&&
		-- zapEq: for the LHSs, ignore the EqBut part
         eq_ifaceExpr env rhs1 rhs2)

eq_hsCD env (IfDataTyCon c1) (IfDataTyCon c2) 
  = eqListBy (eq_ConDecl env) c1 c2

eq_hsCD env (IfNewTyCon c1)  (IfNewTyCon c2)  = eq_ConDecl env c1 c2
eq_hsCD env IfAbstractTyCon  IfAbstractTyCon  = Equal
eq_hsCD env d1		     d2		      = NotEqual

eq_ConDecl env c1@(IfVanillaCon {}) c2@(IfVanillaCon {})
  = bool (ifConOcc c1     == ifConOcc c2 && 
	  ifConInfix c1   == ifConInfix c2 && 
	  ifConStricts c1 == ifConStricts c2 && 
	  ifConFields c1  == ifConFields c2) &&&
   eq_ifTypes env (ifConArgTys c1) (ifConArgTys c2)

eq_ConDecl env c1@(IfGadtCon {}) c2@(IfGadtCon {})
  = bool (ifConOcc c1     == ifConOcc c2 && 
	  ifConStricts c1 == ifConStricts c2) &&& 
    eq_ifTvBndrs env (ifConTyVars c1) (ifConTyVars c2) (\ env ->
	eq_ifContext env (ifConCtxt c1) (ifConCtxt c2) &&&
	eq_ifTypes env (ifConResTys c1) (ifConResTys c2) &&&
	eq_ifTypes env (ifConArgTys c1) (ifConArgTys c2))

eq_ConDecl env c1 c2 = NotEqual

eq_hsFD env (ns1,ms1) (ns2,ms2)
  = eqListBy (eqIfOcc env) ns1 ns2 &&& eqListBy (eqIfOcc env) ms1 ms2

eq_cls_sig env (IfaceClassOp n1 dm1 ty1) (IfaceClassOp n2 dm2 ty2)
  = bool (n1==n2 && dm1 == dm2) &&& eq_ifType env ty1 ty2
\end{code}


\begin{code}
-----------------
eqIfIdInfo NoInfo	 NoInfo	       = Equal
eqIfIdInfo (HasInfo is1) (HasInfo is2) = eqListBy eq_item is1 is2
eqIfIdInfo i1 i2 = NotEqual

eq_item (HsArity a1)	   (HsArity a2)	      = bool (a1 == a2)
eq_item (HsStrictness s1)  (HsStrictness s2)  = bool (s1 == s2)
eq_item (HsUnfold a1 u1)   (HsUnfold a2 u2)   = bool (a1 == a2) &&& eq_ifaceExpr emptyEqEnv u1 u2
eq_item HsNoCafRefs        HsNoCafRefs	      = Equal
eq_item (HsWorker wkr1 a1) (HsWorker wkr2 a2) = bool (a1==a2) &&& (wkr1 `eqIfExt` wkr2)
eq_item _ _ = NotEqual

-----------------
eq_ifaceExpr :: EqEnv -> IfaceExpr -> IfaceExpr -> IfaceEq
eq_ifaceExpr env (IfaceLcl v1)	      (IfaceLcl v2)	   = eqIfOcc env v1 v2
eq_ifaceExpr env (IfaceExt v1)	      (IfaceExt v2)	   = eqIfExt v1 v2
eq_ifaceExpr env (IfaceLit l1)        (IfaceLit l2) 	   = bool (l1 == l2)
eq_ifaceExpr env (IfaceFCall c1 ty1)  (IfaceFCall c2 ty2)  = bool (c1==c2) &&& eq_ifType env ty1 ty2
eq_ifaceExpr env (IfaceType ty1)      (IfaceType ty2)	   = eq_ifType env ty1 ty2
eq_ifaceExpr env (IfaceTuple n1 as1)  (IfaceTuple n2 as2)  = bool (n1==n2) &&& eqListBy (eq_ifaceExpr env) as1 as2
eq_ifaceExpr env (IfaceLam b1 body1)  (IfaceLam b2 body2)  = eq_ifBndr env b1 b2 (\env -> eq_ifaceExpr env body1 body2)
eq_ifaceExpr env (IfaceApp f1 a1)     (IfaceApp f2 a2)	   = eq_ifaceExpr env f1 f2 &&& eq_ifaceExpr env a1 a2
eq_ifaceExpr env (IfaceNote n1 r1)    (IfaceNote n2 r2)    = eq_ifaceNote env n1 n2 &&& eq_ifaceExpr env r1 r2

eq_ifaceExpr env (IfaceCase s1 b1 ty1 as1) (IfaceCase s2 b2 ty2 as2)
  = eq_ifaceExpr env s1 s2 &&&
    eq_ifType env ty1 ty2 &&&
    eq_ifNakedBndr env b1 b2 (\env -> eqListBy (eq_ifaceAlt env) as1 as2)
  where
    eq_ifaceAlt env (c1,bs1,r1) (c2,bs2,r2)
	= bool (eq_ifaceConAlt c1 c2) &&& 
	  eq_ifNakedBndrs env bs1 bs2 (\env -> eq_ifaceExpr env r1 r2)

eq_ifaceExpr env (IfaceLet (IfaceNonRec b1 r1) x1) (IfaceLet (IfaceNonRec b2 r2) x2)
  = eq_ifaceExpr env r1 r2 &&& eq_ifIdBndr env b1 b2 (\env -> eq_ifaceExpr env x1 x2)

eq_ifaceExpr env (IfaceLet (IfaceRec as1) x1) (IfaceLet (IfaceRec as2) x2)
  = eq_ifIdBndrs env bs1 bs2 (\env -> eqListBy (eq_ifaceExpr env) rs1 rs2 &&& eq_ifaceExpr env x1 x2)
  where
    (bs1,rs1) = unzip as1
    (bs2,rs2) = unzip as2


eq_ifaceExpr env _ _ = NotEqual

-----------------
eq_ifaceConAlt :: IfaceConAlt -> IfaceConAlt -> Bool
eq_ifaceConAlt IfaceDefault	  IfaceDefault		= True
eq_ifaceConAlt (IfaceDataAlt n1)  (IfaceDataAlt n2)	= n1==n2
eq_ifaceConAlt (IfaceTupleAlt c1) (IfaceTupleAlt c2)	= c1==c2
eq_ifaceConAlt (IfaceLitAlt l1)	  (IfaceLitAlt l2)	= l1==l2
eq_ifaceConAlt _ _ = False

-----------------
eq_ifaceNote :: EqEnv -> IfaceNote -> IfaceNote -> IfaceEq
eq_ifaceNote env (IfaceSCC c1)    (IfaceSCC c2)        = bool (c1==c2)
eq_ifaceNote env (IfaceCoerce t1) (IfaceCoerce t2)     = eq_ifType env t1 t2
eq_ifaceNote env IfaceInlineCall  IfaceInlineCall      = Equal
eq_ifaceNote env IfaceInlineMe    IfaceInlineMe        = Equal
eq_ifaceNote env (IfaceCoreNote s1) (IfaceCoreNote s2) = bool (s1==s2)
eq_ifaceNote env _ _ = NotEqual
\end{code}

\begin{code}
---------------------
eqIfType t1 t2 = eq_ifType emptyEqEnv t1 t2

-------------------
eq_ifType env (IfaceTyVar n1)         (IfaceTyVar n2)         = eqIfOcc env n1 n2
eq_ifType env (IfaceAppTy s1 t1)      (IfaceAppTy s2 t2)      = eq_ifType env s1 s2 &&& eq_ifType env t1 t2
eq_ifType env (IfacePredTy st1)       (IfacePredTy st2)       = eq_ifPredType env st1 st2
eq_ifType env (IfaceTyConApp tc1 ts1) (IfaceTyConApp tc2 ts2) = tc1 `eqIfTc` tc2 &&& eq_ifTypes env ts1 ts2
eq_ifType env (IfaceForAllTy tv1 t1)  (IfaceForAllTy tv2 t2)  = eq_ifTvBndr env tv1 tv2 (\env -> eq_ifType env t1 t2)
eq_ifType env (IfaceFunTy s1 t1)      (IfaceFunTy s2 t2)      = eq_ifType env s1 s2 &&& eq_ifType env t1 t2
eq_ifType env _ _ = NotEqual

-------------------
eq_ifTypes env = eqListBy (eq_ifType env)

-------------------
eq_ifContext env a b = eqListBy (eq_ifPredType env) a b

-------------------
eq_ifPredType env (IfaceClassP c1 tys1) (IfaceClassP c2 tys2) = c1 `eqIfExt` c2 &&&  eq_ifTypes env tys1 tys2
eq_ifPredType env (IfaceIParam n1 ty1) (IfaceIParam n2 ty2)   = bool (n1 == n2) &&& eq_ifType env ty1 ty2
eq_ifPredType env _ _ = NotEqual

-------------------
eqIfTc (IfaceTc tc1) (IfaceTc tc2) = tc1 `eqIfExt` tc2
eqIfTc IfaceIntTc    IfaceIntTc	   = Equal
eqIfTc IfaceCharTc   IfaceCharTc   = Equal
eqIfTc IfaceBoolTc   IfaceBoolTc   = Equal
eqIfTc IfaceListTc   IfaceListTc   = Equal
eqIfTc IfacePArrTc   IfacePArrTc   = Equal
eqIfTc (IfaceTupTc bx1 ar1) (IfaceTupTc bx2 ar2) = bool (bx1==bx2 && ar1==ar2)
eqIfTc _ _ = NotEqual
\end{code}

-----------------------------------------------------------
	Support code for equality checking
-----------------------------------------------------------

\begin{code}
------------------------------------
type EqEnv = OccEnv OccName	-- Tracks the mapping from L-variables to R-variables

eqIfOcc :: EqEnv -> OccName -> OccName -> IfaceEq
eqIfOcc env n1 n2 = case lookupOccEnv env n1 of
			Just n1 -> bool (n1 == n2)
			Nothing -> bool (n1 == n2)

extendEqEnv :: EqEnv -> OccName -> OccName -> EqEnv
extendEqEnv env n1 n2 | n1 == n2  = env
		      | otherwise = extendOccEnv env n1 n2

emptyEqEnv :: EqEnv
emptyEqEnv = emptyOccEnv

------------------------------------
type ExtEnv bndr = EqEnv -> bndr -> bndr -> (EqEnv -> IfaceEq) -> IfaceEq

eq_ifNakedBndr :: ExtEnv OccName
eq_ifBndr      :: ExtEnv IfaceBndr
eq_ifTvBndr    :: ExtEnv IfaceTvBndr
eq_ifIdBndr    :: ExtEnv IfaceIdBndr

eq_ifNakedBndr env n1 n2 k = k (extendEqEnv env n1 n2)

eq_ifBndr env (IfaceIdBndr b1) (IfaceIdBndr b2) k = eq_ifIdBndr env b1 b2 k
eq_ifBndr env (IfaceTvBndr b1) (IfaceTvBndr b2) k = eq_ifTvBndr env b1 b2 k
eq_ifBndr _ _ _ _ = NotEqual

eq_ifTvBndr env (v1, k1) (v2, k2) k = bool (k1 == k2)     &&& k (extendEqEnv env v1 v2)
eq_ifIdBndr env (v1, t1) (v2, t2) k = eq_ifType env t1 t2 &&& k (extendEqEnv env v1 v2)

eq_ifBndrs   	:: ExtEnv [IfaceBndr]
eq_ifIdBndrs 	:: ExtEnv [IfaceIdBndr]
eq_ifTvBndrs 	:: ExtEnv [IfaceTvBndr]
eq_ifNakedBndrs :: ExtEnv [OccName]
eq_ifBndrs   	= eq_bndrs_with eq_ifBndr
eq_ifIdBndrs 	= eq_bndrs_with eq_ifIdBndr
eq_ifTvBndrs 	= eq_bndrs_with eq_ifTvBndr
eq_ifNakedBndrs = eq_bndrs_with eq_ifNakedBndr

eq_bndrs_with eq env []       []       k = k env
eq_bndrs_with eq env (b1:bs1) (b2:bs2) k = eq env b1 b2 (\env -> eq_bndrs_with eq env bs1 bs2 k)
eq_bndrs_with eq env _	      _	       _ = NotEqual
\end{code}

\begin{code}
eqListBy :: (a->a->IfaceEq) -> [a] -> [a] -> IfaceEq
eqListBy eq []     []     = Equal
eqListBy eq (x:xs) (y:ys) = eq x y &&& eqListBy eq xs ys
eqListBy eq xs     ys     = NotEqual

eqMaybeBy :: (a->a->IfaceEq) -> Maybe a -> Maybe a -> IfaceEq
eqMaybeBy eq Nothing Nothing   = Equal
eqMaybeBy eq (Just x) (Just y) = eq x y
eqMaybeBy eq x        y        = NotEqual
\end{code}
