{-# LANGUAGE ScopedTypeVariables, PatternGuards, NamedFieldPuns, FlexibleInstances, MultiParamTypeClasses #-}
{-
This module stores the meta-data so its very important its always accurate
We can't rely on getting any exceptions or termination at the end, so we'd better write out a journal
We store a series of records, and if they contain twice as many records as needed, we compress
-}

module Development.Shake.Storage(
    withStorage
    ) where

import General.Binary
import General.Base
import Development.Shake.Types
import General.Timing

import Control.Arrow
import Control.Exception as E
import Control.Monad
import Control.Concurrent
import Data.Binary.Get
import Data.Binary.Put
import Data.Time
import Data.Char
import Development.Shake.Classes
import qualified Data.HashMap.Strict as Map
import Data.List
import Numeric
import System.Directory
import System.Exit
import System.FilePath
import System.IO

import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Data.ByteString.Lazy as LBS8


type Map = Map.HashMap

-- Increment every time the on-disk format/semantics change,
-- @x@ is for the users version number
databaseVersion :: String -> String
-- THINGS I WANT TO DO ON THE NEXT CHANGE
-- * Change FileTime to be a Word32, not an Int32, with maxBound for fileNone
-- * Change filepaths to store a 1 byte prefix saying 8bit ASCII or UTF8
databaseVersion x = "SHAKE-DATABASE-8-" ++ s ++ "\r\n"
    where s = tail $ init $ show x -- call show, then take off the leading/trailing quotes
                                   -- ensures we do not get \r or \n in the user portion


withStorage
    :: (Show w, Show k, Show v, Eq w, Eq k, Hashable k
       ,Binary w, BinaryWith w k, BinaryWith w v)
    => ShakeOptions             -- ^ Storage options
    -> (String -> IO ())        -- ^ Logging function
    -> w                        -- ^ Witness
    -> (Map k v -> (k -> v -> IO ()) -> IO a)  -- ^ Execute
    -> IO a
withStorage ShakeOptions{shakeVerbosity,shakeOutput,shakeVersion,shakeFlush,shakeFiles,shakeStorageLog} diagnostic witness act = do
    let dbfile = shakeFiles <.> "database"
        bupfile = shakeFiles <.> "bup"
    createDirectoryIfMissing True $ takeDirectory shakeFiles

    -- complete a partially failed compress
    b <- doesFileExist bupfile
    when b $ do
        unexpected "Backup file exists, restoring over the previous file\n"
        diagnostic $ "Backup file move to original"
        E.catch (removeFile dbfile) (\(e :: SomeException) -> return ())
        renameFile bupfile dbfile

    addTiming "Database read"
    withBinaryFile dbfile ReadWriteMode $ \h -> do
        n <- hFileSize h
        diagnostic $ "Reading file of size " ++ show n
        src <- LBS.hGet h $ fromInteger n

        if not $ ver `LBS.isPrefixOf` src then do
            unless (LBS.null src) $ do
                let limit x = let (a,b) = splitAt 200 x in a ++ (if null b then "" else "...")
                let disp = map (\x -> if isPrint x && isAscii x then x else '?') . takeWhile (`notElem` "\r\n")
                outputErr $ unlines
                    ["Error when reading Shake database - invalid version stamp detected:"
                    ,"  File:      " ++ dbfile
                    ,"  Expected:  " ++ disp (LBS.unpack ver)
                    ,"  Found:     " ++ disp (limit $ LBS.unpack src)
                    ,"All rules will be rebuilt"]
            continue h Map.empty
         else
            -- make sure you are not handling exceptions from inside
            join $ handleJust (\e -> if asyncException e then Nothing else Just e) (\err -> do
                msg <- showException err
                outputErr $ unlines $
                    ("Error when reading Shake database " ++ dbfile) :
                    map ("  "++) (lines msg) ++
                    ["All files will be rebuilt"]
                when shakeStorageLog $ do
                    hSeek h AbsoluteSeek 0
                    i <- hFileSize h
                    bs <- LBS.hGet h $ fromInteger i
                    let cor = shakeFiles <.> "corrupt"
                    LBS.writeFile cor bs
                    unexpected $ "Backup of corrupted file stored at " ++ cor ++ ", " ++ show i ++ " bytes\n"
                    
                -- exitFailure -- should never happen without external corruption
                               -- add back to check during random testing
                return $ continue h Map.empty) $
                case readChunks $ LBS.drop (LBS.length ver) src of
                    ([], slop) -> do
                        when (LBS.length slop > 0) $ unexpected $ "Last " ++ show slop ++ " bytes do not form a whole record\n"
                        diagnostic $ "Read 0 chunks, plus " ++ show slop ++ " slop"
                        return $ continue h Map.empty
                    (w:xs, slopRaw) -> do
                        let slop = fromIntegral $ LBS.length slopRaw
                        when (slop > 0) $ unexpected $ "Last " ++ show slop ++ " bytes do not form a whole record\n"
                        diagnostic $ "Read " ++ show (length xs + 1) ++ " chunks, plus " ++ show slop ++ " slop"
                        let ws = decode w
                            f mp (k, v) = Map.insert k v mp
                            ents = map (runGet $ getWith ws) xs
                            mp = foldl' f Map.empty ents

                        when (shakeVerbosity == Diagnostic) $ do
                            let raw x = "[len " ++ show (LBS.length x) ++ "] " ++ concat
                                        [['0' | length c == 1] ++ c | x <- LBS8.unpack x, let c = showHex x ""]
                            let pretty (Left x) = "FAILURE: " ++ show (x :: SomeException)
                                pretty (Right x) = x
                            diagnostic $ "Witnesses " ++ raw w
                            forM_ (zip3 [1..] xs ents) $ \(i,x,ent) -> do
                                x2 <- try $ evaluate $ let s = show ent in rnf s `seq` s
                                diagnostic $ "Chunk " ++ show i ++ " " ++ raw x ++ " " ++ pretty x2
                            diagnostic $ "Slop " ++ raw slopRaw

                        diagnostic $ "Found " ++ show (Map.size mp) ++ " real entries"

                        -- if mp is null, continue will reset it, so no need to clean up
                        if Map.null mp || (ws == witness && Map.size mp * 2 > length xs - 2) then do
                            -- make sure we reset to before the slop
                            when (not (Map.null mp) && slop /= 0) $ do
                                diagnostic $ "Dropping last " ++ show slop ++ " bytes of database (incomplete)"
                                now <- hFileSize h
                                hSetFileSize h $ now - slop
                                hSeek h AbsoluteSeek $ now - slop
                                hFlush h
                                diagnostic $ "Drop complete"
                            return $ continue h mp
                         else do
                            addTiming "Database compression"
                            unexpected "Compressing database\n"
                            diagnostic "Compressing database"
                            hClose h -- two hClose are fine
                            return $ do
                                renameFile dbfile bupfile
                                withBinaryFile dbfile ReadWriteMode $ \h -> do
                                    reset h mp
                                    removeFile bupfile
                                    diagnostic "Compression complete"
                                    continue h mp
    where
        unexpected x = when shakeStorageLog $ do
            t <- getCurrentTime
            appendFile (shakeFiles <.> "storage") $ "\n[" ++ show t ++ "]: " ++ x
        outputErr x = do
            when (shakeVerbosity >= Quiet) $ shakeOutput Quiet x
            unexpected x

        ver = LBS.pack $ databaseVersion shakeVersion

        writeChunk h s = do
            diagnostic $ "Writing chunk " ++ show (LBS.length s)
            LBS.hPut h $ toChunk s

        reset h mp = do
            diagnostic $ "Resetting database to " ++ show (Map.size mp) ++ " elements"
            hSetFileSize h 0
            hSeek h AbsoluteSeek 0
            LBS.hPut h ver
            writeChunk h $ encode witness
            mapM_ (writeChunk h . runPut . putWith witness) $ Map.toList mp
            hFlush h
            diagnostic "Flush"

        -- continuation (since if we do a compress, h changes)
        continue h mp = do
            when (Map.null mp) $
                reset h mp -- might as well, no data to lose, and need to ensure a good witness table
                           -- also lets us recover in the case of corruption
            flushThread shakeFlush h $ \out -> do
                addTiming "With database"
                act mp $ \k v -> out $ toChunk $ runPut $ putWith witness (k, v)


-- We avoid calling flush too often on SSD drives, as that can be slow
-- Make sure all exceptions happen on the caller, so we don't have to move exceptions back
-- Make sure we only write on one thread, otherwise async exceptions can cause partial writes
flushThread :: Maybe Double -> Handle -> ((LBS.ByteString -> IO ()) -> IO a) -> IO a
flushThread flush h act = do
    chan <- newChan -- operations to perform on the file
    kick <- newEmptyMVar -- kicked whenever something is written
    died <- newBarrier -- has the writing thread finished

    flusher <- case flush of
        Nothing -> return Nothing
        Just flush -> fmap Just $ forkIO $ forever $ do
            takeMVar kick
            threadDelay $ ceiling $ flush * 1000000
            tryTakeMVar kick
            writeChan chan $ hFlush h >> return True

    root <- myThreadId
    writer <- forkIO $ handle (\(e :: SomeException) -> signalBarrier died () >> throwTo root e) $
        -- only one thread ever writes, ensuring only the final write can be torn
        whileM $ join $ readChan chan

    (act $ \s -> do
            evaluate $ LBS.length s -- ensure exceptions occur on this thread
            writeChan chan $ LBS.hPut h s >> tryPutMVar kick () >> return True)
        `finally` do
            maybe (return ()) killThread flusher
            writeChan chan $ signalBarrier died () >> return False
            waitBarrier died


-- Return the amount of junk at the end, along with all the chunk
readChunks :: LBS.ByteString -> ([LBS.ByteString], LBS.ByteString)
readChunks x
    | Just (n, x) <- grab 4 x
    , Just (y, x) <- grab (fromIntegral (decode n :: Word32)) x
    = first (y :) $ readChunks x
    | otherwise = ([], x)
    where
        grab i x | LBS.length a == i = Just (a, b)
                 | otherwise = Nothing
            where (a,b) = LBS.splitAt i x


toChunk :: LBS.ByteString -> LBS.ByteString
toChunk x = n `LBS.append` x
    where n = encode (fromIntegral $ LBS.length x :: Word32)


-- Some exceptions may have an error message which is itself an exception,
-- make sure you show them properly
showException :: SomeException -> IO String
showException err = do
    let msg = show err
    E.catch (evaluate $ rnf msg `seq` msg) (\(_ :: SomeException) -> return "Unknown exception (error while showing error message)")


-- | Is the exception asyncronous, not a "coding error" that should be ignored
asyncException :: SomeException -> Bool
asyncException e
    | Just (_ :: AsyncException) <- fromException e = True
    | Just (_ :: ExitCode) <- fromException e = True
    | otherwise = False
