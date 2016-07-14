-- If you want to customise your build you should copy this file from
-- hadrian/src/UserSettings.hs to hadrian/UserSettings.hs and edit your copy.
-- If you don't copy the file your changes will be tracked by git and you can
-- accidentally commit them.
module UserSettings (
    buildRootPath, userFlavours, userKnownPackages, integerLibrary, validating,
    turnWarningsIntoErrors, verboseCommands, putBuild, putSuccess
    ) where

import System.Console.ANSI

import Base
import Flavour
import GHC
import Predicate

-- TODO: Update the docs.
-- See doc/user-settings.md for instructions.

-- | All build results are put into 'buildRootPath' directory.
buildRootPath :: FilePath
buildRootPath = "_build"

-- | User defined build flavours. See 'defaultFlavour' as an example.
userFlavours :: [Flavour]
userFlavours = []

-- | Add user defined packages. Note, this only let's Hadrian know about the
-- existence of a new package; to actually build it you need to create a new
-- build flavour, modifying the list of packages that are built by default.
userKnownPackages :: [Package]
userKnownPackages = []

-- | Choose the integer library: 'integerGmp' or 'integerSimple'.
integerLibrary :: Package
integerLibrary = integerGmp

-- | User defined flags. Note the following type semantics:
-- * @Bool@: a plain Boolean flag whose value is known at compile time.
-- * @Action Bool@: a flag whose value can depend on the build environment.
-- * @Predicate@: a flag whose value can depend on the build environment and
-- on the current build target.

-- TODO: This should be set automatically when validating.
validating :: Bool
validating = False

-- TODO: Replace with stage2 ? arg "-Werror"? Also see #251.
-- | To enable -Werror in Stage2 set turnWarningsIntoErrors = stage2.
turnWarningsIntoErrors :: Predicate
turnWarningsIntoErrors = return False

-- | Set to True to print full command lines during the build process. Note,
-- this is a Predicate, hence you can enable verbose output only for certain
-- targets, e.g.: @verboseCommands = package ghcPrim@.
verboseCommands :: Predicate
verboseCommands = return False

-- | Customise build progress messages (e.g. executing a build command).
putBuild :: String -> Action ()
putBuild = putColoured Dull Magenta

-- | Customise build success messages (e.g. a package is built successfully).
putSuccess :: String -> Action ()
putSuccess = putColoured Dull Green
