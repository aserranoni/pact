{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}


-- |
-- Module      :  Pact.Core.IR.Typecheck
-- Copyright   :  (C) 2022 Kadena
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Jose Cardona <jose@kadena.io>
--
-- Pact core minimal repl
--


module Main where

import Control.Lens
import Control.Monad.IO.Class(liftIO)
import Control.Monad.Catch
import System.Console.Haskeline
import Data.IORef
import Data.Foldable(traverse_)
import Control.Monad.Trans(lift)

import qualified Data.ByteString as B
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Set as Set

import Pact.Core.Compile
import Pact.Core.Repl.Utils
import Pact.Core.Persistence
import Pact.Core.Pretty
import Pact.Core.Builtin

main :: IO ()
main = do
  pactDb <- mockPactDb
  g <- newIORef mempty
  evalLog <- newIORef Nothing
  ref <- newIORef (ReplState mempty emptyLoaded pactDb g evalLog)
  runReplT ref (runInputT replSettings (loop lispInterpretBundle ref))
  where
  replSettings = Settings (replCompletion rawBuiltinNames) (Just ".pc-history") True
  displayOutput = \case
    InterpretValue v -> outputStrLn (show (pretty v))
    InterpretLog t -> outputStrLn (T.unpack t)
  catch' bundle ref ma = catchAll ma (\e -> outputStrLn (show e) *> loop bundle ref)
  loop bundle ref = do
    minput <- fmap (T.strip . T.pack) <$> getInputLine "pact>"
    case minput of
      Nothing -> outputStrLn "goodbye"
      Just input | T.null input -> loop bundle ref
      Just input -> case parseReplAction input of
        Nothing -> do
          outputStrLn "Error: Expected command [:load, :type, :syntax, :debug] or expression"
          loop bundle ref
        Just ra -> case ra of
          RALoad txt -> let
            file = T.unpack txt
            in catch' bundle ref $ do
              source <- liftIO (B.readFile file)
              vs <- lift (program bundle source)
              traverse_ displayOutput vs
              loop bundle ref
          RASetLispSyntax -> loop lispInterpretBundle ref
          RASetNewSyntax -> loop lispInterpretBundle ref
          RATypecheck inp -> catch' bundle ref $ do
            let inp' = T.strip inp
            out <- lift (exprType bundle (T.encodeUtf8 inp'))
            outputStrLn (show (pretty out))
            loop bundle ref
          RASetFlag flag -> do
            liftIO (modifyIORef' ref (over replFlags (Set.insert flag)))
            outputStrLn $ unwords ["set debug flag for", prettyReplFlag flag]
            loop bundle ref
          RADebugAll -> do
            liftIO (modifyIORef' ref (set replFlags (Set.fromList [minBound .. maxBound])))
            outputStrLn $ unwords ["set all debug flags"]
            loop bundle ref
          RADebugNone -> do
            liftIO (modifyIORef' ref (set replFlags mempty))
            outputStrLn $ unwords ["Remove all debug flags"]
            loop bundle ref
          RAExecuteExpr src -> catch' bundle ref $ do
            out <- lift (expr bundle (T.encodeUtf8 src))
            displayOutput (InterpretValue out)
            loop bundle ref
