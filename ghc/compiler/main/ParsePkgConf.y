{
module ParsePkgConf( loadPackageConfig ) where

import Packages  ( PackageConfig(..), defaultPackageConfig )
import Lex
import FastString
import StringBuffer
import SrcLoc
import Outputable
import Panic     ( GhcException(..) )
import Exception ( throwDyn )

#include "HsVersions.h"

}

%token
 '{'		{ ITocurly }
 '}'		{ ITccurly }
 '['		{ ITobrack }
 ']'		{ ITcbrack }
 ','		{ ITcomma }
 '='		{ ITequal }
 VARID   	{ ITvarid    $$ }
 CONID   	{ ITconid    $$ }
 STRING		{ ITstring   $$ }

%monad { P } { thenP } { returnP }
%lexer { lexer } { ITeof }
%name parse
%tokentype { Token }
%%

pkgconf :: { [ PackageConfig ] }
	: '[' ']'			{ [] }
	| '[' pkgs ']'			{ reverse $2 }

pkgs 	:: { [ PackageConfig ] }
	: pkg 				{ [ $1 ] }
	| pkgs ',' pkg			{ $3 : $1 }

pkg 	:: { PackageConfig }
	: CONID '{' fields '}'		{ $3 defaultPackageConfig }

fields  :: { PackageConfig -> PackageConfig }
	: field				{ \p -> $1 p }
	| fields ',' field		{ \p -> $1 ($3 p) }

field	:: { PackageConfig -> PackageConfig }
	: VARID '=' STRING		
                 {% case unpackFS $1 of { 
		   "name" -> returnP (\ p -> p{name = unpackFS $3});
		   _      -> happyError } }
			
	| VARID '=' strlist		
		{\p -> case unpackFS $1 of
		        "import_dirs"     -> p{import_dirs     = $3}
		        "library_dirs"    -> p{library_dirs    = $3}
		        "hs_libraries"    -> p{hs_libraries    = $3}
		        "extra_libraries" -> p{extra_libraries = $3}
		        "include_dirs"    -> p{include_dirs    = $3}
		        "c_includes"      -> p{c_includes      = $3}
		        "package_deps"    -> p{package_deps    = $3}
		        "extra_ghc_opts"  -> p{extra_ghc_opts  = $3}
		        "extra_cc_opts"   -> p{extra_cc_opts   = $3}
		        "extra_ld_opts"   -> p{extra_ld_opts   = $3}
		        "framework_dirs"  -> p{framework_dirs  = $3}
		        "extra_frameworks"-> p{extra_frameworks= $3}
			_other            -> p
		}

strlist :: { [String] }
        : '[' ']'			{ [] }
	| '[' strs ']'			{ reverse $2 }

strs	:: { [String] }
	: STRING			{ [ unpackFS $1 ] }
	| strs ',' STRING		{ unpackFS $3 : $1 }

{
happyError :: P a
happyError buf PState{ loc = loc } = PFailed (srcParseErr buf loc)

loadPackageConfig :: FilePath -> IO [PackageConfig]
loadPackageConfig conf_filename = do
   buf <- hGetStringBuffer conf_filename
   let loc  = mkSrcLoc (mkFastString conf_filename) 1
       exts = ExtFlags {glasgowExtsEF = False,
		        ffiEF	      = False,
			withEF	      = False,
			parrEF	      = False}
   case parse buf (mkPState loc exts) of
	PFailed err -> do
	    freeStringBuffer buf
            throwDyn (InstallationError (showSDoc err))

	POk _ pkg_details -> do
	    freeStringBuffer buf
	    return pkg_details
}
