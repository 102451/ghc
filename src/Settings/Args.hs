module Settings.Args (getArgs) where

import Data.Monoid

import Expression
import Settings.Builders.Alex
import Settings.Builders.Ar
import Settings.Builders.DeriveConstants
import Settings.Builders.Gcc
import Settings.Builders.GenPrimopCode
import Settings.Builders.Ghc
import Settings.Builders.GhcCabal
import Settings.Builders.GhcPkg
import Settings.Builders.Haddock
import Settings.Builders.Happy
import Settings.Builders.Hsc2Hs
import Settings.Builders.HsCpp
import Settings.Builders.Ld
import Settings.Packages.Compiler
import Settings.User

getArgs :: Expr [String]
getArgs = fromDiffExpr $ defaultBuilderArgs <> defaultPackageArgs <> userArgs

-- TODO: add src-hc-args = -H32m -O
-- TODO: GhcStage2HcOpts=-O2 unless GhcUnregisterised
-- TODO: compiler/stage1/build/Parser_HC_OPTS += -O0 -fno-ignore-interface-pragmas
-- TODO: compiler/main/GhcMake_HC_OPTS        += -auto-all
-- TODO: compiler/prelude/PrimOp_HC_OPTS  += -fforce-recomp
-- TODO: is GhcHcOpts=-Rghc-timing needed?
defaultBuilderArgs :: Args
defaultBuilderArgs = mconcat
    [ alexArgs
    , arArgs
    , cabalArgs
    , customPackageArgs
    , deriveConstantsArgs
    , gccArgs
    , gccMArgs
    , genPrimopCodeArgs
    , ghcArgs
    , ghcCabalHsColourArgs
    , ghcMArgs
    , ghcPkgArgs
    , haddockArgs
    , happyArgs
    , hsc2HsArgs
    , hsCppArgs
    , ldArgs ]

defaultPackageArgs :: Args
defaultPackageArgs = mconcat
    [ compilerArgs ]
