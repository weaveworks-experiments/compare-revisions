{-# LANGUAGE DeriveGeneric #-}
module CompareRevisions.Config
  ( Config(..)
  , ConfigRepo(..)
  , Environment(..)
  , ImageConfig(..)
  , PolicyConfig(..)
  , GitURL(..)
  ) where

import Protolude hiding (Identity)

import Control.Monad.Fail (fail)
import Data.Aeson
  ( FromJSON(..)
  , ToJSON(..)
  , Value(..)
  , (.:)
  , defaultOptions
  , genericParseJSON
  , genericToJSON
  , withText
  )
import Data.Aeson.Types (Options(..), SumEncoding(..), camelTo2, typeMismatch)
import qualified Data.Char as Char
import qualified Network.URI
import CompareRevisions.Duration (Duration)
import CompareRevisions.SCP (SCP, formatSCP, parseSCP)

data Config = Config { configRepo :: ConfigRepo
                     , images :: Map ImageName ImageConfig
                     , revisionPolicies :: Map PolicyName PolicyConfig
                     } deriving (Eq, Ord, Show, Generic)

configOptions :: Options
configOptions = defaultOptions { fieldLabelModifier = camelTo2 '-' }

instance ToJSON Config where
  toJSON = genericToJSON configOptions

instance FromJSON Config where
  parseJSON = genericParseJSON configOptions

type ImageName = Text
type PolicyName = Text

data GitURL = URI Network.URI.URI
            | SCP SCP
            deriving (Eq, Ord, Show, Generic)

instance ToJSON GitURL where
  toJSON (URI uri) = toJSON (Network.URI.uriToString identity uri "")
  toJSON (SCP scp) = toJSON (formatSCP scp)

instance FromJSON GitURL where
  parseJSON = withText "URI must be text" $ \text ->
    maybe empty pure (URI <$> Network.URI.parseAbsoluteURI (toS text)) <|> (SCP <$> parseSCP text)

data ConfigRepo
  = ConfigRepo
    { url :: GitURL
    , pollInterval :: Duration
    , sourceEnv :: Environment
    , targetEnv :: Environment
    } deriving (Eq, Ord, Show, Generic)

configRepoOptions :: Options
configRepoOptions = defaultOptions { fieldLabelModifier = camelTo2 '-' }

instance ToJSON ConfigRepo where
  toJSON = genericToJSON configRepoOptions

instance FromJSON ConfigRepo where
  parseJSON = genericParseJSON configRepoOptions

data Environment
  = Environment
    { name :: EnvironmentName
    , path :: FilePath
    } deriving (Eq, Ord, Show, Generic)

type EnvironmentName = Text

instance FromJSON Environment
instance ToJSON Environment

data ImageConfig
  = ImageConfig
  { gitURL :: GitURL
  , imageToRevisionPolicy :: PolicyName
  } deriving (Eq, Ord, Show, Generic)

imageConfigOptions :: Options
imageConfigOptions = defaultOptions { fieldLabelModifier = camelTo2 '-' }

instance ToJSON ImageConfig where
  toJSON = genericToJSON imageConfigOptions

instance FromJSON ImageConfig where
  parseJSON = genericParseJSON imageConfigOptions

data PolicyConfig
  = Regex
  { match :: Text  -- XXX: Probably a different type
  , output :: Text  -- XXX: Probably a different type
  }
  | Identity
  deriving (Eq, Ord, Show, Generic)

policyConfigOptions :: Options
policyConfigOptions =
  defaultOptions { constructorTagModifier = map Char.toLower
                 , sumEncoding = TaggedObject "type" "contents"
                 }

instance ToJSON PolicyConfig where
  toJSON = genericToJSON policyConfigOptions

instance FromJSON PolicyConfig where
  parseJSON (Object v) = do
    typ <- v .: "type"
    case typ of
      String "identity" -> pure Identity
      String "regex" -> Regex <$> v .: "match" <*> v .: "output"
      String x -> fail $ "Unrecognized policy type: " <> toS x
      x -> typeMismatch "Policy type name" x
  parseJSON x = typeMismatch "Policy config" x
