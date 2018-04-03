{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TypeOperators #-}

-- | API definition for compare-revisions.
module CompareRevisions.API
  ( API
  , api
  , server
  ) where

import Protolude hiding (diff)

import Data.Aeson (ToJSON(..))
import qualified Data.Map as Map
import qualified Data.Text as Text
import qualified Data.Time as Time
import qualified Lucid as L
import Network.URI (URI(..), parseRelativeReference, relativeTo, uriToString)
import Servant (Server, Handler)
import Servant.API (Capture, Get, JSON, QueryParam, (:<|>)(..), (:>))
import Servant.HTML.Lucid (HTML)
import Servant.Server (ServantErr(..), err404, err500)

import qualified CompareRevisions.Config as Config
import qualified CompareRevisions.Engine as Engine
import qualified CompareRevisions.Git as Git
import qualified CompareRevisions.Kube as Kube

-- | compare-revisions API definition.
type API
  = "images" :> Get '[HTML, JSON] ImageDiffs
  :<|> "revisions" :> Get '[HTML] RevisionDiffs
  :<|> Capture "environment" Config.EnvironmentName :> "changes" :> QueryParam "start" Time.Day :> Get '[HTML] ChangeLog
  :<|> Get '[HTML] RootPage

-- TODO: Also want to show:
--  - current config
--  - when config last updated
--  - browsing config repo?

-- | Value-level representation of API.
api :: Proxy API
api = Proxy

-- | API implementation.
server :: URI -> Engine.ClusterDiffer -> Server API
server externalURL clusterDiffer
  = images clusterDiffer
  :<|> revisions clusterDiffer
  :<|> changes clusterDiffer
  :<|> rootPage externalURL clusterDiffer

rootPage :: HasCallStack => URI -> Engine.ClusterDiffer -> Handler RootPage
rootPage externalURL differ = do
  envs <- findEnvironments <$> Engine.getConfig differ
  pure (RootPage externalURL envs)

-- | Show how images differ between two environments.
images :: HasCallStack => Engine.ClusterDiffer -> Handler ImageDiffs
images = map (ImageDiffs . map Engine.imageDiffs) . Engine.getCurrentDifferences

-- | Show the revisions that are in one environment but not others.
revisions :: Engine.ClusterDiffer -> Handler RevisionDiffs
revisions differ = do
  diff <- Engine.getCurrentDifferences differ
  pure . RevisionDiffs $ Engine.revisionDiffs <$> diff

-- | Show recent changes to a particular cluster.
--
-- Probably want this to take the following parameters:
--   - the cluster to look at
--   - the start date for changes (and default to something like 2 weeks ago)
--   - the end date for changes (defaulting to 'now')
--
-- Initial version should not take end date (YAGNI).
--
-- Then use that to:
--   - find the configuration for the cluster
--   - check out a version for the start date
--   - (check out a version for the end date)
--   - Use Kube.getDifferingImages to find the images that differ
--   - Use Engine.compareRevisions to find the git revisions
--   - Organize this information reverse chronologically,
--     probably not even grouped be images.
changes :: Engine.ClusterDiffer -> Config.EnvironmentName -> Maybe Time.Day -> Handler ChangeLog
changes differ env start' = do
  envs <- findEnvironments <$> Engine.getConfig differ
  envPath <- case Map.lookup env envs of
    Nothing -> throwError $ err404 { errBody = "No such environment: " <> toS env }
    Just envPath -> pure envPath
  start <- case start' of
    Nothing -> do
      now <- liftIO Time.getCurrentTime
      let today = Time.utctDay now
      -- TODO: Would like to pick the last Sunday that gives us two whole weeks.
      pure (Time.addDays (-14) today)
    Just start'' -> pure start''
  changelog' <- liftIO . runExceptT $ Engine.loadChanges differ envPath start
  case changelog' of
    Left err -> throwError $ err500 { errBody = "Could not load config repo: " <> show err }
    Right changelog -> pure (ChangeLog env start changelog)


-- | Find all of the environments in our configuration.
findEnvironments :: Config.ValidConfig -> Map Config.EnvironmentName FilePath
findEnvironments cfg = Map.fromList [(Config.name env, Config.path env) | env <- envs]
  where
    envs = [Config.sourceEnv repo, Config.targetEnv repo]
    repo = Config.configRepo cfg


-- | Wrap an HTML "page" with all of our standard boilerplate.
standardPage :: Monad m => Text -> L.HtmlT m () -> L.HtmlT m ()
standardPage title content =
  L.doctypehtml_ $ do
    L.head_ (L.title_ (L.toHtml title))
    L.body_ $ do
      L.h1_ (L.toHtml title)
      content
      L.p_ $ do
        "Source code at "
        L.a_ [L.href_ sourceURL] (L.toHtml sourceURL)
  where
    sourceURL = "https://github.com/weaveworks-experiments/compare-revisions"

-- | Represents the root page of the service.
data RootPage = RootPage URI (Map Config.EnvironmentName FilePath) deriving (Eq, Ord, Show)

-- | Very simple root HTML page.
instance L.ToHtml RootPage where
  toHtmlRaw = L.toHtml
  toHtml (RootPage externalURL envs) =
    standardPage "compare-revisions" $ do
      L.h2_ "Between environments"
      L.ul_ $ do
        L.li_ $ L.a_ [L.href_ (getURL "images")] "Images"
        L.li_ $ L.a_ [L.href_ (getURL "revisions")] "Revisions"
      L.h2_ "Within environments"
      L.ul_ $ sequence_ [ L.li_ $ L.a_ [L.href_ (getURL (toS env <> "/changes"))] (L.toHtml env)
                        | env <- Map.keys envs ]
      L.h2_ "Ops"
      L.ul_ $
        L.li_ $ L.a_ [L.href_ (getURL "metrics")] (L.code_ "metrics")
    where
      getURL path =
        case parseRelativeReference path of
          Nothing -> panic $ toS path <> " is not a valid relative URI"
          Just path' -> toS (uriToString identity (path' `relativeTo` externalURL) "")

-- | The images that differ between Kubernetes objects.
-- Newtype wrapper is to let us provide nice HTML.
newtype ImageDiffs = ImageDiffs (Maybe (Map Kube.KubeID [Kube.ImageDiff])) deriving (Eq, Ord, Show, Generic)

instance ToJSON ImageDiffs where
  -- I *think* we can't get a default instance because Aeson cowardly refuses
  -- to objects where the keys are objects.
  toJSON (ImageDiffs diffs) = toJSON (Map.fromList . map reshapeKeys . Map.toList <$> diffs)
    where
      reshapeKeys (kubeID, diff) =
        ( Kube.namespacedName kubeID
        , Map.fromList [ ("kind" :: Text, toJSON (Kube.kind kubeID))
                       , ("diff", toJSON diff)
                       ]
        )

instance L.ToHtml ImageDiffs where
  toHtmlRaw = L.toHtml
  toHtml (ImageDiffs diffs) = standardPage "compare-images" imageDiffs
    where
      imageDiffs =
        case diffs of
          Nothing -> L.p_ (L.toHtml ("No data yet" :: Text))
          Just diffs' ->
            L.table_ $ do
              L.tr_ $ do
                L.th_ "Image"
                L.th_ "dev"
                L.th_ "prod" -- TODO: Read the environment names from the data structure, rather than hardcoding
              rows diffs'

      rows diffs' = mconcat (map (L.tr_ . toRow) (flattenedImages diffs'))
      flattenedImages diffs' = sortOn Kube.getImageName (ordNub (fold diffs'))

      toRow (Kube.ImageAdded name label) = nameCell name <> labelCell label <> L.td_ "ADDED"
      toRow (Kube.ImageChanged name oldLabel newLabel) = nameCell name <> labelCell oldLabel <> labelCell newLabel
      toRow (Kube.ImageRemoved name label) = nameCell name <> L.td_ "REMOVED" <> labelCell label

      nameCell = L.td_ . L.toHtml
      labelCell = L.td_ . L.toHtml . fromMaybe "<no label>"


-- | The revisions that differ between images.
--
-- newtype wrapper exists so we can define HTML & JSON views.
newtype RevisionDiffs = RevisionDiffs (Maybe (Map Kube.ImageName (Either Engine.Error (Git.URL, [Git.Revision])))) deriving (Show)

-- TODO: JSON version of Revisions.

instance L.ToHtml RevisionDiffs where
  toHtmlRaw = L.toHtml
  toHtml (RevisionDiffs clusterDiff) = standardPage "compare-revisions" byImage
    where
      byImage =
        case clusterDiff of
          Nothing -> L.p_ (L.toHtml ("No data yet" :: Text))
          Just diff -> foldMap renderImage (Map.toAscList diff)

      renderImage (name, revs) =
        L.h2_ (L.toHtml name) <> renderLogs revs

      renderLogs (Left (Engine.NoConfigForImage _)) =
        L.p_ (L.toHtml ("No repository configured for image" :: Text))
      renderLogs (Left err) =
        L.pre_ (L.toHtml (show err :: Text))
      renderLogs (Right (_, [])) =
        L.p_ (L.toHtml ("No revisions in range" :: Text))
      renderLogs (Right (_, revs)) =
        L.table_ $ do
          L.tr_ $ do
            L.th_ "SHA-1"
            L.th_ "Date"
            L.th_ "Author"
            L.th_ "Subject"
          foldMap renderRevision revs

      renderRevision rev@Git.Revision{..} =
        L.tr_ $
          L.td_ (L.toHtml (Git.abbrevHash rev)) <>
          L.td_ (L.toHtml (formatDateAndTime commitDate)) <>
          L.td_ (L.toHtml authorName) <>
          L.td_ (L.toHtml subject)


data ChangeLog
  = ChangeLog
  { environment :: Config.EnvironmentName
  , startDate :: Time.Day
  , changelog :: Map Kube.ImageName (Either Engine.Error (Git.URL, [Git.Revision]))
  } deriving (Show)

instance L.ToHtml ChangeLog where
  toHtmlRaw = L.toHtml
  toHtml ChangeLog{environment, startDate, changelog} = standardPage (environment <> " :: changelog") $ do
    L.p_ ("Since " <> L.toHtml (formatDate startDate))
    L.table_ $ do
      L.tr_ $ do
        L.th_ "Date"
        L.th_ "Repo"
        L.th_ "Subject"
        L.th_ "Author"
      foldMap renderRevision (reverse (sortOn (Git.commitDate . snd) (Map.keys (flattenChangelog changelog))))
    L.h2_ (L.toHtml ("This week" :: Text))
    L.h2_ (L.toHtml ("Last week" :: Text))
    where
      formatDate = Time.formatTime Time.defaultTimeLocale (Time.iso8601DateFormat Nothing)
      renderRevision (uri, Git.Revision{commitDate, authorName, subject}) =
        L.tr_ $
          L.td_ (L.toHtml (formatDateAndTime commitDate)) <>
          L.td_ (renderRepoURL uri) <>
          L.td_ (L.toHtml subject) <>
          L.td_ (L.toHtml authorName)
      renderRepoURL (Git.URI uri) =
        let path = toS $ uriPath uri
            withoutGit = fromMaybe path (Text.stripSuffix ".git" path)
            cleanPath = fromMaybe withoutGit (Text.stripPrefix "/weaveworks/" withoutGit)
        in L.a_ [L.href_ (toS $ uriToString (const "") uri "")] (L.toHtml cleanPath)
      renderRepoURL uri@(Git.SCP _) = L.toHtml (Git.toText uri)


-- | Format a UTC time in the standard way for our HTML.
--
-- This means ISO with numeric timezone.
formatDateAndTime :: Time.UTCTime -> Text
formatDateAndTime = toS . Time.formatTime Time.defaultTimeLocale (Time.iso8601DateFormat (Just "%H:%M:%S%z"))

flattenChangelog
  :: Map Kube.ImageName (Either Engine.Error (Git.URL, [Git.Revision]))
  -> Map (Git.URL, Git.Revision) [Kube.ImageName]
flattenChangelog changelog =
  Map.fromListWith (<>) [((uri, rev), [img]) | (img, Right (uri, revs)) <- Map.toList changelog, rev <- revs]
