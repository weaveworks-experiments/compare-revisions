{-# OPTIONS_GHC -fno-warn-redundant-constraints #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
module CompareRevisions.Git
  ( URL(..)
  , toText
  , Branch(..)
  , RevSpec(..)
  , Revision(..)
  , GitError(..)
  , ensureCheckout
  , syncRepo
  , getLog
  ) where

import Protolude

import qualified Control.Logging as Log
import qualified Data.Text as Text
import Data.Aeson (FromJSON(..), ToJSON(..), withText)
import qualified Network.URI
import System.Directory (removeDirectoryRecursive)
import System.FilePath ((</>), makeRelative, takeDirectory)
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files
  ( createSymbolicLink
  , fileExist
  , readSymbolicLink
  , rename
  )
import System.Process
  ( CmdSpec(..)
  , CreateProcess(..)
  , proc
  , readCreateProcessWithExitCode
  , showCommandForUser
  )

import CompareRevisions.SCP (SCP, formatSCP, parseSCP)

-- | The URL to a Git repository.
data URL
  = URI Network.URI.URI
  | SCP SCP
  deriving (Eq, Ord, Show, Generic)

toText :: URL -> Text
toText (URI uri) = toS $ Network.URI.uriToString identity uri ""
toText (SCP scp) = formatSCP scp

instance ToJSON URL where
  toJSON = toJSON . toText

instance FromJSON URL where
  parseJSON = withText "URI must be text" $ \text ->
    maybe empty pure (URI <$> Network.URI.parseAbsoluteURI (toS text)) <|> (SCP <$> parseSCP text)


-- | A Git branch.
newtype Branch = Branch Text deriving (Eq, Ord, Show, Generic, FromJSON, ToJSON)

-- | A SHA-1 hash for a Git revision.
newtype Hash = Hash Text deriving (Eq, Ord, Show, Generic, FromJSON)

-- | Specifies a revision in a Git repository.
newtype RevSpec = RevSpec Text deriving (Eq, Ord, Show, Generic, FromJSON)

-- | A Git revision.
--
-- Should actually contain structured data, but for now we'll just have the
-- direct output of @git log@.
newtype Revision = Revision Text deriving (Eq, Ord, Show)

-- XXX: Not sure this is a good idea. Maybe use exceptions all the way
-- through?
-- | An error that occurs while we're doing stuff.
data GitError
  -- | An error occurred running the 'git' subprocess.
  = GitProcessError Text Int Text Text (Maybe FilePath)
  deriving (Eq, Show)

-- | Sync a repository.
--
-- If the repository does not exist locally, it will be cloned from the URL.
-- If it does, it will be updated.
syncRepo
  :: (MonadIO m, MonadError GitError m, HasCallStack)
  => URL -- ^ URL of Git repository to synchronize
  -> FilePath -- ^ Where to store the bare Git repository
  -> m ()
syncRepo url repoPath = do
  Log.debug' $ "Syncing " <> show url <> " to " <> show repoPath
  repoExists <- liftIO $ fileExist repoPath
  if repoExists
    then do
      Log.debug' "Update existing repo"
      -- TODO: Wrongly assumes 'origin' is the same
      fetchRepo repoPath
    else do
      Log.debug' "Downloading new repo"
      cloneRepo url repoPath
  Log.debug' "Repo updated"

-- | Clone a Git repository.
cloneRepo :: (HasCallStack, MonadError GitError m, MonadIO m) => URL -> FilePath -> m ()
cloneRepo url gitRoot = void $ runGit (["clone", "--mirror"] <> [toText url, toS gitRoot])

-- | Fetch the latest changes to a Git repository.
fetchRepo :: (HasCallStack, MonadIO m, MonadError GitError m) => FilePath -> m ()
fetchRepo repoPath = void $ runGitInRepo repoPath ["fetch", "--all", "--prune"]


-- | Ensure a checkout exists at the given path.
--
-- Assumes that:
--   * we have write access to the repo (we create checkouts under there)
--   * we are responsible for managing the checkout path
--
-- Checkout path is a symlink to the canonical location of the working tree,
-- which is updated to point at a new directory if they are out of date.
ensureCheckout
  :: (MonadError GitError m, MonadIO m, HasCallStack)
  => FilePath -- ^ Path to a Git repository on disk
  -> Branch -- ^ The branch we want to check out
  -> FilePath -- ^ The path to the checkout
  -> m ()
ensureCheckout repoPath branch workTreePath = do
  Log.debug' $ "Ensuring checkout of " <> toS repoPath <> " to " <> show branch <> " at " <> toS workTreePath
  hash@(Hash hashText) <- hashForBranchHead branch
  let canonicalTree = repoPath </> ("rev-" <> toS hashText)
  addWorkTree canonicalTree hash
  oldTree <- liftIO $ swapSymlink workTreePath canonicalTree
  case oldTree of
    Nothing -> pass
    Just oldTreePath
      | oldTreePath == canonicalTree -> pass
      | otherwise -> removeWorkTree oldTreePath

  where
    -- | Get the SHA-1 of the head of a branch.
    hashForBranchHead :: (HasCallStack, MonadError GitError m, MonadIO m) => Branch -> m Hash
    hashForBranchHead (Branch b) = Hash . Text.strip . fst <$> runGitInRepo repoPath ["rev-list", "-n1", b]

    -- | Checkout a branch of a repo to a given path.
    addWorkTree :: (HasCallStack, MonadIO m, MonadError GitError m) => FilePath -> Hash -> m ()
    addWorkTree path (Hash hash) = do
      alreadyThere <- liftIO $ fileExist path
      -- TODO: Doesn't handle case where path exists but is a file (not a
      -- directory), or doesn't contain a valid worktree.
      unless alreadyThere $ do
        void $ runGitInRepo repoPath ["worktree", "add", toS path, hash]
        Log.debug' $ "Added work tree at " <> toS path

    removeWorkTree path = do
      liftIO $ removeDirectoryRecursive path
      void $ runGitInRepo repoPath ["worktree", "prune"]
      Log.debug' $ "Removed worktree from " <> toS path

    -- | Ensure the symlink at 'linkPath' points to 'newPath'. Return the target
    -- of the old path if it differs from the new path.
    swapSymlink :: HasCallStack => FilePath -> FilePath -> IO (Maybe FilePath)
    swapSymlink linkPath newPath = do
      Log.debug' $ "Updating symlink " <> toS linkPath <> " to point to " <> toS newPath
      currentPath <- getSymlink linkPath
      Log.debug' $ "Symlink currently points to: " <> show currentPath
      let base = takeDirectory linkPath
      let newPathRelative = makeRelative base newPath
      if Just newPathRelative == currentPath
        then pure Nothing
        else
        do let tmpLink = base </> "tmp-link"
           -- TODO: Handle tmp-link existing, or better yet, make it somewhere
           -- completely different.
           Log.debug' $ "Creating new link to " <> toS newPathRelative <> " at " <> toS tmpLink
           createSymbolicLink newPathRelative tmpLink
           Log.debug' $ "Renaming " <> toS tmpLink <> " to " <> toS linkPath
           rename (base </> "tmp-link") linkPath
           Log.debug' $ "Swapped symlink: " <> toS linkPath <> " now points to " <> toS newPath
           pure currentPath

    getSymlink :: HasCallStack => FilePath -> IO (Maybe FilePath)
    getSymlink path = do
      result <- tryJust (guard . isDoesNotExistError) (readSymbolicLink path)
      pure $ hush result

getLog :: (MonadError GitError m, MonadIO m) => FilePath -> RevSpec -> RevSpec -> m [Revision]
getLog repoPath (RevSpec start) (RevSpec end) = do
  -- TODO: Format as something mildly parseable (e.g. "--format=%h::%an::%s")
  -- and parse it.
  (out, _) <- runGitInRepo repoPath ["log", "--first-parent", "--oneline", range]
  pure (map Revision (Text.lines out))
  where
    range = start <> ".." <> end

-- | Run 'git' in a repository.
runGitInRepo :: (HasCallStack, MonadError GitError m, MonadIO m) => FilePath -> [Text] -> m (Text, Text)
runGitInRepo repoPath args = runProcess $ gitCommand (Just repoPath) args

-- | Run 'git' on the command line.
runGit :: (HasCallStack, MonadError GitError m, MonadIO m) => [Text] -> m (Text, Text)
runGit args = runProcess $ gitCommand Nothing args

-- | Run a process.
runProcess :: (HasCallStack, MonadError GitError m, MonadIO m) => CreateProcess -> m (Text, Text)
runProcess process = do
  Log.debug' $ "Running process: " <> toS cmdInfo <> "; " <> show process
  (exitCode, out, err) <- liftIO $ readCreateProcessWithExitCode process ""
  let out' = toS out
  let err' = toS err
  case exitCode of
    ExitFailure e -> do
      Log.warn' $ "Process failed (" <> show e <> "): " <> toS cmdInfo
      throwError $ GitProcessError (toS cmdInfo) e out' err' (cwd process)
    ExitSuccess -> do
      Log.debug' $ "Process succeeded: " <> toS cmdInfo
      pure (out', err')
  where
    cmdInfo =
      case spec of
        ShellCommand s -> s
        RawCommand path args -> showCommandForUser path args
    spec = cmdspec process

-- | Get the CreateProcess for running git.
gitCommand :: Maybe FilePath -> [Text] -> CreateProcess
gitCommand repoPath args = (proc "git" (map toS args)) { cwd = repoPath }
