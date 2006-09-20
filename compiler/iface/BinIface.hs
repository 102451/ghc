{-% DrIFT (Automatic class derivations for Haskell) v1.1 %-}
{-% DrIFT (Automatic class derivations for Haskell) v1.1 %-}
-- 
--  (c) The University of Glasgow 2002
-- 
-- Binary interface file support.

module BinIface ( writeBinIface, readBinIface, v_IgnoreHiWay ) where

#include "HsVersions.h"

import HscTypes
import BasicTypes
import NewDemand
import IfaceSyn
import VarEnv
import InstEnv		( OverlapFlag(..) )
import Class		( DefMeth(..) )
import CostCentre
import StaticFlags	( opt_HiVersion, v_Build_tag )
import Type		( Kind,
                          isLiftedTypeKind, isUnliftedTypeKind, isOpenTypeKind,
			  isArgTypeKind, isUbxTupleKind, liftedTypeKind,
			  unliftedTypeKind, openTypeKind, argTypeKind,  
			  ubxTupleKind, mkArrowKind, splitFunTy_maybe )
import Panic
import Binary
import Util
import Config		( cGhcUnregisterised )

import DATA_IOREF
import EXCEPTION	( throwDyn )
import Monad		( when )
import Outputable

#include "HsVersions.h"

-- ---------------------------------------------------------------------------
writeBinIface :: FilePath -> ModIface -> IO ()
writeBinIface hi_path mod_iface
  = putBinFileWithDict hi_path mod_iface

readBinIface :: FilePath -> IO ModIface
readBinIface hi_path = getBinFileWithDict hi_path


-- %*********************************************************
-- %*						 	    *
-- 		All the Binary instances
-- %*							    *
-- %*********************************************************

-- BasicTypes
{-! for IPName derive: Binary !-}
{-! for Fixity derive: Binary !-}
{-! for FixityDirection derive: Binary !-}
{-! for Boxity derive: Binary !-}
{-! for StrictnessMark derive: Binary !-}
{-! for Activation derive: Binary !-}

-- NewDemand
{-! for Demand derive: Binary !-}
{-! for Demands derive: Binary !-}
{-! for DmdResult derive: Binary !-}
{-! for StrictSig derive: Binary !-}

-- Class
{-! for DefMeth derive: Binary !-}

-- HsTypes
{-! for HsPred derive: Binary !-}
{-! for HsType derive: Binary !-}
{-! for TupCon derive: Binary !-}
{-! for HsTyVarBndr derive: Binary !-}

-- HsCore
{-! for UfExpr derive: Binary !-}
{-! for UfConAlt derive: Binary !-}
{-! for UfBinding derive: Binary !-}
{-! for UfBinder derive: Binary !-}
{-! for HsIdInfo derive: Binary !-}
{-! for UfNote derive: Binary !-}

-- HsDecls
{-! for ConDetails derive: Binary !-}
{-! for BangType derive: Binary !-}

-- CostCentre
{-! for IsCafCC derive: Binary !-}
{-! for IsDupdCC derive: Binary !-}
{-! for CostCentre derive: Binary !-}



-- ---------------------------------------------------------------------------
-- Reading a binary interface into ParsedIface

instance Binary ModIface where
   put_ bh (ModIface {
		 mi_module    = mod,
		 mi_boot      = is_boot,
		 mi_mod_vers  = mod_vers,
		 mi_orphan    = orphan,
		 mi_deps      = deps,
		 mi_usages    = usages,
		 mi_exports   = exports,
		 mi_exp_vers  = exp_vers,
		 mi_fixities  = fixities,
		 mi_deprecs   = deprecs,
		 mi_decls     = decls,
		 mi_insts     = insts,
		 mi_rules     = rules,
		 mi_rule_vers = rule_vers }) = do
	put_ bh (show opt_HiVersion)
	way_descr <- getWayDescr
	put  bh way_descr
	put_ bh mod
	put_ bh is_boot
	put_ bh mod_vers
	put_ bh orphan
	lazyPut bh deps
	lazyPut bh usages
	put_ bh exports
	put_ bh exp_vers
	put_ bh fixities
	lazyPut bh deprecs
        put_ bh decls
	put_ bh insts
	lazyPut bh rules
	put_ bh rule_vers

   get bh = do
	check_ver  <- get bh
	let our_ver = show opt_HiVersion
        when (check_ver /= our_ver) $
	   -- use userError because this will be caught by readIface
	   -- which will emit an error msg containing the iface module name.
	   throwDyn (ProgramError (
		"mismatched interface file versions: expected "
		++ our_ver ++ ", found " ++ check_ver))

	check_way <- get bh
        ignore_way <- readIORef v_IgnoreHiWay
	way_descr <- getWayDescr
        when (not ignore_way && check_way /= way_descr) $
	   -- use userError because this will be caught by readIface
	   -- which will emit an error msg containing the iface module name.
	   throwDyn (ProgramError (
		"mismatched interface file ways: expected "
		++ way_descr ++ ", found " ++ check_way))

	mod_name  <- get bh
	is_boot   <- get bh
	mod_vers  <- get bh
	orphan    <- get bh
	deps	  <- lazyGet bh
	usages	  <- {-# SCC "bin_usages" #-} lazyGet bh
	exports	  <- {-# SCC "bin_exports" #-} get bh
	exp_vers  <- get bh
	fixities  <- {-# SCC "bin_fixities" #-} get bh
	deprecs   <- {-# SCC "bin_deprecs" #-} lazyGet bh
        decls 	  <- {-# SCC "bin_tycldecls" #-} get bh
	insts     <- {-# SCC "bin_insts" #-} get bh
	rules	  <- {-# SCC "bin_rules" #-} lazyGet bh
	rule_vers <- get bh
	return (ModIface {
		 mi_module    = mod_name,
		 mi_boot      = is_boot,
		 mi_mod_vers  = mod_vers,
		 mi_orphan    = orphan,
		 mi_deps      = deps,
		 mi_usages    = usages,
		 mi_exports   = exports,
		 mi_exp_vers  = exp_vers,
		 mi_fixities  = fixities,
		 mi_deprecs   = deprecs,
		 mi_decls     = decls,
		 mi_globals   = Nothing,
		 mi_insts     = insts,
		 mi_rules     = rules,
		 mi_rule_vers = rule_vers,
			-- And build the cached values
		 mi_dep_fn = mkIfaceDepCache deprecs,
		 mi_fix_fn = mkIfaceFixCache fixities,
		 mi_ver_fn = mkIfaceVerCache decls })

GLOBAL_VAR(v_IgnoreHiWay, False, Bool)

getWayDescr :: IO String
getWayDescr = do
  tag <- readIORef v_Build_tag
  if cGhcUnregisterised == "YES" then return ('u':tag) else return tag
	-- if this is an unregisterised build, make sure our interfaces
	-- can't be used by a registerised build.

-------------------------------------------------------------------------
--		Types from: HscTypes
-------------------------------------------------------------------------

instance Binary Dependencies where
    put_ bh deps = do put_ bh (dep_mods deps)
		      put_ bh (dep_pkgs deps)
		      put_ bh (dep_orphs deps)

    get bh = do ms <- get bh 
		ps <- get bh
		os <- get bh
		return (Deps { dep_mods = ms, dep_pkgs = ps, dep_orphs = os })

instance (Binary name) => Binary (GenAvailInfo name) where
    put_ bh (Avail aa) = do
	    putByte bh 0
	    put_ bh aa
    put_ bh (AvailTC ab ac) = do
	    putByte bh 1
	    put_ bh ab
	    put_ bh ac
    get bh = do
	    h <- getByte bh
	    case h of
	      0 -> do aa <- get bh
		      return (Avail aa)
	      _ -> do ab <- get bh
		      ac <- get bh
		      return (AvailTC ab ac)

instance Binary Usage where
    put_ bh usg	= do 
	put_ bh (usg_name     usg)
	put_ bh (usg_mod      usg)
	put_ bh (usg_exports  usg)
	put_ bh (usg_entities usg)
	put_ bh (usg_rules    usg)

    get bh = do
	nm    <- get bh
	mod   <- get bh
	exps  <- get bh
	ents  <- get bh
	rules <- get bh
	return (Usage {	usg_name = nm, usg_mod = mod,
			usg_exports = exps, usg_entities = ents,
			usg_rules = rules })

instance Binary a => Binary (Deprecs a) where
    put_ bh NoDeprecs     = putByte bh 0
    put_ bh (DeprecAll t) = do
	    putByte bh 1
	    put_ bh t
    put_ bh (DeprecSome ts) = do
	    putByte bh 2
	    put_ bh ts

    get bh = do
	    h <- getByte bh
	    case h of
	      0 -> return NoDeprecs
	      1 -> do aa <- get bh
		      return (DeprecAll aa)
	      _ -> do aa <- get bh
		      return (DeprecSome aa)

-------------------------------------------------------------------------
--		Types from: BasicTypes
-------------------------------------------------------------------------

instance Binary Activation where
    put_ bh NeverActive = do
	    putByte bh 0
    put_ bh AlwaysActive = do
	    putByte bh 1
    put_ bh (ActiveBefore aa) = do
	    putByte bh 2
	    put_ bh aa
    put_ bh (ActiveAfter ab) = do
	    putByte bh 3
	    put_ bh ab
    get bh = do
	    h <- getByte bh
	    case h of
	      0 -> do return NeverActive
	      1 -> do return AlwaysActive
	      2 -> do aa <- get bh
		      return (ActiveBefore aa)
	      _ -> do ab <- get bh
		      return (ActiveAfter ab)

instance Binary StrictnessMark where
    put_ bh MarkedStrict = do
	    putByte bh 0
    put_ bh MarkedUnboxed = do
	    putByte bh 1
    put_ bh NotMarkedStrict = do
	    putByte bh 2
    get bh = do
	    h <- getByte bh
	    case h of
	      0 -> do return MarkedStrict
	      1 -> do return MarkedUnboxed
	      _ -> do return NotMarkedStrict

instance Binary Boxity where
    put_ bh Boxed = do
	    putByte bh 0
    put_ bh Unboxed = do
	    putByte bh 1
    get bh = do
	    h <- getByte bh
	    case h of
	      0 -> do return Boxed
	      _ -> do return Unboxed

instance Binary TupCon where
    put_ bh (TupCon ab ac) = do
	    put_ bh ab
	    put_ bh ac
    get bh = do
	  ab <- get bh
	  ac <- get bh
	  return (TupCon ab ac)

instance Binary RecFlag where
    put_ bh Recursive = do
	    putByte bh 0
    put_ bh NonRecursive = do
	    putByte bh 1
    get bh = do
	    h <- getByte bh
	    case h of
	      0 -> do return Recursive
	      _ -> do return NonRecursive

instance Binary DefMeth where
    put_ bh NoDefMeth  = putByte bh 0
    put_ bh DefMeth    = putByte bh 1
    put_ bh GenDefMeth = putByte bh 2
    get bh = do
	    h <- getByte bh
	    case h of
	      0 -> return NoDefMeth
	      1 -> return DefMeth
	      _ -> return GenDefMeth

instance Binary FixityDirection where
    put_ bh InfixL = do
	    putByte bh 0
    put_ bh InfixR = do
	    putByte bh 1
    put_ bh InfixN = do
	    putByte bh 2
    get bh = do
	    h <- getByte bh
	    case h of
	      0 -> do return InfixL
	      1 -> do return InfixR
	      _ -> do return InfixN

instance Binary Fixity where
    put_ bh (Fixity aa ab) = do
	    put_ bh aa
	    put_ bh ab
    get bh = do
	  aa <- get bh
	  ab <- get bh
	  return (Fixity aa ab)

instance (Binary name) => Binary (IPName name) where
    put_ bh (Dupable aa) = do
	    putByte bh 0
	    put_ bh aa
    put_ bh (Linear ab) = do
	    putByte bh 1
	    put_ bh ab
    get bh = do
	    h <- getByte bh
	    case h of
	      0 -> do aa <- get bh
		      return (Dupable aa)
	      _ -> do ab <- get bh
		      return (Linear ab)

-------------------------------------------------------------------------
--		Types from: Demand
-------------------------------------------------------------------------

instance Binary DmdType where
	-- Ignore DmdEnv when spitting out the DmdType
  put bh (DmdType _ ds dr) = do p <- put bh ds; put bh dr; return (castBin p)
  get bh = do ds <- get bh; dr <- get bh; return (DmdType emptyVarEnv ds dr)

instance Binary Demand where
    put_ bh Top = do
	    putByte bh 0
    put_ bh Abs = do
	    putByte bh 1
    put_ bh (Call aa) = do
	    putByte bh 2
	    put_ bh aa
    put_ bh (Eval ab) = do
	    putByte bh 3
	    put_ bh ab
    put_ bh (Defer ac) = do
	    putByte bh 4
	    put_ bh ac
    put_ bh (Box ad) = do
	    putByte bh 5
	    put_ bh ad
    put_ bh Bot = do
	    putByte bh 6
    get bh = do
	    h <- getByte bh
	    case h of
	      0 -> do return Top
	      1 -> do return Abs
	      2 -> do aa <- get bh
		      return (Call aa)
	      3 -> do ab <- get bh
		      return (Eval ab)
	      4 -> do ac <- get bh
		      return (Defer ac)
	      5 -> do ad <- get bh
		      return (Box ad)
	      _ -> do return Bot

instance Binary Demands where
    put_ bh (Poly aa) = do
	    putByte bh 0
	    put_ bh aa
    put_ bh (Prod ab) = do
	    putByte bh 1
	    put_ bh ab
    get bh = do
	    h <- getByte bh
	    case h of
	      0 -> do aa <- get bh
		      return (Poly aa)
	      _ -> do ab <- get bh
		      return (Prod ab)

instance Binary DmdResult where
    put_ bh TopRes = do
	    putByte bh 0
    put_ bh RetCPR = do
	    putByte bh 1
    put_ bh BotRes = do
	    putByte bh 2
    get bh = do
	    h <- getByte bh
	    case h of
	      0 -> do return TopRes
	      1 -> do return RetCPR	-- Really use RetCPR even if -fcpr-off
					-- The wrapper was generated for CPR in 
					-- the imported module!
	      _ -> do return BotRes

instance Binary StrictSig where
    put_ bh (StrictSig aa) = do
	    put_ bh aa
    get bh = do
	  aa <- get bh
	  return (StrictSig aa)


-------------------------------------------------------------------------
--		Types from: CostCentre
-------------------------------------------------------------------------

instance Binary IsCafCC where
    put_ bh CafCC = do
	    putByte bh 0
    put_ bh NotCafCC = do
	    putByte bh 1
    get bh = do
	    h <- getByte bh
	    case h of
	      0 -> do return CafCC
	      _ -> do return NotCafCC

instance Binary IsDupdCC where
    put_ bh OriginalCC = do
	    putByte bh 0
    put_ bh DupdCC = do
	    putByte bh 1
    get bh = do
	    h <- getByte bh
	    case h of
	      0 -> do return OriginalCC
	      _ -> do return DupdCC

instance Binary CostCentre where
    put_ bh NoCostCentre = do
	    putByte bh 0
    put_ bh (NormalCC aa ab ac ad) = do
	    putByte bh 1
	    put_ bh aa
	    put_ bh ab
	    put_ bh ac
	    put_ bh ad
    put_ bh (AllCafsCC ae) = do
	    putByte bh 2
	    put_ bh ae
    get bh = do
	    h <- getByte bh
	    case h of
	      0 -> do return NoCostCentre
	      1 -> do aa <- get bh
		      ab <- get bh
		      ac <- get bh
		      ad <- get bh
		      return (NormalCC aa ab ac ad)
	      _ -> do ae <- get bh
		      return (AllCafsCC ae)

-------------------------------------------------------------------------
--		IfaceTypes and friends
-------------------------------------------------------------------------

instance Binary IfaceExtName where
    put_ bh (ExtPkg mod occ) = do
	    putByte bh 0
	    put_ bh mod
	    put_ bh occ
    put_ bh (HomePkg mod occ vers) = do
	    putByte bh 1
	    put_ bh mod
	    put_ bh occ
	    put_ bh vers
    put_ bh (LocalTop occ) = do
	    putByte bh 2
	    put_ bh occ
    put_ bh (LocalTopSub occ _) = do	-- Write LocalTopSub just like LocalTop
	    putByte bh 2
	    put_ bh occ

    get bh = do
	    h <- getByte bh
	    case h of
	      0 -> do mod <- get bh
		      occ <- get bh
		      return (ExtPkg mod occ)
	      1 -> do mod <- get bh
		      occ <- get bh
		      vers <- get bh
		      return (HomePkg mod occ vers)
	      _ -> do occ <- get bh
		      return (LocalTop occ)

instance Binary IfaceBndr where
    put_ bh (IfaceIdBndr aa) = do
	    putByte bh 0
	    put_ bh aa
    put_ bh (IfaceTvBndr ab) = do
	    putByte bh 1
	    put_ bh ab
    get bh = do
	    h <- getByte bh
	    case h of
	      0 -> do aa <- get bh
		      return (IfaceIdBndr aa)
	      _ -> do ab <- get bh
		      return (IfaceTvBndr ab)

instance Binary IfaceType where
    put_ bh (IfaceForAllTy aa ab) = do
	    putByte bh 0
	    put_ bh aa
	    put_ bh ab
    put_ bh (IfaceTyVar ad) = do
	    putByte bh 1
	    put_ bh ad
    put_ bh (IfaceAppTy ae af) = do
	    putByte bh 2
	    put_ bh ae
	    put_ bh af
    put_ bh (IfaceFunTy ag ah) = do
	    putByte bh 3
	    put_ bh ag
	    put_ bh ah
    put_ bh (IfacePredTy aq) = do
	    putByte bh 5
	    put_ bh aq

	-- Simple compression for common cases of TyConApp
    put_ bh (IfaceTyConApp IfaceIntTc  [])   = putByte bh 6
    put_ bh (IfaceTyConApp IfaceCharTc [])   = putByte bh 7
    put_ bh (IfaceTyConApp IfaceBoolTc [])   = putByte bh 8
    put_ bh (IfaceTyConApp IfaceListTc [ty]) = do { putByte bh 9; put_ bh ty }
	-- Unit tuple and pairs
    put_ bh (IfaceTyConApp (IfaceTupTc Boxed 0) []) 	 = putByte bh 10
    put_ bh (IfaceTyConApp (IfaceTupTc Boxed 2) [t1,t2]) = do { putByte bh 11; put_ bh t1; put_ bh t2 }
        -- Kind cases
    put_ bh (IfaceTyConApp IfaceLiftedTypeKindTc [])   = putByte bh 12
    put_ bh (IfaceTyConApp IfaceOpenTypeKindTc [])     = putByte bh 13
    put_ bh (IfaceTyConApp IfaceUnliftedTypeKindTc []) = putByte bh 14
    put_ bh (IfaceTyConApp IfaceUbxTupleKindTc [])     = putByte bh 15
    put_ bh (IfaceTyConApp IfaceArgTypeKindTc [])      = putByte bh 16

	-- Generic cases

    put_ bh (IfaceTyConApp (IfaceTc tc) tys) = do { putByte bh 18; put_ bh tc; put_ bh tys }
    put_ bh (IfaceTyConApp tc tys) 	     = do { putByte bh 19; put_ bh tc; put_ bh tys }

    get bh = do
	    h <- getByte bh
	    case h of
	      0 -> do aa <- get bh
		      ab <- get bh
		      return (IfaceForAllTy aa ab)
	      1 -> do ad <- get bh
		      return (IfaceTyVar ad)
	      2 -> do ae <- get bh
		      af <- get bh
		      return (IfaceAppTy ae af)
	      3 -> do ag <- get bh
		      ah <- get bh
		      return (IfaceFunTy ag ah)
	      5 -> do ap <- get bh
		      return (IfacePredTy ap)

		-- Now the special cases for TyConApp
	      6 -> return (IfaceTyConApp IfaceIntTc [])
	      7 -> return (IfaceTyConApp IfaceCharTc [])
	      8 -> return (IfaceTyConApp IfaceBoolTc [])
	      9 -> do { ty <- get bh; return (IfaceTyConApp IfaceListTc [ty]) }
	      10 -> return (IfaceTyConApp (IfaceTupTc Boxed 0) [])
	      11 -> do { t1 <- get bh; t2 <- get bh; return (IfaceTyConApp (IfaceTupTc Boxed 2) [t1,t2]) }
              12 -> return (IfaceTyConApp IfaceLiftedTypeKindTc [])
              13 -> return (IfaceTyConApp IfaceOpenTypeKindTc [])
              14 -> return (IfaceTyConApp IfaceUnliftedTypeKindTc [])
              15 -> return (IfaceTyConApp IfaceUbxTupleKindTc [])
              16 -> return (IfaceTyConApp IfaceArgTypeKindTc [])

	      18 -> do { tc <- get bh; tys <- get bh; return (IfaceTyConApp (IfaceTc tc) tys) }
	      _  -> do { tc <- get bh; tys <- get bh; return (IfaceTyConApp tc tys) }

instance Binary IfaceTyCon where
	-- Int,Char,Bool can't show up here because they can't not be saturated

   put_ bh IfaceIntTc  	      = putByte bh 1
   put_ bh IfaceBoolTc 	      = putByte bh 2
   put_ bh IfaceCharTc 	      = putByte bh 3
   put_ bh IfaceListTc 	      = putByte bh 4
   put_ bh IfacePArrTc 	      = putByte bh 5
   put_ bh IfaceLiftedTypeKindTc   = putByte bh 6
   put_ bh IfaceOpenTypeKindTc     = putByte bh 7
   put_ bh IfaceUnliftedTypeKindTc = putByte bh 8
   put_ bh IfaceUbxTupleKindTc     = putByte bh 9
   put_ bh IfaceArgTypeKindTc      = putByte bh 10
   put_ bh (IfaceTupTc bx ar) = do { putByte bh 11; put_ bh bx; put_ bh ar }
   put_ bh (IfaceTc ext)      = do { putByte bh 12; put_ bh ext }

   get bh = do
	h <- getByte bh
	case h of
	  1 -> return IfaceIntTc
	  2 -> return IfaceBoolTc
	  3 -> return IfaceCharTc
	  4 -> return IfaceListTc
	  5 -> return IfacePArrTc
          6 -> return IfaceLiftedTypeKindTc 
          7 -> return IfaceOpenTypeKindTc 
          8 -> return IfaceUnliftedTypeKindTc
          9 -> return IfaceUbxTupleKindTc
          10 -> return IfaceArgTypeKindTc
	  11 -> do { bx <- get bh; ar <- get bh; return (IfaceTupTc bx ar) }
	  _ -> do { ext <- get bh; return (IfaceTc ext) }

instance Binary IfacePredType where
    put_ bh (IfaceClassP aa ab) = do
	    putByte bh 0
	    put_ bh aa
	    put_ bh ab
    put_ bh (IfaceIParam ac ad) = do
	    putByte bh 1
	    put_ bh ac
	    put_ bh ad
    put_ bh (IfaceEqPred ac ad) = do
	    putByte bh 2
	    put_ bh ac
	    put_ bh ad
    get bh = do
	    h <- getByte bh
	    case h of
	      0 -> do aa <- get bh
		      ab <- get bh
		      return (IfaceClassP aa ab)
	      1 -> do ac <- get bh
		      ad <- get bh
		      return (IfaceIParam ac ad)
	      2 -> do ac <- get bh
		      ad <- get bh
		      return (IfaceEqPred ac ad)

-------------------------------------------------------------------------
--		IfaceExpr and friends
-------------------------------------------------------------------------

instance Binary IfaceExpr where
    put_ bh (IfaceLcl aa) = do
	    putByte bh 0
	    put_ bh aa
    put_ bh (IfaceType ab) = do
	    putByte bh 1
	    put_ bh ab
    put_ bh (IfaceTuple ac ad) = do
	    putByte bh 2
	    put_ bh ac
	    put_ bh ad
    put_ bh (IfaceLam ae af) = do
	    putByte bh 3
	    put_ bh ae
	    put_ bh af
    put_ bh (IfaceApp ag ah) = do
	    putByte bh 4
	    put_ bh ag
	    put_ bh ah
-- gaw 2004
    put_ bh (IfaceCase ai aj al ak) = do
	    putByte bh 5
	    put_ bh ai
	    put_ bh aj
-- gaw 2004
            put_ bh al
	    put_ bh ak
    put_ bh (IfaceLet al am) = do
	    putByte bh 6
	    put_ bh al
	    put_ bh am
    put_ bh (IfaceNote an ao) = do
	    putByte bh 7
	    put_ bh an
	    put_ bh ao
    put_ bh (IfaceLit ap) = do
	    putByte bh 8
	    put_ bh ap
    put_ bh (IfaceFCall as at) = do
	    putByte bh 9
	    put_ bh as
	    put_ bh at
    put_ bh (IfaceExt aa) = do
	    putByte bh 10
	    put_ bh aa
    put_ bh (IfaceCast ie ico) = do
            putByte bh 11
            put_ bh ie
            put_ bh ico
    get bh = do
	    h <- getByte bh
	    case h of
	      0 -> do aa <- get bh
		      return (IfaceLcl aa)
	      1 -> do ab <- get bh
		      return (IfaceType ab)
	      2 -> do ac <- get bh
		      ad <- get bh
		      return (IfaceTuple ac ad)
	      3 -> do ae <- get bh
		      af <- get bh
		      return (IfaceLam ae af)
	      4 -> do ag <- get bh
		      ah <- get bh
		      return (IfaceApp ag ah)
	      5 -> do ai <- get bh
		      aj <- get bh
-- gaw 2004
                      al <- get bh                   
		      ak <- get bh
-- gaw 2004
		      return (IfaceCase ai aj al ak)
	      6 -> do al <- get bh
		      am <- get bh
		      return (IfaceLet al am)
	      7 -> do an <- get bh
		      ao <- get bh
		      return (IfaceNote an ao)
	      8 -> do ap <- get bh
		      return (IfaceLit ap)
	      9 -> do as <- get bh
		      at <- get bh
		      return (IfaceFCall as at)
	      10 -> do aa <- get bh
		       return (IfaceExt aa)
              11 -> do ie <- get bh
                       ico <- get bh
                       return (IfaceCast ie ico)

instance Binary IfaceConAlt where
    put_ bh IfaceDefault = do
	    putByte bh 0
    put_ bh (IfaceDataAlt aa) = do
	    putByte bh 1
	    put_ bh aa
    put_ bh (IfaceTupleAlt ab) = do
	    putByte bh 2
	    put_ bh ab
    put_ bh (IfaceLitAlt ac) = do
	    putByte bh 3
	    put_ bh ac
    get bh = do
	    h <- getByte bh
	    case h of
	      0 -> do return IfaceDefault
	      1 -> do aa <- get bh
		      return (IfaceDataAlt aa)
	      2 -> do ab <- get bh
		      return (IfaceTupleAlt ab)
	      _ -> do ac <- get bh
		      return (IfaceLitAlt ac)

instance Binary IfaceBinding where
    put_ bh (IfaceNonRec aa ab) = do
	    putByte bh 0
	    put_ bh aa
	    put_ bh ab
    put_ bh (IfaceRec ac) = do
	    putByte bh 1
	    put_ bh ac
    get bh = do
	    h <- getByte bh
	    case h of
	      0 -> do aa <- get bh
		      ab <- get bh
		      return (IfaceNonRec aa ab)
	      _ -> do ac <- get bh
		      return (IfaceRec ac)

instance Binary IfaceIdInfo where
    put_ bh NoInfo = putByte bh 0
    put_ bh (HasInfo i) = do
	    putByte bh 1
	    lazyPut bh i			-- NB lazyPut

    get bh = do
	    h <- getByte bh
	    case h of
	      0 -> return NoInfo
	      _ -> do info <- lazyGet bh	-- NB lazyGet
		      return (HasInfo info)

instance Binary IfaceInfoItem where
    put_ bh (HsArity aa) = do
	    putByte bh 0
	    put_ bh aa
    put_ bh (HsStrictness ab) = do
	    putByte bh 1
	    put_ bh ab
    put_ bh (HsUnfold ad) = do
	    putByte bh 2
	    put_ bh ad
    put_ bh (HsInline ad) = do
	    putByte bh 3
	    put_ bh ad
    put_ bh HsNoCafRefs = do
	    putByte bh 4
    put_ bh (HsWorker ae af) = do
	    putByte bh 5
	    put_ bh ae
	    put_ bh af
    get bh = do
	    h <- getByte bh
	    case h of
	      0 -> do aa <- get bh
		      return (HsArity aa)
	      1 -> do ab <- get bh
		      return (HsStrictness ab)
	      2 -> do ad <- get bh
		      return (HsUnfold ad)
	      3 -> do ad <- get bh
		      return (HsInline ad)
	      4 -> do return HsNoCafRefs
	      _ -> do ae <- get bh
		      af <- get bh
		      return (HsWorker ae af)

instance Binary IfaceNote where
    put_ bh (IfaceSCC aa) = do
	    putByte bh 0
	    put_ bh aa
    put_ bh IfaceInlineMe = do
	    putByte bh 3
    put_ bh (IfaceCoreNote s) = do
            putByte bh 4
            put_ bh s
    get bh = do
	    h <- getByte bh
	    case h of
	      0 -> do aa <- get bh
		      return (IfaceSCC aa)
	      3 -> do return IfaceInlineMe
              4 -> do ac <- get bh
                      return (IfaceCoreNote ac)


-------------------------------------------------------------------------
--		IfaceDecl and friends
-------------------------------------------------------------------------

instance Binary IfaceDecl where
    put_ bh (IfaceId name ty idinfo) = do
	    putByte bh 0
	    put_ bh name
	    put_ bh ty
	    put_ bh idinfo
    put_ bh (IfaceForeign ae af) = 
	error "Binary.put_(IfaceDecl): IfaceForeign"
    put_ bh (IfaceData a1 a2 a3 a4 a5 a6 a7 a8) = do
	    putByte bh 2
	    put_ bh a1
	    put_ bh a2
	    put_ bh a3
	    put_ bh a4
	    put_ bh a5
	    put_ bh a6
	    put_ bh a7
	    put_ bh a8
    put_ bh (IfaceSyn aq ar as at) = do
	    putByte bh 3
	    put_ bh aq
	    put_ bh ar
	    put_ bh as
	    put_ bh at
    put_ bh (IfaceClass a1 a2 a3 a4 a5 a6 a7) = do
	    putByte bh 4
	    put_ bh a1
	    put_ bh a2
	    put_ bh a3
	    put_ bh a4
	    put_ bh a5
	    put_ bh a6
	    put_ bh a7
    get bh = do
	    h <- getByte bh
	    case h of
	      0 -> do name   <- get bh
		      ty     <- get bh
		      idinfo <- get bh
		      return (IfaceId name ty idinfo)
	      1 -> error "Binary.get(TyClDecl): ForeignType"
	      2 -> do
		    a1 <- get bh
		    a2 <- get bh
		    a3 <- get bh
		    a4 <- get bh
		    a5 <- get bh
		    a6 <- get bh
		    a7 <- get bh
		    a8 <- get bh
		    return (IfaceData a1 a2 a3 a4 a5 a6 a7 a8)
	      3 -> do
		    aq <- get bh
		    ar <- get bh
		    as <- get bh
		    at <- get bh
		    return (IfaceSyn aq ar as at)
	      _ -> do
		    a1 <- get bh
		    a2 <- get bh
		    a3 <- get bh
		    a4 <- get bh
		    a5 <- get bh
		    a6 <- get bh
		    a7 <- get bh
		    return (IfaceClass a1 a2 a3 a4 a5 a6 a7)

instance Binary IfaceInst where
    put_ bh (IfaceInst cls tys dfun flag orph) = do
	    put_ bh cls
	    put_ bh tys
	    put_ bh dfun
	    put_ bh flag
	    put_ bh orph
    get bh = do cls  <- get bh
		tys  <- get bh
		dfun <- get bh
		flag <- get bh
		orph <- get bh
		return (IfaceInst cls tys dfun flag orph)

instance Binary OverlapFlag where
    put_ bh NoOverlap  = putByte bh 0
    put_ bh OverlapOk  = putByte bh 1
    put_ bh Incoherent = putByte bh 2
    get bh = do h <- getByte bh
		case h of
		  0 -> return NoOverlap
		  1 -> return OverlapOk
		  2 -> return Incoherent

instance Binary IfaceConDecls where
    put_ bh IfAbstractTyCon = putByte bh 0
    put_ bh IfOpenDataTyCon = putByte bh 1
    put_ bh IfOpenNewTyCon = putByte bh 2
    put_ bh (IfDataTyCon cs) = do { putByte bh 3
				  ; put_ bh cs }
    put_ bh (IfNewTyCon c)  = do { putByte bh 4
				  ; put_ bh c }
    get bh = do
	    h <- getByte bh
	    case h of
	      0 -> return IfAbstractTyCon
	      1 -> return IfOpenDataTyCon
	      2 -> return IfOpenNewTyCon
	      3 -> do cs <- get bh
		      return (IfDataTyCon cs)
	      _ -> do aa <- get bh
		      return (IfNewTyCon aa)

instance Binary IfaceConDecl where
    put_ bh (IfCon a1 a2 a3 a4 a5 a6 a7 a8 a9 a10) = do
	    put_ bh a1
	    put_ bh a2
	    put_ bh a3
	    put_ bh a4
	    put_ bh a5
	    put_ bh a6
	    put_ bh a7
	    put_ bh a8
	    put_ bh a9
	    put_ bh a10
    get bh = do a1 <- get bh
		a2 <- get bh
		a3 <- get bh	      
		a4 <- get bh
		a5 <- get bh
		a6 <- get bh
		a7 <- get bh
		a8 <- get bh
		a9 <- get bh
		a10 <- get bh
	        return (IfCon a1 a2 a3 a4 a5 a6 a7 a8 a9 a10)

instance Binary IfaceClassOp where
   put_ bh (IfaceClassOp n def ty) = do	
	put_ bh n 
	put_ bh def	
	put_ bh ty
   get bh = do
	n <- get bh
	def <- get bh
	ty <- get bh
	return (IfaceClassOp n def ty)

instance Binary IfaceRule where
    put_ bh (IfaceRule a1 a2 a3 a4 a5 a6 a7) = do
	    put_ bh a1
	    put_ bh a2
	    put_ bh a3
	    put_ bh a4
	    put_ bh a5
	    put_ bh a6
	    put_ bh a7
    get bh = do
	    a1 <- get bh
	    a2 <- get bh
	    a3 <- get bh
	    a4 <- get bh
	    a5 <- get bh
	    a6 <- get bh
	    a7 <- get bh
	    return (IfaceRule a1 a2 a3 a4 a5 a6 a7)


