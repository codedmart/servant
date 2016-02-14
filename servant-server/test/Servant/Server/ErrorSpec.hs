{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE TypeOperators         #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Servant.Server.ErrorSpec (spec) where

import           Data.Aeson                 (encode)
import qualified Data.ByteString.Lazy.Char8 as BC
import           Control.Monad.Trans.Either (left)
import           Data.Proxy
import           Network.HTTP.Types         (methodGet, methodPost)
import           Test.Hspec
import           Test.Hspec.Wai

import           Servant


-- 1) Check whether one or more endpoints have the right path. Otherwise return 404.
-- 2) Check whether the one of those have the right method. Otherwise return
-- 405. If so, pick the first. We've now commited to calling at most one handler. *
-- 3) Check whether the Content-Type is known. Otherwise return 415.
-- 4) Check whether that one deserializes the body. Otherwise return 400. If there
-- was no Content-Type, try the first one of the API content-type list.
-- 5) Check whether the request is authorized. Otherwise return a 401.
-- 6) Check whether the request is forbidden. If so return 403.
-- 7) Check whether the request has a known Accept. Otherwise return 406.
-- 8) Check whether Accept-Language, Accept-Charset and Accept-Encoding exist and
-- match. We can follow the webmachine order here.
-- 9) Call the handler. Whatever it returns, we return.

spec :: Spec
spec = describe "HTTP Errors" $ do
    errorOrder
    errorRetry

------------------------------------------------------------------------------
-- * Error Order {{{

type ErrorOrderApi = "home"
                  :> ReqBody '[JSON] Int
                  :> Capture "t" Int
                  :> Post '[JSON] Int

errorOrderApi :: Proxy ErrorOrderApi
errorOrderApi = Proxy

errorOrderServer :: Server ErrorOrderApi
errorOrderServer = \_ _ -> left err402

errorOrder :: Spec
errorOrder = describe "HTTP error order"
           $ with (return $ serve errorOrderApi errorOrderServer) $ do
  let badContentType  = ("Content-Type", "text/plain")
      badAccept       = ("Accept", "text/plain")
      badMethod       = methodGet
      badUrl          = "home/nonexistent"
      badBody         = "nonsense"
      goodContentType = ("Content-Type", "application/json")
      goodAccept      = ("Accept", "application/json")
      goodMethod      = methodPost
      goodUrl         = "home/5"
      goodBody        = encode (5 :: Int)

  it "has 404 as its highest priority error" $ do
    request badMethod badUrl [badContentType, badAccept] badBody
      `shouldRespondWith` 404

  it "has 405 as its second highest priority error" $ do
    request badMethod goodUrl [badContentType, badAccept] badBody
      `shouldRespondWith` 405

  it "has 415 as its third highest priority error" $ do
    request goodMethod goodUrl [badContentType, badAccept] badBody
      `shouldRespondWith` 415

  it "has 400 as its fourth highest priority error" $ do
    request goodMethod goodUrl [goodContentType, badAccept] badBody
      `shouldRespondWith` 400

  it "has 406 as its fifth highest priority error" $ do
    request goodMethod goodUrl [goodContentType, badAccept] goodBody
      `shouldRespondWith` 406

  it "returns handler errors as its lower priority errors" $ do
    request goodMethod goodUrl [goodContentType, goodAccept] goodBody
      `shouldRespondWith` 402

-- }}}
------------------------------------------------------------------------------
-- * Error Retry {{{

type ErrorRetryApi
     = "a" :> ReqBody '[JSON] Int      :> Post '[JSON] Int                -- 0
  :<|> "a" :> ReqBody '[PlainText] Int :> Post '[JSON] Int                -- 1
  :<|> "a" :> ReqBody '[JSON] Int      :> Post '[PlainText] Int           -- 2
  :<|> "a" :> ReqBody '[JSON] String   :> Post '[JSON] Int                -- 3
  :<|> "a" :> ReqBody '[JSON] Int      :> Get  '[PlainText] Int           -- 4
  :<|>        ReqBody '[JSON] Int      :> Get  '[JSON] Int                -- 5
  :<|>        ReqBody '[JSON] Int      :> Get  '[JSON] Int                -- 6

errorRetryApi :: Proxy ErrorRetryApi
errorRetryApi = Proxy

errorRetryServer :: Server ErrorRetryApi
errorRetryServer
     = (\_ -> return 0)
  :<|> (\_ -> return 1)
  :<|> (\_ -> return 2)
  :<|> (\_ -> return 3)
  :<|> (\_ -> return 4)
  :<|> (\_ -> return 5)
  :<|> (\_ -> return 6)

errorRetry :: Spec
errorRetry = describe "Handler search"
           $ with (return $ serve errorRetryApi errorRetryServer) $ do
  let plainCT     = ("Content-Type", "text/plain")
      plainAccept = ("Accept", "text/plain")
      jsonCT      = ("Content-Type", "application/json")
      jsonAccept  = ("Accept", "application/json")
      jsonBody    = encode (1797 :: Int)

  it "should continue when URLs don't match" $ do
    request methodPost "" [jsonCT, jsonAccept] jsonBody
     `shouldRespondWith` 201 { matchBody = Just $ encode (5 :: Int) }

  it "should continue when methods don't match" $ do
    request methodGet "a" [jsonCT, jsonAccept] jsonBody
     `shouldRespondWith` 200 { matchBody = Just $ encode (4 :: Int) }

  it "should not continue when Content-Types don't match" $ do
    request methodPost "a" [plainCT, jsonAccept] jsonBody
     `shouldRespondWith` 415

  it "should not continue when body can't be deserialized" $ do
    request methodPost "a" [jsonCT, jsonAccept] (encode ("nonsense" :: String))
     `shouldRespondWith` 400

  it "should not continue when Accepts don't match" $ do
    request methodPost "a" [jsonCT, plainAccept] jsonBody
     `shouldRespondWith` 406

-- }}}
------------------------------------------------------------------------------
-- * Instances {{{

instance MimeUnrender PlainText Int where
    mimeUnrender _ = Right . read . BC.unpack

instance MimeRender PlainText Int where
    mimeRender _ = BC.pack . show
-- }}}
