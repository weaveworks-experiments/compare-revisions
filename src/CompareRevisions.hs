-- | Entry point for compare-revisions.
module CompareRevisions
  ( startApp
  ) where

import Protolude

import qualified Control.Logging as Log
import Options.Applicative (ParserInfo, execParser, fullDesc, header, helper, info, progDesc)
import Servant (serve)

import qualified CompareRevisions.API as API

import qualified CompareRevisions.Config as Config
import qualified CompareRevisions.Engine as Engine
import qualified CompareRevisions.Server as Server
import qualified CompareRevisions.Server.Logging as Log

-- | Overall command-line configuration.
data Config = Config Config.AppConfig Server.Config Log.LogLevel deriving (Eq, Show)

-- | Command-line parser for compare-revisions.
options :: ParserInfo Config
options = info (helper <*> parser) description
  where
    parser = Config <$> Config.flags <*> Server.flags <*> Log.flags

    description =
      fold
        [ fullDesc
        , progDesc "Show how sets of images differ, by revision"
        , header "compare-revisions - webservice to compare k8s clusters"
        ]

-- | Run the service.
startApp :: IO ()
startApp = do
  Config appConfig serverConfig logLevel <- execParser options
  Log.withLogging logLevel $ do
    result <- runExceptT $ do
      clusterDiffer <- Engine.newClusterDiffer appConfig
      let webServer = API.server (Config.externalURL appConfig) clusterDiffer
      let runWebServer = Server.run serverConfig (serve API.api webServer)
      liftIO $ withAsync runWebServer $ \_ -> runExceptT (Engine.runClusterDiffer clusterDiffer)
    case result of
      Left err -> do
        Log.error' (show err)
        exitWith (ExitFailure 1)
      Right _ -> do
        Log.log' "compare-revisions terminated successfully"
        exitSuccess
