module Settings.Builders.GhcCabal (
    cabalArgs, ghcCabalHsColourArgs, ghcIncludeDirs, bootPackageDbArgs,
    customPackageArgs, ccArgs, cppArgs, ccWarnings, argStagedSettingList, needDll0
    ) where

import Expression
import Predicates hiding (stage)
import Settings

cabalArgs :: Args
cabalArgs = builder GhcCabal ? do
    path <- getPackagePath
    dir  <- getTargetDirectory
    mconcat [ arg "configure"
            , arg path
            , arg dir
            , dll0Args
            , withStaged Ghc
            , withStaged GhcPkg
            , stage0 ? bootPackageDbArgs
            , libraryArgs
            , with HsColour
            , configureArgs
            , packageConstraints
            , withStaged Gcc
            , notStage0 ? with Ld
            , with Ar
            , with Alex
            , with Happy ]

ghcCabalHsColourArgs :: Args
ghcCabalHsColourArgs = builder GhcCabalHsColour ? do
    path <- getPackagePath
    dir  <- getTargetDirectory
    mconcat [ arg "hscolour"
            , arg path
            , arg dir ]

-- TODO: Isn't vanilla always built? If yes, some conditions are redundant.
-- TODO: Need compiler_stage1_CONFIGURE_OPTS += --disable-library-for-ghci?
libraryArgs :: Args
libraryArgs = do
    ways     <- getWays
    withGhci <- lift ghcWithInterpreter
    append [ if vanilla `elem` ways
             then  "--enable-library-vanilla"
             else "--disable-library-vanilla"
           , if vanilla `elem` ways && withGhci && not dynamicGhcPrograms
             then  "--enable-library-for-ghci"
             else "--disable-library-for-ghci"
           , if profiling `elem` ways
             then  "--enable-library-profiling"
             else "--disable-library-profiling"
           , if dynamic `elem` ways
             then  "--enable-shared"
             else "--disable-shared" ]

-- TODO: LD_OPTS?
configureArgs :: Args
configureArgs = do
    let conf key = appendSubD $ "--configure-option=" ++ key
        cFlags   = mconcat [ ccArgs
                           , remove ["-Werror"]
                           , argStagedSettingList ConfCcArgs ]
        ldFlags  = ldArgs  <> (argStagedSettingList ConfGccLinkerArgs)
        cppFlags = cppArgs <> (argStagedSettingList ConfCppArgs)
    mconcat
        [ conf "CFLAGS"   cFlags
        , conf "LDFLAGS"  ldFlags
        , conf "CPPFLAGS" cppFlags
        , appendSubD "--gcc-options" $ cFlags <> ldFlags
        , conf "--with-iconv-includes"    $ argSettingList IconvIncludeDirs
        , conf "--with-iconv-libraries"   $ argSettingList IconvLibDirs
        , conf "--with-gmp-includes"      $ argSettingList GmpIncludeDirs
        , conf "--with-gmp-libraries"     $ argSettingList GmpLibDirs
        , crossCompiling ? (conf "--host" $ argSetting TargetPlatformFull)
        , conf "--with-cc" $ argStagedBuilderPath Gcc ]

bootPackageDbArgs :: Args
bootPackageDbArgs = do
    path <- getSetting GhcSourcePath
    arg $ "--package-db=" ++ path -/- "libraries/bootstrapping.conf"

packageConstraints :: Args
packageConstraints = stage0 ? do
    constraints <- lift . readFileLines $ bootPackageConstraints
    append $ concat [ ["--constraint", c] | c <- constraints ]

-- TODO: should be in a different file
-- TODO: put all validating options together in one file
ccArgs :: Args
ccArgs = validating ? ccWarnings

-- TODO: should be in a different file
ccWarnings :: Args
ccWarnings = do
    let gccGe46 = notM $ (flag GccIsClang ||^ flag GccLt46)
    mconcat [ arg "-Werror"
            , arg "-Wall"
            , flag GccIsClang ? arg "-Wno-unknown-pragmas"
            , gccGe46 ? notM windowsHost ? arg "-Werror=unused-but-set-variable"
            , gccGe46 ? arg "-Wno-error=inline" ]

ldArgs :: Args
ldArgs = mempty

ghcIncludeDirs :: [FilePath]
ghcIncludeDirs = [ "includes", "includes/dist"
                 , "includes/dist-derivedconstants/header"
                 , "includes/dist-ghcconstants/header" ]

cppArgs :: Args
cppArgs = append $ map ("-I" ++) ghcIncludeDirs

-- TODO: Is this needed?
-- ifeq "$(GMP_PREFER_FRAMEWORK)" "YES"
-- libraries/integer-gmp_CONFIGURE_OPTS += --with-gmp-framework-preferred
-- endif

-- TODO: move this somewhere
customPackageArgs :: Args
customPackageArgs = do
    nextStage <- fmap succ getStage
    rtsWays   <- getRtsWays
    mconcat
        [ package integerGmp ?
          mconcat [ windowsHost ? builder GhcCabal ?
                    arg "--configure-option=--with-intree-gmp"
                  , appendCcArgs ["-I" ++ pkgPath integerGmp -/- "gmp"] ]

        , package base ?
          builder GhcCabal ?
          arg ("--flags=" ++ takeFileName (pkgPath integerLibrary))

        , package ghcPrim ?
          builder GhcCabal ? arg "--flag=include-ghc-prim"

        , package compiler ?
          builder GhcCabal ?
          mconcat [ arg $ "--ghc-option=-DSTAGE=" ++ show nextStage
                  , arg $ "--flags=stage" ++ show nextStage
                  , arg "--disable-library-for-ghci"
                  , anyTargetOs ["openbsd"] ? arg "--ld-options=-E"
                  , flag GhcUnregisterised ? arg "--ghc-option=-DNO_REGS"
                  , notM ghcWithSMP ? arg "--ghc-option=-DNOSMP"
                  , notM ghcWithSMP ? arg "--ghc-option=-optc-DNOSMP"
                  , (threaded `elem` rtsWays) ?
                    notStage0 ? arg "--ghc-option=-optc-DTHREADED_RTS"
                  , ghcWithNativeCodeGen ? arg "--flags=ncg"
                  , ghcWithInterpreter ?
                    notStage0 ? arg "--flags=ghci"
                  , ghcWithInterpreter ?
                    ghcEnableTablesNextToCode ?
                    notM (flag GhcUnregisterised) ?
                    notStage0 ? arg "--ghc-option=-DGHCI_TABLES_NEXT_TO_CODE"
                  , ghcWithInterpreter ?
                    ghciWithDebugger ?
                    notStage0 ? arg "--ghc-option=-DDEBUGGER"
                  , ghcProfiled ?
                    notStage0 ? arg "--ghc-pkg-option=--force"
                  ]
        , package ghc ?
          builder GhcCabal ?
          mconcat [ arg $ "--flags=stage" ++ show nextStage
                  , ghcWithInterpreter ?
                    notStage0 ? arg "--flags=ghci"
                  ]
        , package haddock ?
          builder GhcCabal ? append ["--flag", "in-ghc-tree"]
        ]

withBuilderKey :: Builder -> String
withBuilderKey b = case b of
    Ar       -> "--with-ar="
    Ld       -> "--with-ld="
    Gcc _    -> "--with-gcc="
    Ghc _    -> "--with-ghc="
    Alex     -> "--with-alex="
    Happy    -> "--with-happy="
    GhcPkg _ -> "--with-ghc-pkg="
    HsColour -> "--with-hscolour="
    _        -> error "withBuilderKey: not supported builder"

-- Expression 'with Gcc' appends "--with-gcc=/path/to/gcc" and needs Gcc.
with :: Builder -> Args
with b = specified b ? do
    path <- getBuilderPath b
    lift $ needBuilder laxDependencies b
    append [withBuilderKey b ++ path]

withStaged :: (Stage -> Builder) -> Args
withStaged sb = (with . sb) =<< getStage

argM :: Action String -> Args
argM = (arg =<<) . lift

argSetting :: Setting -> Args
argSetting = argM . setting

argSettingList :: SettingList -> Args
argSettingList = (append =<<) . lift . settingList

argStagedSettingList :: (Stage -> SettingList) -> Args
argStagedSettingList ss = (argSettingList . ss) =<< getStage

argStagedBuilderPath :: (Stage -> Builder) -> Args
argStagedBuilderPath sb = (argM . builderPath . sb) =<< getStage

-- Pass arguments to Gcc and corresponding lists of sub-arguments of GhcCabal
appendCcArgs :: [String] -> Args
appendCcArgs xs = do
    mconcat [ stagedBuilder Gcc  ? append xs
            , stagedBuilder GccM ? append xs
            , builder GhcCabal   ? appendSub "--configure-option=CFLAGS" xs
            , builder GhcCabal   ? appendSub "--gcc-options" xs ]

needDll0 :: Stage -> Package -> Action Bool
needDll0 stage pkg = do
    windows <- windowsHost
    return $ windows && pkg == compiler && stage == Stage1

-- This is a positional argument, hence:
-- * if it is empty, we need to emit one empty string argument;
-- * otherwise, we must collapse it into one space-separated string.
dll0Args :: Args
dll0Args = do
    stage    <- getStage
    pkg      <- getPackage
    dll0     <- lift $ needDll0 stage pkg
    withGhci <- lift ghcWithInterpreter
    arg . unwords . concat $ [ modules     | dll0             ]
                          ++ [ ghciModules | dll0 && withGhci ] -- see #9552
  where
    modules = [ "Annotations"
              , "ApiAnnotation"
              , "Avail"
              , "Bag"
              , "BasicTypes"
              , "Binary"
              , "BooleanFormula"
              , "BreakArray"
              , "BufWrite"
              , "Class"
              , "CmdLineParser"
              , "CmmType"
              , "CoAxiom"
              , "ConLike"
              , "Coercion"
              , "Config"
              , "Constants"
              , "CoreArity"
              , "CoreFVs"
              , "CoreSubst"
              , "CoreSyn"
              , "CoreTidy"
              , "CoreUnfold"
              , "CoreUtils"
              , "CoreSeq"
              , "CoreStats"
              , "CostCentre"
              , "Ctype"
              , "DataCon"
              , "Demand"
              , "Digraph"
              , "DriverPhases"
              , "DynFlags"
              , "Encoding"
              , "ErrUtils"
              , "Exception"
              , "ExtsCompat46"
              , "FamInstEnv"
              , "FastFunctions"
              , "FastMutInt"
              , "FastString"
              , "FastTypes"
              , "Fingerprint"
              , "FiniteMap"
              , "ForeignCall"
              , "Hooks"
              , "HsBinds"
              , "HsDecls"
              , "HsDoc"
              , "HsExpr"
              , "HsImpExp"
              , "HsLit"
              , "PlaceHolder"
              , "HsPat"
              , "HsSyn"
              , "HsTypes"
              , "HsUtils"
              , "HscTypes"
              , "IOEnv"
              , "Id"
              , "IdInfo"
              , "IfaceSyn"
              , "IfaceType"
              , "InstEnv"
              , "Kind"
              , "Lexeme"
              , "Lexer"
              , "ListSetOps"
              , "Literal"
              , "Maybes"
              , "MkCore"
              , "MkId"
              , "Module"
              , "MonadUtils"
              , "Name"
              , "NameEnv"
              , "NameSet"
              , "OccName"
              , "OccurAnal"
              , "OptCoercion"
              , "OrdList"
              , "Outputable"
              , "PackageConfig"
              , "Packages"
              , "Pair"
              , "Panic"
              , "PatSyn"
              , "PipelineMonad"
              , "Platform"
              , "PlatformConstants"
              , "PprCore"
              , "PrelNames"
              , "PrelRules"
              , "Pretty"
              , "PrimOp"
              , "RdrName"
              , "Rules"
              , "Serialized"
              , "SrcLoc"
              , "StaticFlags"
              , "StringBuffer"
              , "TcEvidence"
              , "TcRnTypes"
              , "TcType"
              , "TrieMap"
              , "TyCon"
              , "Type"
              , "TypeRep"
              , "TysPrim"
              , "TysWiredIn"
              , "Unify"
              , "UniqFM"
              , "UniqSet"
              , "UniqSupply"
              , "Unique"
              , "Util"
              , "Var"
              , "VarEnv"
              , "VarSet" ]
    ghciModules = [ "Bitmap"
                  , "BlockId"
                  , "ByteCodeAsm"
                  , "ByteCodeInstr"
                  , "ByteCodeItbls"
                  , "CLabel"
                  , "Cmm"
                  , "CmmCallConv"
                  , "CmmExpr"
                  , "CmmInfo"
                  , "CmmMachOp"
                  , "CmmNode"
                  , "CmmSwitch"
                  , "CmmUtils"
                  , "CodeGen.Platform"
                  , "CodeGen.Platform.ARM"
                  , "CodeGen.Platform.ARM64"
                  , "CodeGen.Platform.NoRegs"
                  , "CodeGen.Platform.PPC"
                  , "CodeGen.Platform.PPC_Darwin"
                  , "CodeGen.Platform.SPARC"
                  , "CodeGen.Platform.X86"
                  , "CodeGen.Platform.X86_64"
                  , "FastBool"
                  , "Hoopl"
                  , "Hoopl.Dataflow"
                  , "InteractiveEvalTypes"
                  , "MkGraph"
                  , "PprCmm"
                  , "PprCmmDecl"
                  , "PprCmmExpr"
                  , "Reg"
                  , "RegClass"
                  , "SMRep"
                  , "StgCmmArgRep"
                  , "StgCmmClosure"
                  , "StgCmmEnv"
                  , "StgCmmLayout"
                  , "StgCmmMonad"
                  , "StgCmmProf"
                  , "StgCmmTicky"
                  , "StgCmmUtils"
                  , "StgSyn"
                  , "Stream" ]
