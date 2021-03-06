
module Examples.Test.Lint(main) where

import Development.Shake
import Development.Shake.FilePath
import Examples.Util
import Control.Exception hiding (assert)
import System.Directory as IO


main = shaken test $ \args obj -> do
    want $ map obj args

    addOracle $ \() -> do
        liftIO $ createDirectoryIfMissing True $ obj "dir"
        liftIO $ setCurrentDirectory $ obj "dir"
        return ()

    obj "changedir" *> \out -> do
        () <- askOracle ()
        writeFile' out ""

    obj "pause.*" *> \out -> do
        liftIO $ sleep 0.1
        need [obj "cdir" <.> takeExtension out]
        writeFile' out ""

    obj "cdir.*" *> \out -> do
        pwd <- liftIO getCurrentDirectory
        let dir2 = obj $ "dir" ++ takeExtension out
        liftIO $ createDirectoryIfMissing True dir2
        liftIO $ setCurrentDirectory dir2
        liftIO $ sleep 0.2
        liftIO $ setCurrentDirectory pwd
        writeFile' out ""

    obj "createonce" *> \out -> do
        writeFile' out "X"

    obj "createtwice" *> \out -> do
        need [obj "createonce"]
        liftIO sleepFileTime
        writeFile' (obj "createonce") "Y"
        writeFile' out ""

    obj "listing" *> \out -> do
        writeFile' (out <.> "ls1") ""
        getDirectoryFiles (obj "") ["//*.ls*"]
        writeFile' (out <.> "ls2") ""
        writeFile' out ""

    obj "existance" *> \out -> do
        Development.Shake.doesFileExist $ obj "exists"
        writeFile' (obj "exists") ""
        writeFile' out ""

    obj "gen*" *> \out -> do
        writeFile' out out

    obj "needed1" *> \out -> do
        needed [obj "gen1"]
        writeFile' out ""

    obj "needed2" *> \out -> do
        orderOnly [obj "gen2"]
        needed [obj "gen2"]
        writeFile' out ""

test build obj = do
    dir <- getCurrentDirectory
    let crash args parts = do
            assertException parts (build $ "--quiet" : args)
                `finally` setCurrentDirectory dir

    crash ["changedir"] ["current directory has changed"]
    build ["cdir.1","cdir.2","-j1"]
    build ["--clean","cdir.1","pause.2","-j1"]
    crash ["--clean","cdir.1","pause.2","-j2"] ["before building output/lint/","current directory has changed"]
    crash ["existance"] ["changed since being depended upon"]
    crash ["createtwice"] ["changed since being depended upon"]
    crash ["listing"] ["changed since being depended upon","output/lint"]
    crash ["--clean","listing","existance"] ["changed since being depended upon"]
    crash ["needed1"] ["'needed' file required rebuilding"]
    build ["needed2"]
