{-# LANGUAGE CPP #-}
{-# LANGUAGE RecordWildCards #-}

module Network.Wai.Handler.Warp.FileInfoCache (
    FileInfo (..),
    withFileInfoCache,
    getInfo, -- test purpose only
) where

import Control.Exception (bracket, onException, throwIO)
import Control.Reaper
import Network.HTTP.Date
#if WINDOWS
import System.PosixCompat.Files
#else
import System.Posix.Files
#endif

import Network.Wai.Handler.Warp.HashMap (HashMap)
import qualified Network.Wai.Handler.Warp.HashMap as M
import Network.Wai.Handler.Warp.Imports

----------------------------------------------------------------

-- | File information.
data FileInfo = FileInfo
    { fileInfoName :: !FilePath
    , fileInfoSize :: !Integer
    , fileInfoTime :: HTTPDate
    -- ^ Modification time
    , fileInfoDate :: ByteString
    -- ^ Modification time in the GMT format
    }
    deriving (Eq, Show)

data Entry = Negative | Positive FileInfo
type Cache = HashMap Entry
type FileInfoCache = Reaper Cache (FilePath, Entry)

----------------------------------------------------------------

-- | Getting the file information corresponding to the file.
getInfo :: FilePath -> IO FileInfo
getInfo path = do
    fs <- getFileStatus path -- file access
    let regular = not (isDirectory fs)
        readable = fileMode fs `intersectFileModes` ownerReadMode /= 0
    if regular && readable
        then do
            let time = epochTimeToHTTPDate $ modificationTime fs
                date = formatHTTPDate time
                size = fromIntegral $ fileSize fs
                info =
                    FileInfo
                        { fileInfoName = path
                        , fileInfoSize = size
                        , fileInfoTime = time
                        , fileInfoDate = date
                        }
            return info
        else throwIO (userError "FileInfoCache:getInfo")

getInfoNaive :: FilePath -> IO FileInfo
getInfoNaive = getInfo

----------------------------------------------------------------

getAndRegisterInfo :: FileInfoCache -> FilePath -> IO FileInfo
getAndRegisterInfo reaper path = do
    cache <- reaperRead reaper
    case M.lookup path cache of
        Just Negative -> throwIO (userError "FileInfoCache:getAndRegisterInfo")
        Just (Positive x) -> return x
        Nothing ->
            positive reaper path
                `onException` negative reaper path

positive :: FileInfoCache -> FilePath -> IO FileInfo
positive reaper path = do
    info <- getInfo path
    reaperAdd reaper (path, Positive info)
    return info

negative :: FileInfoCache -> FilePath -> IO FileInfo
negative reaper path = do
    reaperAdd reaper (path, Negative)
    throwIO (userError "FileInfoCache:negative")

----------------------------------------------------------------

-- | Creating a file information cache
--   and executing the action in the second argument.
--   The first argument is a cache duration in microseconds.
withFileInfoCache
    :: Int
    -> ((FilePath -> IO FileInfo) -> IO a)
    -> IO a
withFileInfoCache 0 action = action getInfoNaive
withFileInfoCache duration action =
    bracket
        (initialize duration)
        terminate
        (action . getAndRegisterInfo)

initialize :: Int -> IO FileInfoCache
initialize duration = mkReaper settings
  where
    settings =
        defaultReaperSettings
            { reaperAction = override
            , reaperDelay = duration
            , reaperCons = \(path, v) -> M.insert path v
            , reaperNull = M.isEmpty
            , reaperEmpty = M.empty
            , reaperThreadName = "File info cacher (Reaper)"
            }

override :: Cache -> IO (Cache -> Cache)
override _ = return $ const M.empty

terminate :: FileInfoCache -> IO ()
terminate x = void $ reaperStop x
