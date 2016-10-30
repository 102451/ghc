module Rules.Dependencies (buildPackageDependencies) where

import Development.Shake.Util

import Base
import Context
import Expression
import Oracles.ModuleFiles
import Settings.Path
import Target
import Util

buildPackageDependencies :: [(Resource, Int)] -> Context -> Rules ()
buildPackageDependencies rs context@Context {..} =
    buildPath context -/- ".dependencies" %> \deps -> do
        srcs <- hsSources context
        need srcs
        let mk = deps <.> "mk"
        if srcs == []
        then writeFileChanged mk ""
        else buildWithResources rs $
            Target context (Ghc FindHsDependencies stage) srcs [mk]
        removeFile $ mk <.> "bak"
        mkDeps <- readFile' mk
        writeFileChanged deps . unlines
                              . map (\(src, deps) -> unwords $ src : deps)
                              . map (bimap unifyPath (map unifyPath))
                              . map (bimap head concat . unzip)
                              . groupBy ((==) `on` fst)
                              . sortBy (compare `on` fst)
                              $ parseMakefile mkDeps
