module Streaming.Pipes.Concurrent
 (module Pipes.Concurrent
 , module GHC.Conc.Sync
 , fromInput
 , toOutput) 
  where

import Pipes.Concurrent hiding (fromInput, toOutput)
import qualified Pipes.Concurrent as Conc
import GHC.Conc.Sync (STM(..), TVar(..), ThreadId(..))
import Streaming
import qualified Streaming.Prelude as S

toOutput :: (MonadIO m) => Output a -> Stream (Of a) m () -> m ()
toOutput output = loop where
  loop str = do
    e <- S.next str
    case e of 
      Left r -> return r
      Right (a, rest) -> do 
        alive <- liftIO $ Conc.atomically $ send output a
        if alive then loop rest else return ()
{-# INLINABLE toOutput #-}


fromInput :: (MonadIO m) => Input a -> Stream (Of a) m ()
fromInput input = loop where
  loop = do
      ma <- liftIO $ Conc.atomically $ recv input
      case ma of
          Nothing -> return ()
          Just a  -> do
              S.yield a
              loop
{-# INLINABLE fromInput #-}


