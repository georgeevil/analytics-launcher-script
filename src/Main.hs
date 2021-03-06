#!/usr/bin/env stack
-- stack --install-ghc runghc --package turtle
{-# LANGUAGE LambdaCase, DeriveGeneric, GeneralizedNewtypeDeriving, NamedFieldPuns, OverloadedStrings, RecordWildCards #-}

import Prelude hiding (mapM_, unwords)
import Turtle as T hiding (find, stripPrefix)
import qualified Data.ByteString.Lazy as B
import qualified Network.Wreq as N
import qualified System.Process as S

import Control.Concurrent (isEmptyMVar, forkIO, tryPutMVar)
import Control.Concurrent.MVar (MVar, newEmptyMVar)
import Control.Exception (catch, throw, SomeException)
import Control.Monad (void)
import Control.Monad.Parallel (mapM_)
import Control.Retry (constantDelay, limitRetries, recoverAll)
import Data.Aeson
import Data.List (find, partition)
import Data.Maybe (fromMaybe)
import Data.Text (isPrefixOf, pack, unpack, unwords, isPrefixOf, stripPrefix, unwords)
import Data.Tuple.All (sel4)
import Debug.Trace (trace)
import Filesystem.Path.CurrentOS (encodeString)
import GHC.Generics
import System.Process (createProcess, waitForProcess)
import System.Process.Internals (ProcessHandle, ProcessHandle__(..), PHANDLE, withProcessHandle)
import System.Posix.Signals (Handler(..), installHandler, sigINT, sigTERM)

main :: IO ()
main = do
  args <- T.options "Script to start up SaaS-like analytics cluster." optionsParser
  currDir <- pwd
  configs <- makeNodeConfigs currDir (planPath args)
  print configs
  homeDir <- getPropOrDie "ANALYTICS_HOME" "Set it to be something like /Users/firstname.lastname/appdynamics/analytics-codebase/analytics"
  cd homeDir
  shellsNoArgs "./gradlew --build-cache -p analytics-processor clean distZip"
  cd "analytics-processor/build/distributions"
  baseDir <- pwd
  -- unzip all nodes and join
  sh $ parallel $ map (shellNoArgs . mkUnzipCmd) configs
  -- run all the nodes
  _ <- startAllNodes (not (doNotKillAll args)) baseDir configs
  -- should not hit this until you ctrl+c and all nodes stop
  putStrLn "End of the script!"

makeNodeConfigs :: T.FilePath -> T.FilePath -> IO NodeConfigs
makeNodeConfigs basePath relativePath = do
  planInBytes <- B.readFile (encodeString $ basePath <> relativePath)
  case eitherDecode planInBytes of
    Left readErr  -> die $ fromString $ "Could not read input file into plan object: " <> readErr
    Right val     -> return val

optionsParser :: T.Parser ProgramArgs
optionsParser = ProgramArgs
  <$> optPath "plan" 'p' "Location of json file that defines which nodes are started."
  <*> switch "no-kill-all" 'n' "Set to turn off default behavior of killing all nodes if one dies."

data ProgramArgs = ProgramArgs 
  { planPath      :: T.FilePath
  , doNotKillAll  :: Bool
  }

mkUnzipCmd :: NodeConfig -> Text
mkUnzipCmd conf = "unzip analytics-processor.zip -d " <> mkDirName conf

mkDirName :: NodeConfig -> Text
mkDirName NodeConfig{nodeName, dirName, ..} = fromMaybe nodeName dirName

startAllNodes :: Bool -> T.FilePath -> NodeConfigs -> IO ()
startAllNodes shouldKillAll baseDir config = do
  hasCleanupStarted <- newEmptyMVar
  let (esNodes, otherNodes) = partition isStoreConfig config
  esNodeHandles <- startNodes baseDir esNodes
  -- wait for ES
  esPort <- getElasticsearchPort config
  tryWaitForElasticsearch esNodeHandles esPort
  putStrLn "Elasticsearch is up now!"
  -- bring up others
  nonEsNodeHandles <- startNodes baseDir otherNodes
  -- install handlers and wait for all
  let allHandles = esNodeHandles ++ nonEsNodeHandles
  _ <- installHandler sigINT (killHandles hasCleanupStarted allHandles) Nothing
  _ <- installHandler sigTERM (killHandles hasCleanupStarted allHandles) Nothing
  mapM_ (waitOrCleanupAll shouldKillAll hasCleanupStarted allHandles) allHandles
  return ()

waitOrCleanupAll :: Bool -> MVar () -> [ProcessHandle] -> ProcessHandle -> IO ()
waitOrCleanupAll shouldKillAll cleanupMVar allHandles thisHandle = getPid thisHandle >>= \case
  Nothing   -> when shouldKillAll $ tryKillAll cleanupMVar allHandles
  Just pid  -> do
    exitCode <- waitForProcess thisHandle
    firstTimeCleanup <- isEmptyMVar cleanupMVar
    case exitCode of
      ExitSuccess -> return ()
      ExitFailure code ->
        when (firstTimeCleanup && shouldKillAll) $ trace
          ("Killing all handles since " <> show pid <> " stopped with " <> show code)
          (tryKillAll cleanupMVar allHandles)

isStoreConfig :: NodeConfig -> Bool
isStoreConfig config = 
  let name = nodeName config
  in  "store" `isPrefixOf` name || "api-store" `isPrefixOf` name

getElasticsearchPort :: NodeConfigs -> IO Text
getElasticsearchPort configs = case getOptElasticsearchPort configs of
    Nothing -> die "ad.es.node.http.port wasn't set in elasticsearch property overrides"
    Just a  -> return a

getOptElasticsearchPort :: NodeConfigs -> Maybe Text
getOptElasticsearchPort configs =
  let portPrefix = "ad.es.node.http.port=" :: Text
      isPortProp p = portPrefix `isPrefixOf` p
      esProps = propertyOverrides (head configs)
  in  find isPortProp esProps >>= stripPrefix portPrefix

tryWaitForElasticsearch :: [ProcessHandle] -> Text -> IO ()
tryWaitForElasticsearch handles esPort = catch (waitForElasticsearch esPort) (handleError handles)

handleError :: [ProcessHandle] -> SomeException -> IO ()
handleError handles someE = kill9All handles >>= throw someE

waitForElasticsearch :: Text -> IO ()
waitForElasticsearch esPort = recoverAll (constantDelay 1000000 <> limitRetries 60) go where
  go _ = trace "Waiting for Elasticsearch to start up..." $
          void $ N.get ("http://localhost:" <> unpack esPort)

-- startNodes :: T.FilePath -> NodeConfigs -> IO [ProcessHandle]
-- startNodes baseDir = traverse $ 
--   editVmOptionsFile baseDir >> shellReturnHandle . configToStartCmd baseDir

startNodes :: T.FilePath -> NodeConfigs -> IO [ProcessHandle]
startNodes baseDir configs = do
  _ <- traverse (editVmOptionsFile baseDir) configs
  traverse (shellReturnHandle . configToStartCmd baseDir) configs

editVmOptionsFile :: T.FilePath -> NodeConfig -> IO ()
editVmOptionsFile baseDir nodeConfig = performIfExists modifyFile (debugOption nodeConfig) 
    where
  modifyFile :: DebugOption -> IO ()
  modifyFile (DebugOption opt) = append file "" >> append file (fromString $ unpack opt)
  file = getVmOptionsFile baseDir nodeConfig

getVmOptionsFile :: T.FilePath -> NodeConfig -> T.FilePath
getVmOptionsFile baseDir nodeConfig =
  if isStoreConfig nodeConfig
    then fromText $ vmOptionsFileFormat "analytics-sidecar"
    else fromText $ vmOptionsFileFormat "analytics-processor"
  where
    vmOptionsFileFormat = format (fp % "/" %s % "/analytics-processor/conf/" %s % ".vmoptions") baseDir (mkDirName nodeConfig)

killHandles :: MVar () -> [ProcessHandle] -> Handler
killHandles hasCleanupStarted handles = Catch $ tryKillAll hasCleanupStarted handles

tryKillAll :: MVar () -> [ProcessHandle] -> IO ()
tryKillAll cleanupMvar handles = do
  cleanupHadNotStarted <- tryPutMVar cleanupMvar ()
  when cleanupHadNotStarted (kill9All handles)

kill9All :: [ProcessHandle] -> IO ()
kill9All phs = void $ traverse kill9 phs

kill9 :: ProcessHandle -> IO ()
kill9 ph = void $ forkIO $ do
  _ <- getPid ph >>= performIfExists (killCmdTemplate softKillMsg "kill ")
  sleep 5.0
  _ <- getPid ph >>= performIfExists (killCmdTemplate hardKillMsg "kill -9 ")
  return ()
    where
  killCmdTemplate msg baseCmd pid = trace (msg pid) $ shellsNoArgs (baseCmd <> showT pid)
  softKillMsg showable = "Soft killing process with id: [" <> show showable <> "], will hard kill in 5 seconds if it's still alive"
  hardKillMsg showable = "Hard killing process with id: [" <> show showable <> "]"

performIfExists :: Monad m => (a -> m ()) -> Maybe a -> m () 
performIfExists _ Nothing   = return ()
performIfExists f (Just a)  = f a

configToStartCmd :: T.FilePath -> NodeConfig -> Text
configToStartCmd baseDir nodeConfig = trace (show traceLine) finalCmd where
  apDir = format (fp%"/"%s%"/analytics-processor") baseDir (mkDirName nodeConfig)
  shFile = format (s%"/bin/analytics-processor.sh") apDir
  propFile = format (s%"/conf/analytics-"%s%".properties") apDir (nodeName nodeConfig)
  logPathProp = format ("-D ad.dw.log.path="%s%"/logs") apDir
  extraProps = format (s%" "%s) logPathProp $ getPropertyOverrideString nodeConfig
  finalCmd = format ("sh "%s%" start -p "%s%" "%s) shFile propFile extraProps
  traceLine = format ("Starting ["%s%"] with command:      "%s) (nodeName nodeConfig) finalCmd

getPropertyOverrideString :: NodeConfig -> Text
getPropertyOverrideString nodeConfig = unwords $ map (\prop -> "-D " <> prop) (propertyOverrides nodeConfig)

getPid :: ProcessHandle -> IO (Maybe PHANDLE)
getPid ph = withProcessHandle ph $ return <$> phToJust

phToJust :: ProcessHandle__ -> Maybe PHANDLE
phToJust (OpenHandle phandle) = Just phandle
phToJust _                    = Nothing

-- More general util methods

shellNoArgs :: Text -> IO ExitCode
shellNoArgs cmd = T.shell cmd empty

shellsNoArgs :: Text -> IO ()
shellsNoArgs cmd = shells cmd empty

getPropOrDie :: Text -> Text -> IO T.FilePath
getPropOrDie prop message = need prop >>= \case
  Nothing -> die (prop <> " was not set. " <> message)
  Just a  -> return $ fromText a

showT :: Show a => a -> Text
showT = (pack . show)

shellReturnHandle :: Text -> IO ProcessHandle
shellReturnHandle cmd = createProcess (S.shell (unpack cmd)) >>= return <$> sel4

type NodeConfigs = [NodeConfig]
data NodeConfig = NodeConfig 
  { nodeName :: Text
  , propertyOverrides :: [Text]
  , debugOption :: Maybe DebugOption
  , dirName :: Maybe Text
  } deriving (Generic, Show)

instance ToJSON NodeConfig
instance FromJSON NodeConfig

newtype DebugOption = DebugOption Text
  deriving (Generic, Show, ToJSON, FromJSON)