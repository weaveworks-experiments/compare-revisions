{-# LANGUAGE DuplicateRecordFields #-}
module Kube (tests) where

import Protolude

import qualified Data.Map as Map
import qualified Data.Set as Set
import Data.String (String)
import qualified Data.Yaml as Yaml
import qualified Data.Text as Text
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck ((===), (==>))
import qualified Test.QuickCheck as QuickCheck
import Test.Tasty (TestTree)
import Test.Tasty.Hspec (testSpec, describe, it, shouldBe)

import qualified CompareRevisions.Kube as Kube


kubeObjects :: QuickCheck.Gen Kube.KubeObject
kubeObjects = Kube.KubeObject <$> kubeIDs <*> QuickCheck.listOf images'

kubeIDs :: QuickCheck.Gen Kube.KubeID
kubeIDs =
  Kube.KubeID <$> text <*> text <*> text

images' :: QuickCheck.Gen Kube.Image
images' =
  Kube.Image <$> text <*> labels

labels :: QuickCheck.Gen (Maybe Kube.ImageLabel)
labels = QuickCheck.oneof [ pure Nothing
                          , Just <$> text
                          ]

text :: QuickCheck.Gen Text
text = toS <$> (QuickCheck.arbitrary :: QuickCheck.Gen String)


tests :: IO TestTree
tests = testSpec "Kube" $ do
  describe "Parser" $
    it "parses normal YAML files" $ do
      let parsed = Yaml.decodeEither (toS example)
      parsed `shouldBe` Right Kube.KubeObject
        { id = Kube.KubeID { namespace = "cortex"
                           , name = "ruler"
                           , kind = "Deployment"
                           }
        , images = [ Kube.Image { name = "quay.io/weaveworks/cortex-ruler"
                                , label = Just "master-f7f6cf9e"
                                }
                   ]
        }

  describe "Image Sets" $ do
    prop "Image set has all image names" $
      QuickCheck.forAll kubeObjects $ \obj ->
      Set.fromList [ Kube.Image n l | (n, l) <- Map.toList (Kube.getImageSet obj) ] `Set.isSubsetOf` Set.fromList (Kube.images obj)
    it "Finds all the images in our example" $ do
      let Right obj = Yaml.decodeEither (toS example)
      Kube.getImageSet obj `shouldBe` Map.fromList [("quay.io/weaveworks/cortex-ruler", Just "master-f7f6cf9e")]

  describe "getDifferingImages" $ do
    prop "shows nothing for identical environments" $
      QuickCheck.forAll (QuickCheck.listOf kubeObjects) $ \env ->
      Kube.getDifferingImages env env === Map.empty

    prop "detects new images" $
      QuickCheck.forAll kubeIDs $ \kubeID -> QuickCheck.forAll images' $ \image ->
      let obj1 = Kube.KubeObject { id = kubeID, images = [image] }
          obj2 = Kube.KubeObject { id = kubeID, images = [] }
      in Kube.getDifferingImages [obj1] [obj2] === Map.singleton kubeID [Kube.ImageAdded (Kube.name (image :: Kube.Image)) (Kube.label image)]

    prop "detects removed images" $
      QuickCheck.forAll kubeIDs $ \kubeID -> QuickCheck.forAll images' $ \image ->
      let obj1 = Kube.KubeObject { id = kubeID, images = [] }
          obj2 = Kube.KubeObject { id = kubeID, images = [image] }
      in Kube.getDifferingImages [obj1] [obj2] === Map.singleton kubeID [Kube.ImageRemoved (Kube.name (image :: Kube.Image)) (Kube.label image)]

    prop "detects changed images" $
      QuickCheck.forAll kubeIDs $ \kubeID -> QuickCheck.forAll images' $ \image -> QuickCheck.forAll labels $ \newLabel ->
      newLabel /= Kube.label image ==>
      let obj1 = Kube.KubeObject { id = kubeID, images = [image] }
          obj2 = Kube.KubeObject { id = kubeID, images = [image { Kube.label = newLabel }] }
      in Kube.getDifferingImages [obj1] [obj2] === Map.singleton kubeID [Kube.ImageChanged (Kube.name (image :: Kube.Image)) (Kube.label image) newLabel]


example :: Text
example = Text.unlines
          [ "---"
          , "apiVersion: extensions/v1beta1"
          , "kind: Deployment"
          , "metadata:"
          , "  name: ruler"
          , "  namespace: cortex"
          , "spec:"
          , "  replicas: 1"
          , "  template:"
          , "    metadata:"
          , "      labels:"
          , "        name: ruler"
          , "    spec:"
          , "      containers:"
          , "      - name: ruler"
          , "        image: quay.io/weaveworks/cortex-ruler:master-f7f6cf9e"
          , "        imagePullPolicy: IfNotPresent"
          , "        args:"
          , "        - -server.http-listen-port=80"
          , "        ports:"
          , "        - containerPort: 80"
          ]
