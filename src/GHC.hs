module GHC (
    array, base, binPackageDb, binary, bytestring, cabal, compiler, containers,
    deepseq, directory, filepath, ghc, ghcCabal, ghcPkg, ghcPrim, ghcPwd,
    haskeline, hoopl, hpc, integerGmp, integerSimple, parallel, pretty,
    primitive, process, stm, templateHaskell, terminfo, time, transformers,
    unix, win32, xhtml,

    defaultKnownPackages, defaultTargetDirectory, defaultProgramPath
    ) where

import Base
import Package
import Stage

-- These are all GHC packages we know about. Build rules will be generated for
-- all of them. However, not all of these packages will be built. For example,
-- package 'win32' is built only on Windows.
-- Settings/Packages.hs defines default conditions for building each package,
-- which can be overridden in Settings/User.hs.
defaultKnownPackages :: [Package]
defaultKnownPackages =
    [ array, base, binPackageDb, binary, bytestring, cabal, compiler
    , containers, deepseq, directory, filepath, ghc, ghcCabal, ghcPkg, ghcPrim
    , ghcPwd, haskeline, hoopl, hpc, integerGmp, integerSimple, parallel, pretty
    , primitive, process, stm, templateHaskell, terminfo, time, transformers
    , unix, win32, xhtml ]

-- Package definitions
array, base, binPackageDb, binary, bytestring, cabal, compiler, containers,
    deepseq, directory, filepath, ghc, ghcCabal, ghcPkg, ghcPrim, ghcPwd,
    haskeline, hoopl, hpc, integerGmp, integerSimple, parallel, pretty,
    primitive, process, stm, templateHaskell, terminfo, time, transformers,
    unix, win32, xhtml :: Package

array           = library  "array"
base            = library  "base"
binPackageDb    = library  "bin-package-db"
binary          = library  "binary"
bytestring      = library  "bytestring"
cabal           = library  "Cabal"          `setPath` "libraries/Cabal/Cabal"
compiler        = topLevel "ghc"            `setPath` "compiler"
containers      = library  "containers"
deepseq         = library  "deepseq"
directory       = library  "directory"
filepath        = library  "filepath"
ghc             = topLevel "ghc-bin"        `setPath` "ghc"
ghcCabal        = utility  "ghc-cabal"
ghcPkg          = utility  "ghc-pkg"
ghcPrim         = library  "ghc-prim"
ghcPwd          = utility  "ghc-pwd"
haskeline       = library  "haskeline"
hoopl           = library  "hoopl"
hpc             = library  "hpc"
integerGmp      = library  "integer-gmp"
integerSimple   = library  "integer-simple"
parallel        = library  "parallel"
pretty          = library  "pretty"
primitive       = library  "primitive"
process         = library  "process"
stm             = library  "stm"
templateHaskell = library  "template-haskell"
terminfo        = library  "terminfo"
time            = library  "time"
transformers    = library  "transformers"
unix            = library  "unix"
win32           = library  "Win32"
xhtml           = library  "xhtml"


-- GHC build results will be placed into target directories with the following
-- typical structure:
-- * build/          : contains compiled object code
-- * doc/            : produced by haddock
-- * package-data.mk : contains output of ghc-cabal applied to pkgCabal
-- TODO: simplify to just 'show stage'?
-- TODO: we divert from the previous convention for ghc-cabal and ghc-pkg,
-- which used to store stage0 build results in 'dist' folder
defaultTargetDirectory :: Stage -> Package -> FilePath
defaultTargetDirectory stage pkg
    | pkg   == compiler = "stage" ++ show (fromEnum stage + 1)
    | pkg   == ghc      = "stage" ++ show (fromEnum stage + 1)
    | stage == Stage0   = "dist-boot"
    | otherwise         = "dist-install"

defaultProgramPath :: Stage -> Package -> Maybe FilePath
defaultProgramPath stage pkg
    | pkg == ghc      = program $ "ghc-stage" ++ show (fromEnum stage + 1)
    | pkg == ghcCabal = program $ pkgName pkg
    | pkg == ghcPkg   = program $ pkgName pkg
    | pkg == ghcPwd   = program $ pkgName pkg
    | otherwise       = Nothing
  where
    program name = Just $ pkgPath pkg -/- defaultTargetDirectory stage pkg
                                      -/- "build/tmp" -/- name <.> exe
