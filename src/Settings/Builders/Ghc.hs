module Settings.Builders.Ghc (ghcArgs, ghcMArgs, commonGhcArgs) where

import Expression
import Oracles
import GHC
import Predicates (package, stagedBuilder, splitObjects, stage0, notStage0)
import Settings

-- TODO: add support for -dyno
-- TODO: consider adding a new builder for programs (e.g. GhcLink?)
-- $1/$2/build/%.$$($3_o-bootsuf) : $1/$4/%.hs-boot
--     $$(call cmd,$1_$2_HC) $$($1_$2_$3_ALL_HC_OPTS) -c $$< -o $$@
--     $$(if $$(findstring YES,$$($1_$2_DYNAMIC_TOO)),-dyno
--     $$(addsuffix .$$(dyn_osuf)-boot,$$(basename $$@)))
ghcArgs :: Args
ghcArgs = stagedBuilder Ghc ? do
    output <- getOutput
    way    <- getWay
    let buildObj = ("//*." ++ osuf way) ?== output || ("//*." ++ obootsuf way) ?== output
    mconcat [ commonGhcArgs
            , arg "-H32m"
            , stage0    ? arg "-O"
            , notStage0 ? arg "-O2"
            , arg "-Wall"
            , arg "-fwarn-tabs"
            , buildObj ? splitObjects ? arg "-split-objs"
            , package ghc ? arg "-no-hs-main"
            , buildObj ? arg "-c"
            , append =<< getInputs
            , arg "-o", arg =<< getOutput ]

ghcMArgs :: Args
ghcMArgs = stagedBuilder GhcM ? do
    ways <- getWays
    mconcat [ arg "-M"
            , commonGhcArgs
            , arg "-include-pkg-deps"
            , arg "-dep-makefile", arg =<< getOutput
            , append $ concat [ ["-dep-suffix", wayPrefix w] | w <- ways ]
            , append =<< getInputs ]

-- This is included into ghcArgs, ghcMArgs and haddockArgs.
commonGhcArgs :: Args
commonGhcArgs = do
    way     <- getWay
    path    <- getTargetPath
    hsArgs  <- getPkgDataList HsArgs
    cppArgs <- getPkgDataList CppArgs
    let buildPath = path -/- "build"
    mconcat [ arg "-hisuf", arg $ hisuf way
            , arg "-osuf" , arg $  osuf way
            , arg "-hcsuf", arg $ hcsuf way
            , wayGhcArgs
            , packageGhcArgs
            , includeGhcArgs
            , append hsArgs
            , append $ map ("-optP" ++) cppArgs
            , arg "-odir"    , arg buildPath
            , arg "-hidir"   , arg buildPath
            , arg "-stubdir" , arg buildPath
            , arg "-rtsopts" ] -- TODO: ifeq "$(HC_VERSION_GE_6_13)" "YES"

-- TODO: do '-ticky' in all debug ways?
wayGhcArgs :: Args
wayGhcArgs = do
    way <- getWay
    mconcat [ if (Dynamic `wayUnit` way)
              then append ["-fPIC", "-dynamic"]
              else arg "-static"
            , (Threaded  `wayUnit` way) ? arg "-optc-DTHREADED_RTS"
            , (Debug     `wayUnit` way) ? arg "-optc-DDEBUG"
            , (Profiling `wayUnit` way) ? arg "-prof"
            , (Logging   `wayUnit` way) ? arg "-eventlog"
            , (Parallel  `wayUnit` way) ? arg "-parallel"
            , (GranSim   `wayUnit` way) ? arg "-gransim"
            , (way == debug || way == debugDynamic) ?
              append ["-ticky", "-DTICKY_TICKY"] ]

packageGhcArgs :: Args
packageGhcArgs = do
    stage              <- getStage
    pkg                <- getPackage
    supportsPackageKey <- getFlag SupportsPackageKey
    pkgKey             <- getPkgData PackageKey
    pkgDepIds          <- getPkgDataList DepIds
    mconcat
        [ arg "-hide-all-packages"
        , arg "-no-user-package-db"
        , stage0 ? arg "-package-db libraries/bootstrapping.conf"
        , isLibrary pkg ?
          if supportsPackageKey || stage /= Stage0
          then arg $ "-this-package-key " ++ pkgKey
          else arg $ "-package-name "     ++ pkgKey
        , append $ map ("-package-id " ++) pkgDepIds ]

includeGhcArgs :: Args
includeGhcArgs = do
    pkg     <- getPackage
    path    <- getTargetPath
    srcDirs <- getPkgDataList SrcDirs
    incDirs <- getPkgDataList IncludeDirs
    let buildPath   = path -/- "build"
        autogenPath = buildPath -/- "autogen"
    mconcat [ arg "-i"
            , arg $ "-i" ++ buildPath
            , arg $ "-i" ++ autogenPath
            , arg $ "-I" ++ buildPath
            , arg $ "-I" ++ autogenPath
            , append [ "-i" ++ pkgPath pkg -/- dir | dir <- srcDirs ]
            , append [ "-I" ++ pkgPath pkg -/- dir | dir <- incDirs ]
            , arg "-optP-include"
            , arg $ "-optP" ++ autogenPath -/- "cabal_macros.h" ]

-- TODO: see ghc.mk
-- # And then we strip it out again before building the package:
-- define libraries/ghc-prim_PACKAGE_MAGIC
-- libraries/ghc-prim_dist-install_MODULES := $$(filter-out GHC.Prim,$$(libraries/ghc-prim_dist-install_MODULES))
-- endef
