%
% (c) The GRASP/AQUA Project, Glasgow University, 1993-2000
%

\section[GHC_Main]{Main driver for Glasgow Haskell compiler}

\begin{code}
module HscMain ( 
	HscResult(..),
	hscMain, newHscEnv, hscCmmFile, 
	hscBufferCheck, hscFileCheck,
#ifdef GHCI
	, hscStmt, hscTcExpr, hscKcType
	, hscGetInfo, GetInfoResult
	, compileExpr
#endif
	) where

#include "HsVersions.h"

#ifdef GHCI
import HsSyn		( Stmt(..), LStmt, LHsExpr, LHsType )
import IfaceSyn		( IfaceDecl, IfaceInst )
import Module		( Module )
import CodeOutput	( outputForeignStubs )
import ByteCodeGen	( byteCodeGen, coreExprToBCOs )
import Linker		( HValue, linkExpr )
import TidyPgm		( tidyCoreExpr )
import CorePrep		( corePrepExpr )
import Flattening	( flattenExpr )
import TcRnDriver	( tcRnStmt, tcRnExpr, tcRnGetInfo, GetInfoResult, tcRnType ) 
import RdrName		( rdrNameOcc )
import OccName		( occNameUserString )
import Type		( Type )
import PrelNames	( iNTERACTIVE )
import StringBuffer	( stringToStringBuffer )
import Kind		( Kind )
import Var		( Id )
import CoreLint		( lintUnfolding )
import DsMeta		( templateHaskellNames )
import BasicTypes	( Fixity )
import SrcLoc		( SrcLoc, noSrcLoc )
#endif

import RdrName		( RdrName )
import HsSyn		( HsModule )
import SrcLoc		( Located(..) )
import StringBuffer	( hGetStringBuffer )
import Parser
import Lexer		( P(..), ParseResult(..), mkPState )
import SrcLoc		( mkSrcLoc )
import TcRnDriver	( tcRnModule, tcRnExtCore )
import TcRnTypes	( TcGblEnv )
import TcIface		( typecheckIface )
import IfaceEnv		( initNameCache )
import LoadIface	( ifaceStats, initExternalPackageState )
import PrelInfo		( wiredInThings, basicKnownKeyNames )
import RdrName		( GlobalRdrEnv )
import MkIface		( checkOldIface, mkIface )
import Desugar
import Flattening       ( flatten )
import SimplCore
import TidyPgm		( tidyCorePgm )
import CorePrep		( corePrepPgm )
import CoreToStg	( coreToStg )
import Name		( Name, NamedThing(..) )
import SimplStg		( stg2stg )
import CodeGen		( codeGen )
import CmmParse		( parseCmmFile )
import CodeOutput	( codeOutput )

import CmdLineOpts
import DriverPhases     ( HscSource(..) )
import ErrUtils
import UniqSupply	( mkSplitUniqSupply )

import Outputable
import HscStats		( ppSourceStats )
import HscTypes
import MkExternalCore	( emitExternalCore )
import ParserCore
import ParserCoreUtils
import FastString
import Maybes		( expectJust )
import StringBuffer	( StringBuffer )
import Bag		( unitBag, emptyBag )

import Monad		( when )
import Maybe		( isJust )
import IO
import DATA_IOREF	( newIORef, readIORef )
\end{code}


%************************************************************************
%*									*
		Initialisation
%*									*
%************************************************************************

\begin{code}
newHscEnv :: GhciMode -> DynFlags -> IO HscEnv
newHscEnv ghci_mode dflags
  = do 	{ eps_var <- newIORef initExternalPackageState
	; us      <- mkSplitUniqSupply 'r'
	; nc_var  <- newIORef (initNameCache us knownKeyNames)
	; return (HscEnv { hsc_mode   = ghci_mode,
			   hsc_dflags = dflags,
			   hsc_HPT    = emptyHomePackageTable,
			   hsc_EPS    = eps_var,
			   hsc_NC     = nc_var } ) }
			

knownKeyNames :: [Name]	-- Put here to avoid loops involving DsMeta,
			-- where templateHaskellNames are defined
knownKeyNames = map getName wiredInThings 
	      ++ basicKnownKeyNames
#ifdef GHCI
	      ++ templateHaskellNames
#endif
\end{code}


%************************************************************************
%*									*
		The main compiler pipeline
%*									*
%************************************************************************

\begin{code}
data HscResult
   -- Compilation failed
   = HscFail

   -- In IDE mode: we just do the static/dynamic checks
   | HscChecked (Located (HsModule RdrName)) (Maybe TcGblEnv)

   -- Concluded that it wasn't necessary
   | HscNoRecomp ModDetails  	         -- new details (HomeSymbolTable additions)
	         ModIface	         -- new iface (if any compilation was done)

   -- Did recompilation
   | HscRecomp   ModDetails  		-- new details (HomeSymbolTable additions)
                 ModIface		-- new iface (if any compilation was done)
	         Bool	 	 	-- stub_h exists
	         Bool  		 	-- stub_c exists
	         (Maybe CompiledByteCode)


-- What to do when we have compiler error or warning messages
type MessageAction = Messages -> IO ()

	-- no errors or warnings; the individual passes
	-- (parse/rename/typecheck) print messages themselves

hscMain
  :: HscEnv
  -> MessageAction	-- What to do with errors/warnings
  -> ModSummary
  -> Bool		-- True <=> source unchanged
  -> Bool		-- True <=> have an object file (for msgs only)
  -> Maybe ModIface	-- Old interface, if available
  -> IO HscResult

hscMain hsc_env msg_act mod_summary
	source_unchanged have_object maybe_old_iface
 = do {
      (recomp_reqd, maybe_checked_iface) <- 
		_scc_ "checkOldIface" 
		checkOldIface hsc_env mod_summary 
			      source_unchanged maybe_old_iface;

      let no_old_iface = not (isJust maybe_checked_iface)
          what_next | recomp_reqd || no_old_iface = hscRecomp 
                    | otherwise                   = hscNoRecomp

      ; what_next hsc_env msg_act mod_summary have_object 
		  maybe_checked_iface
      }


------------------------------
-- hscNoRecomp definitely expects to have the old interface available
hscNoRecomp hsc_env msg_act mod_summary 
	    have_object (Just old_iface)
 | isOneShot (hsc_mode hsc_env)
 = do {
      compilationProgressMsg (hsc_dflags hsc_env) $
	"compilation IS NOT required";
      dumpIfaceStats hsc_env ;

      let { bomb = panic "hscNoRecomp:OneShot" };
      return (HscNoRecomp bomb bomb)
      }
 | otherwise
 = do	{ compilationProgressMsg (hsc_dflags hsc_env) $
		("Skipping  " ++ showModMsg have_object mod_summary)

	; new_details <- _scc_ "tcRnIface"
		     typecheckIface hsc_env old_iface ;
	; dumpIfaceStats hsc_env

	; return (HscNoRecomp new_details old_iface)
    }

------------------------------
hscRecomp hsc_env msg_act mod_summary
	  have_object maybe_checked_iface
 = case ms_hsc_src mod_summary of
     HsSrcFile -> do { front_res <- hscFileFrontEnd hsc_env msg_act mod_summary
    		     ; hscBackEnd hsc_env mod_summary maybe_checked_iface front_res }

     HsBootFile -> do { front_res <- hscFileFrontEnd hsc_env msg_act mod_summary
		      ; hscBootBackEnd hsc_env mod_summary maybe_checked_iface front_res }

     ExtCoreFile -> do { front_res <- hscCoreFrontEnd hsc_env msg_act mod_summary
    		       ; hscBackEnd hsc_env mod_summary maybe_checked_iface front_res }

hscCoreFrontEnd hsc_env msg_act mod_summary = do {
 	    -------------------
 	    -- PARSE
 	    -------------------
	; inp <- readFile (expectJust "hscCoreFrontEnd" (ms_hspp_file mod_summary))
	; case parseCore inp 1 of
	    FailP s        -> putMsg s{-ToDo: wrong-} >> return Nothing
	    OkP rdr_module -> do {
    
 	    -------------------
 	    -- RENAME and TYPECHECK
 	    -------------------
	; (tc_msgs, maybe_tc_result) <- _scc_ "TypeCheck" 
			      tcRnExtCore hsc_env rdr_module
	; msg_act tc_msgs
	; case maybe_tc_result of
      	     Nothing       -> return Nothing
      	     Just mod_guts -> return (Just mod_guts)	-- No desugaring to do!
	}}
	 

hscFileFrontEnd hsc_env msg_act mod_summary = do {
 	    -------------------
 	    -- DISPLAY PROGRESS MESSAGE
 	    -------------------
	  let one_shot  = isOneShot (hsc_mode hsc_env)
      	; let dflags    = hsc_dflags hsc_env
	; let toInterp  = dopt_HscTarget dflags == HscInterpreted
      	; when (not one_shot) $
		 compilationProgressMsg dflags $
		 ("Compiling " ++ showModMsg (not toInterp) mod_summary)
			
 	    -------------------
 	    -- PARSE
 	    -------------------
	; let hspp_file = expectJust "hscFileFrontEnd" (ms_hspp_file mod_summary)
	      hspp_buf  = ms_hspp_buf  mod_summary

	; maybe_parsed <- myParseModule (hsc_dflags hsc_env) hspp_file hspp_buf

	; case maybe_parsed of {
      	     Left err -> do { msg_act (unitBag err, emptyBag)
			    ; return Nothing } ;
      	     Right rdr_module -> do {

 	    -------------------
 	    -- RENAME and TYPECHECK
 	    -------------------
	  (tc_msgs, maybe_tc_result) 
		<- _scc_ "Typecheck-Rename" 
		   tcRnModule hsc_env (ms_hsc_src mod_summary) rdr_module

	; msg_act tc_msgs
	; case maybe_tc_result of {
      	     Nothing -> return Nothing ;
      	     Just tc_result -> do {

 	    -------------------
 	    -- DESUGAR
 	    -------------------
	; (warns, maybe_ds_result) <- _scc_ "DeSugar" 
		 	     deSugar hsc_env tc_result
	; msg_act (warns, emptyBag)
	; case maybe_ds_result of
	    Nothing        -> return Nothing
	    Just ds_result -> return (Just ds_result)
	}}}}}

------------------------------
hscBootBackEnd :: HscEnv -> ModSummary -> Maybe ModIface -> Maybe ModGuts -> IO HscResult
-- For hs-boot files, there's no code generation to do

hscBootBackEnd hsc_env mod_summary maybe_checked_iface Nothing 
  = return HscFail
hscBootBackEnd hsc_env mod_summary maybe_checked_iface (Just ds_result)
  = do	{ final_iface <- _scc_ "MkFinalIface" 
			 mkIface hsc_env (ms_location mod_summary)
                         	 maybe_checked_iface ds_result

	; let { final_details = ModDetails { md_types = mg_types ds_result,
					     md_insts = mg_insts ds_result,
					     md_rules = mg_rules ds_result } }
      	  -- And the answer is ...
	; dumpIfaceStats hsc_env

	; return (HscRecomp final_details
			    final_iface
                            False False Nothing)
 	}

------------------------------
hscBackEnd :: HscEnv -> ModSummary -> Maybe ModIface -> Maybe ModGuts -> IO HscResult

hscBackEnd hsc_env mod_summary maybe_checked_iface Nothing 
  = return HscFail

hscBackEnd hsc_env mod_summary maybe_checked_iface (Just ds_result) 
  = do 	{ 	-- OMITTED: 
		-- ; seqList imported_modules (return ())

	  let one_shot  = isOneShot (hsc_mode hsc_env)
	      dflags    = hsc_dflags hsc_env

 	    -------------------
 	    -- FLATTENING
 	    -------------------
	; flat_result <- _scc_ "Flattening"
 			 flatten hsc_env ds_result


{-	TEMP: need to review space-leak fixing here
	NB: even the code generator can force one of the
	    thunks for constructor arguments, for newtypes in particular

	; let 	-- Rule-base accumulated from imported packages
	     pkg_rule_base = eps_rule_base (hsc_EPS hsc_env)

		-- In one-shot mode, ZAP the external package state at
		-- this point, because we aren't going to need it from
		-- now on.  We keep the name cache, however, because
		-- tidyCore needs it.
	     pcs_middle 
		 | one_shot  = pcs_tc{ pcs_EPS = error "pcs_EPS missing" }
		 | otherwise = pcs_tc

	; pkg_rule_base `seq` pcs_middle `seq` return ()
-}

	-- alive at this point:  
	--	pcs_middle
	--	flat_result
	--      pkg_rule_base

 	    -------------------
 	    -- SIMPLIFY
 	    -------------------
	; simpl_result <- _scc_ "Core2Core"
			  core2core hsc_env flat_result

 	    -------------------
 	    -- TIDY
 	    -------------------
	; tidy_result <- _scc_ "CoreTidy"
		         tidyCorePgm hsc_env simpl_result

	-- Emit external core
	; emitExternalCore dflags tidy_result

	-- Alive at this point:  
	--	tidy_result, pcs_final
	--      hsc_env

 	    -------------------
	    -- BUILD THE NEW ModIface and ModDetails
	    --	and emit external core if necessary
	    -- This has to happen *after* code gen so that the back-end
	    -- info has been set.  Not yet clear if it matters waiting
	    -- until after code output
	; new_iface <- _scc_ "MkFinalIface" 
			mkIface hsc_env (ms_location mod_summary)
                         	maybe_checked_iface tidy_result

	    -- Space leak reduction: throw away the new interface if
	    -- we're in one-shot mode; we won't be needing it any
	    -- more.
	; final_iface <-
	     if one_shot then return (error "no final iface")
			 else return new_iface

	    -- Build the final ModDetails (except in one-shot mode, where
	    -- we won't need this information after compilation).
	; final_details <- 
	     if one_shot then return (error "no final details")
		 	 else return $! ModDetails { 
					   md_types = mg_types tidy_result,
					   md_insts = mg_insts tidy_result,
					   md_rules = mg_rules tidy_result }

 	    -------------------
 	    -- CONVERT TO STG and COMPLETE CODE GENERATION
	; (stub_h_exists, stub_c_exists, maybe_bcos)
		<- hscCodeGen dflags tidy_result

      	  -- And the answer is ...
	; dumpIfaceStats hsc_env

	; return (HscRecomp final_details
			    final_iface
                            stub_h_exists stub_c_exists
      			    maybe_bcos)
      	 }


hscFileCheck hsc_env msg_act hspp_file = do {
 	    -------------------
 	    -- PARSE
 	    -------------------
	; maybe_parsed <- myParseModule (hsc_dflags hsc_env)  hspp_file Nothing

	; case maybe_parsed of {
      	     Left err -> do { msg_act (unitBag err, emptyBag) ;
			    ; return HscFail ;
			    };
      	     Right rdr_module -> hscBufferTypecheck hsc_env rdr_module msg_act
	}}


-- Perform static/dynamic checks on the source code in a StringBuffer
-- This is a temporary solution: it'll read in interface files lazily, whereas
-- we probably want to use the compilation manager to load in all the modules
-- in a project.
hscBufferCheck :: HscEnv -> StringBuffer -> MessageAction -> IO HscResult
hscBufferCheck hsc_env buffer msg_act = do
	let loc  = mkSrcLoc (mkFastString "*edit*") 1 0
        showPass (hsc_dflags hsc_env) "Parser"
	case unP parseModule (mkPState buffer loc (hsc_dflags hsc_env)) of
		PFailed span err -> do
		   msg_act (emptyBag, unitBag (mkPlainErrMsg span err))
		   return HscFail
		POk _ rdr_module -> do
		   hscBufferTypecheck hsc_env rdr_module msg_act

hscBufferTypecheck hsc_env rdr_module msg_act = do
	(tc_msgs, maybe_tc_result) <- _scc_ "Typecheck-Rename" 
					tcRnModule hsc_env HsSrcFile rdr_module
	msg_act tc_msgs
	case maybe_tc_result of
	    Nothing  -> return (HscChecked rdr_module Nothing)
				-- space leak on rdr_module!
	    Just r -> return (HscChecked rdr_module (Just r))


hscCodeGen dflags 
    ModGuts{  -- This is the last use of the ModGuts in a compilation.
	      -- From now on, we just use the bits we need.
        mg_module   = this_mod,
	mg_binds    = core_binds,
	mg_types    = type_env,
	mg_dir_imps = dir_imps,
	mg_foreign  = foreign_stubs,
	mg_deps     = dependencies     }  = do {

 	    -------------------
 	    -- PREPARE FOR CODE GENERATION
	    -- Do saturation and convert to A-normal form
  prepd_binds <- _scc_ "CorePrep"
		 corePrepPgm dflags core_binds type_env;

  case dopt_HscTarget dflags of
      HscNothing -> return (False, False, Nothing)

      HscInterpreted ->
#ifdef GHCI
	do  -----------------  Generate byte code ------------------
	    comp_bc <- byteCodeGen dflags prepd_binds type_env
	
	    ------------------ Create f-x-dynamic C-side stuff ---
	    (istub_h_exists, istub_c_exists) 
	       <- outputForeignStubs dflags foreign_stubs
	    
	    return ( istub_h_exists, istub_c_exists, Just comp_bc )
#else
	panic "GHC not compiled with interpreter"
#endif

      other ->
	do
	    -----------------  Convert to STG ------------------
	    (stg_binds, cost_centre_info) <- _scc_ "CoreToStg"
	    		 myCoreToStg dflags this_mod prepd_binds	

            ------------------  Code generation ------------------
	    abstractC <- _scc_ "CodeGen"
		         codeGen dflags this_mod type_env foreign_stubs
				 dir_imps cost_centre_info stg_binds

	    ------------------  Code output -----------------------
	    (stub_h_exists, stub_c_exists)
		     <- codeOutput dflags this_mod foreign_stubs 
				dependencies abstractC

	    return (stub_h_exists, stub_c_exists, Nothing)
   }


hscCmmFile :: DynFlags -> FilePath -> IO Bool
hscCmmFile dflags filename = do
  maybe_cmm <- parseCmmFile dflags filename
  case maybe_cmm of
    Nothing -> return False
    Just cmm -> do
	codeOutput dflags no_mod NoStubs noDependencies [cmm]
	return True
  where
	no_mod = panic "hscCmmFile: no_mod"


myParseModule dflags src_filename maybe_src_buf
 = do --------------------------  Parser  ----------------
      showPass dflags "Parser"
      _scc_  "Parser" do

	-- sometimes we already have the buffer in memory, perhaps
	-- because we needed to parse the imports out of it, or get the 
	-- module name.
      buf <- case maybe_src_buf of
		Just b  -> return b
		Nothing -> hGetStringBuffer src_filename

      let loc  = mkSrcLoc (mkFastString src_filename) 1 0

      case unP parseModule (mkPState buf loc dflags) of {

	PFailed span err -> return (Left (mkPlainErrMsg span err));

	POk _ rdr_module -> do {

      dumpIfSet_dyn dflags Opt_D_dump_parsed "Parser" (ppr rdr_module) ;
      
      dumpIfSet_dyn dflags Opt_D_source_stats "Source Statistics"
			   (ppSourceStats False rdr_module) ;
      
      return (Right rdr_module)
	-- ToDo: free the string buffer later.
      }}


myCoreToStg dflags this_mod prepd_binds
 = do 
      stg_binds <- _scc_ "Core2Stg" 
	     coreToStg dflags prepd_binds

      (stg_binds2, cost_centre_info) <- _scc_ "Core2Stg" 
	     stg2stg dflags this_mod stg_binds

      return (stg_binds2, cost_centre_info)
\end{code}


%************************************************************************
%*									*
\subsection{Compiling a do-statement}
%*									*
%************************************************************************

When the UnlinkedBCOExpr is linked you get an HValue of type
	IO [HValue]
When you run it you get a list of HValues that should be 
the same length as the list of names; add them to the ClosureEnv.

A naked expression returns a singleton Name [it].

	What you type			The IO [HValue] that hscStmt returns
	-------------			------------------------------------
	let pat = expr		==> 	let pat = expr in return [coerce HVal x, coerce HVal y, ...]
					bindings: [x,y,...]

	pat <- expr		==> 	expr >>= \ pat -> return [coerce HVal x, coerce HVal y, ...]
					bindings: [x,y,...]

	expr (of IO type)	==>	expr >>= \ v -> return [v]
	  [NB: result not printed]	bindings: [it]
	  

	expr (of non-IO type, 
	  result showable)	==>	let v = expr in print v >> return [v]
	  				bindings: [it]

	expr (of non-IO type, 
	  result not showable)	==>	error

\begin{code}
#ifdef GHCI
hscStmt		-- Compile a stmt all the way to an HValue, but don't run it
  :: HscEnv
  -> InteractiveContext		-- Context for compiling
  -> String			-- The statement
  -> IO (Maybe (InteractiveContext, [Name], HValue))

hscStmt hsc_env icontext stmt
  = do	{ maybe_stmt <- hscParseStmt (hsc_dflags hsc_env) stmt
	; case maybe_stmt of {
      	     Nothing	  -> return Nothing ;	-- Parse error
      	     Just Nothing -> return Nothing ;	-- Empty line
      	     Just (Just parsed_stmt) -> do {	-- The real stuff

		-- Rename and typecheck it
	  maybe_tc_result
		 <- tcRnStmt hsc_env icontext parsed_stmt

	; case maybe_tc_result of {
		Nothing -> return Nothing ;
		Just (new_ic, bound_names, tc_expr) -> do {

		-- Then desugar, code gen, and link it
	; hval <- compileExpr hsc_env iNTERACTIVE 
			      (ic_rn_gbl_env new_ic) 
			      (ic_type_env new_ic)
			      tc_expr

	; return (Just (new_ic, bound_names, hval))
	}}}}}

hscTcExpr	-- Typecheck an expression (but don't run it)
  :: HscEnv
  -> InteractiveContext		-- Context for compiling
  -> String			-- The expression
  -> IO (Maybe Type)

hscTcExpr hsc_env icontext expr
  = do	{ maybe_stmt <- hscParseStmt (hsc_dflags hsc_env) expr
	; case maybe_stmt of {
	     Nothing      -> return Nothing ;	-- Parse error
	     Just (Just (L _ (ExprStmt expr _)))
			-> tcRnExpr hsc_env icontext expr ;
	     Just other -> do { errorMsg ("not an expression: `" ++ expr ++ "'") ;
			        return Nothing } ;
      	     } }

hscKcType	-- Find the kind of a type
  :: HscEnv
  -> InteractiveContext		-- Context for compiling
  -> String			-- The type
  -> IO (Maybe Kind)

hscKcType hsc_env icontext str
  = do	{ maybe_type <- hscParseType (hsc_dflags hsc_env) str
	; case maybe_type of {
	     Just ty	-> tcRnType hsc_env icontext ty ;
	     Just other -> do { errorMsg ("not an type: `" ++ str ++ "'") ;
			        return Nothing } ;
      	     Nothing    -> return Nothing } }
\end{code}

\begin{code}
hscParseStmt :: DynFlags -> String -> IO (Maybe (Maybe (LStmt RdrName)))
hscParseStmt = hscParseThing parseStmt

hscParseType :: DynFlags -> String -> IO (Maybe (LHsType RdrName))
hscParseType = hscParseThing parseType

hscParseIdentifier :: DynFlags -> String -> IO (Maybe (Located RdrName))
hscParseIdentifier = hscParseThing parseIdentifier

hscParseThing :: Outputable thing
	      => Lexer.P thing
	      -> DynFlags -> String
	      -> IO (Maybe thing)
	-- Nothing => Parse error (message already printed)
	-- Just x  => success
hscParseThing parser dflags str
 = do showPass dflags "Parser"
      _scc_ "Parser"  do

      buf <- stringToStringBuffer str

      let loc  = mkSrcLoc FSLIT("<interactive>") 1 0

      case unP parser (mkPState buf loc dflags) of {

	PFailed span err -> do { printError span err;
                                 return Nothing };

	POk _ thing -> do {

      --ToDo: can't free the string buffer until we've finished this
      -- compilation sweep and all the identifiers have gone away.
      dumpIfSet_dyn dflags Opt_D_dump_parsed "Parser" (ppr thing);
      return (Just thing)
      }}
#endif
\end{code}

%************************************************************************
%*									*
\subsection{Getting information about an identifer}
%*									*
%************************************************************************

\begin{code}
#ifdef GHCI
hscGetInfo -- like hscStmt, but deals with a single identifier
  :: HscEnv
  -> InteractiveContext		-- Context for compiling
  -> String			-- The identifier
  -> IO [GetInfoResult]

hscGetInfo hsc_env ic str
   = do maybe_rdr_name <- hscParseIdentifier (hsc_dflags hsc_env) str
	case maybe_rdr_name of {
	  Nothing -> return [];
	  Just (L _ rdr_name) -> do

	maybe_tc_result <- tcRnGetInfo hsc_env ic rdr_name

	case maybe_tc_result of
	     Nothing     -> return []
	     Just things -> return things
 	}
#endif
\end{code}

%************************************************************************
%*									*
	Desugar, simplify, convert to bytecode, and link an expression
%*									*
%************************************************************************

\begin{code}
#ifdef GHCI
compileExpr :: HscEnv 
	    -> Module -> GlobalRdrEnv -> TypeEnv
	    -> LHsExpr Id
	    -> IO HValue

compileExpr hsc_env this_mod rdr_env type_env tc_expr
  = do	{ let { dflags  = hsc_dflags hsc_env ;
		lint_on = dopt Opt_DoCoreLinting dflags }
	      
	 	-- Desugar it
	; ds_expr <- deSugarExpr hsc_env this_mod rdr_env type_env tc_expr
	
		-- Flatten it
	; flat_expr <- flattenExpr hsc_env ds_expr

		-- Simplify it
	; simpl_expr <- simplifyExpr dflags flat_expr

		-- Tidy it (temporary, until coreSat does cloning)
	; tidy_expr <- tidyCoreExpr simpl_expr

		-- Prepare for codegen
	; prepd_expr <- corePrepExpr dflags tidy_expr

		-- Lint if necessary
		-- ToDo: improve SrcLoc
	; if lint_on then 
		case lintUnfolding noSrcLoc [] prepd_expr of
		   Just err -> pprPanic "compileExpr" err
		   Nothing  -> return ()
	  else
		return ()

		-- Convert to BCOs
	; bcos <- coreExprToBCOs dflags prepd_expr

		-- link it
	; hval <- linkExpr hsc_env bcos

	; return hval
     }
#endif
\end{code}


%************************************************************************
%*									*
	Statistics on reading interfaces
%*									*
%************************************************************************

\begin{code}
dumpIfaceStats :: HscEnv -> IO ()
dumpIfaceStats hsc_env
  = do	{ eps <- readIORef (hsc_EPS hsc_env)
	; dumpIfSet (dump_if_trace || dump_rn_stats)
	      	    "Interface statistics"
	      	    (ifaceStats eps) }
  where
    dflags = hsc_dflags hsc_env
    dump_rn_stats = dopt Opt_D_dump_rn_stats dflags
    dump_if_trace = dopt Opt_D_dump_if_trace dflags
\end{code}
