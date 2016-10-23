module Rules.Documentation (buildPackageDocumentation) where

import Base
import Context
import Expression
import Flavour
import GHC
import Oracles.ModuleFiles
import Oracles.PackageData
import Rules.Actions
import Settings
import Settings.Paths
import Target

haddockHtmlLib :: FilePath
haddockHtmlLib = "inplace/lib/html/haddock-util.js"

-- Note: this build rule creates plenty of files, not just the .haddock one.
-- All of them go into the 'doc' subdirectory. Pedantically tracking all built
-- files in the Shake database seems fragile and unnecessary.
buildPackageDocumentation :: Context -> Rules ()
buildPackageDocumentation context@Context {..} =
    let cabalFile   = pkgCabalFile package
        haddockFile = pkgHaddockFile context
    in when (stage == Stage1) $ do
        haddockFile %> \file -> do
            srcs <- hsSources context
            deps <- map PackageName <$> interpretInContext context (getPkgDataList DepNames)
            let haddocks = [ pkgHaddockFile $ vanillaContext Stage1 depPkg
                           | Just depPkg <- map findKnownPackage deps
                           , depPkg /= rts ]
            need $ srcs ++ haddocks ++ [haddockHtmlLib]

            -- HsColour sources
            -- TODO: what is the output of GhcCabalHsColour?
            whenM (specified HsColour) $ do
                pkgConf <- pkgConfFile context
                need [ cabalFile, pkgConf ] -- TODO: check if need pkgConf
                build $ Target context GhcCabalHsColour [cabalFile] []

            -- Build Haddock documentation
            -- TODO: pass the correct way from Rules via Context
            let haddockWay = if dynamicGhcPrograms flavour then dynamic else vanilla
            build $ Target (context {way = haddockWay}) Haddock srcs [file]

        when (package == haddock) $ haddockHtmlLib %> \_ -> do
            let dir = takeDirectory haddockHtmlLib
            liftIO $ removeFiles dir ["//*"]
            copyDirectory "utils/haddock/haddock-api/resources/html" dir

-- # Make the haddocking depend on the library .a file, to ensure
-- # that we wait until the library is fully built before we haddock it
-- $$($$($1_PACKAGE)-$$($1_$2_VERSION)_HADDOCK_FILE) : $$($1_$2_$$(HADDOCK_WAY)_LIB)
-- endif
