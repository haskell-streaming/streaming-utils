{-# LANGUAGE RankNTypes #-}

-- | This minimal module exports facilities that ease the usage of TCP

-- 'Socket's in the /Pipes ecosystem/. It is meant to be used together with
-- the "Network.Simple.TCP" module from the @network-simple@ package, which is
-- completely re-exported from this module.
--
-- This module /does not/ export facilities that would allow you to acquire new
-- 'Socket's within a pipeline. If you need to do so, then you should use
-- "Pipes.Network.TCP.Safe" instead, which exports a similar API to the one
-- exported by this module. However, don't be confused by the word ñsafeî in
-- that module; this module is equally safe to use as long as you don't try to
-- acquire resources within the pipeline.

module Streaming.Network.TCP (
  -- * Receiving
  -- $receiving
    fromSocket
  , fromSocketTimeout
  , fromSocketChunks

  -- * Sending
  -- $sending
  , toSocket
  , toSocketChunks
  , toSocketLazy
  , toSocketMany
  , toSocketTimeout
  , toSocketTimeoutChunks
  , toSocketTimeoutLazy
  , toSocketTimeoutMany
  
  -- * Exports
  -- $exports
  , module Network.Simple.TCP
  ) where

import qualified Data.ByteString                as B
import qualified Data.ByteString.Lazy           as BL
import qualified Data.ByteString.Streaming      as Q
import Streaming
import qualified Streaming.Prelude as S

import           Foreign.C.Error                (errnoToIOError, eTIMEDOUT)
import qualified Network.Socket.ByteString      as NSB
import           Network.Simple.TCP
                  (connect, serve, listen, accept, acceptFork,
                   bindSock, connectSock, closeSock, recv, send, sendLazy,
                   sendMany, withSocketsDo, HostName,
                   HostPreference(HostAny, HostIPv4, HostIPv6, Host),
                   ServiceName, SockAddr, Socket)
-- import           Pipes
-- import           Pipes.Core
import           System.Timeout                 (timeout)

--------------------------------------------------------------------------------

-- $receiving
--
-- The following producers allow you to receive bytes from the remote end.
--
-- Besides the producers below, you might want to use "Network.Simple.TCP"'s
-- 'recv', which happens to be an 'Effect'':
--
-- @
-- 'recv' :: 'MonadIO' m => 'Socket' -> 'Int' -> 'Effect'' m ('Maybe' 'B.ByteString')
-- @

--------------------------------------------------------------------------------

-- | Receives bytes from the remote end and sends them downstream.
--
-- The number of bytes received at once is always in the interval
-- /[1 .. specified maximum]/.
--
-- This 'Producer'' returns if the remote peer closes its side of the connection
-- or EOF is received.
fromSocket
  :: MonadIO m
  => Socket     -- ^Connected socket.
  -> Int        -- ^Maximum number of bytes to receive and send
                -- dowstream at once. Any positive value is fine, the
                -- optimal value depends on how you deal with the
                -- received data. Try using @4096@ if you don't care.
  -> Q.ByteString m ()
fromSocket sock nbytes = loop where
    loop = do
        bs <- liftIO (NSB.recv sock nbytes)
        if B.null bs
           then return ()
           else Q.chunk bs >> loop
{-# INLINABLE fromSocket #-}
     

-- | Receives bytes from the remote end and sends them downstream.
--
-- The number of bytes received at once is always in the interval
-- /[1 .. specified maximum]/.
--
-- This 'Producer'' returns if the remote peer closes its side of the connection
-- or EOF is received.
fromSocketChunks
  :: MonadIO m
  => Socket     -- ^Connected socket.
  -> Int        -- ^Maximum number of bytes to receive and send
                -- dowstream at once. Any positive value is fine, the
                -- optimal value depends on how you deal with the
                -- received data. Try using @4096@ if you don't care.
  -> Stream (Of B.ByteString) m ()
fromSocketChunks sock nbytes = loop where
    loop = do
        bs <- liftIO (NSB.recv sock nbytes)
        if B.null bs
           then return ()
           else S.yield bs >> loop
{-# INLINABLE fromSocketChunks #-}

-- | Like 'fromSocket', except with the first 'Int' argument you can specify
-- the maximum time that each interaction with the remote end can take. If such
-- time elapses before the interaction finishes, then an 'IOError' exception is
-- thrown. The time is specified in microseconds (1 second = 1e6 microseconds).
fromSocketTimeout
  :: MonadIO m
  => Int -> Socket -> Int -> Q.ByteString m ()
fromSocketTimeout wait sock nbytes = loop where
    loop = do
       mbs <- liftIO (timeout wait (NSB.recv sock nbytes))
       case mbs of
          Just bs
           | B.null bs -> return ()
           | otherwise -> Q.chunk bs >> loop
          Nothing -> liftIO $ ioError $ errnoToIOError
             "Pipes.Network.TCP.fromSocketTimeout" eTIMEDOUT Nothing Nothing
{-# INLINABLE fromSocketTimeout #-}

-- --------------------------------------------------------------------------------
--
-- -- $bidirectional
-- --
-- -- The following pipes are bidirectional, which means useful data can flow
-- -- through them upstream and downstream. If you don't care about bidirectional
-- -- pipes, just skip this section.
--
-- --------------------------------------------------------------------------------
--
-- -- | Like 'fromSocket', except the downstream pipe can specify the maximum
-- -- number of bytes to receive at once using 'request'.
-- fromSocketN :: MonadIO m => Socket -> Int -> Server' Int B.ByteString m ()
-- fromSocketN sock = loop where
--     loop = \nbytes -> do
--         bs <- liftIO (NSB.recv sock nbytes)
--         if B.null bs
--            then return ()
--            else respond bs >>= loop
-- {-# INLINABLE fromSocketN #-}
--
--
-- -- | Like 'fromSocketN', except with the first 'Int' argument you can specify
-- -- the maximum time that each interaction with the remote end can take. If such
-- -- time elapses before the interaction finishes, then an 'IOError' exception is
-- -- thrown. The time is specified in microseconds (1 second = 1e6 microseconds).
-- fromSocketTimeoutN
--   :: MonadIO m
--   => Int -> Socket -> Int -> Server' Int B.ByteString m ()
-- fromSocketTimeoutN wait sock = loop where
--     loop = \nbytes -> do
--        mbs <- liftIO (timeout wait (NSB.recv sock nbytes))
--        case mbs of
--           Just bs
--            | B.null bs -> return ()
--            | otherwise -> respond bs >>= loop
--           Nothing -> liftIO $ ioError $ errnoToIOError
--              "Pipes.Network.TCP.fromSocketTimeoutN" eTIMEDOUT Nothing Nothing
-- {-# INLINABLE fromSocketTimeoutN #-}
--
--------------------------------------------------------------------------------

-- $sending
--
-- The following consumers allow you to send bytes to the remote end.
--
-- Besides the consumers below, you might want to use "Network.Simple.TCP"'s
-- 'send', 'sendLazy' or 'sendMany' which happen to be 'Effect''s:
--
-- @
-- 'send'     :: 'MonadIO' m => 'Socket' ->  'B.ByteString'  -> 'Effect'' m ()
-- 'sendLazy' :: 'MonadIO' m => 'Socket' ->  'BL.ByteString'  -> 'Effect'' m ()
-- 'sendMany' :: 'MonadIO' m => 'Socket' -> ['B.ByteString'] -> 'Effect'' m ()
-- @

-- | Sends to the remote end each 'B.ByteString' received from upstream.
toSocket
  :: MonadIO m
  => Socket  -- ^Connected socket.
  -> Q.ByteString m r
  -> m r
toSocket sock = loop where
  loop bs = do
    e <- Q.nextChunk bs
    case e of
      Left r -> return r
      Right (b,rest) -> send sock b >> loop rest
{-# INLINABLE toSocket #-}

-- | Like 'toSocket' but takes a stream of strict bytestring chunks

toSocketChunks
  :: MonadIO m
  => Socket  -- ^Connected socket.
  -> Stream (Of B.ByteString) m r
  -> m r
toSocketChunks sock = loop where
  loop str = do 
    e <- S.next str
    case e of 
      Left r -> return r
      Right (b, rest) -> send sock b >> loop rest
{-# INLINABLE toSocketChunks #-}


-- | Like 'toSocket' but takes a lazy 'BL.ByteSring' and sends it in a more
-- efficient manner (compared to converting it to a strict 'B.ByteString' and
-- sending it).
toSocketLazy
  :: MonadIO m
  => Socket  -- ^Connected socket.
  -> Stream (Of BL.ByteString) m r
  -> m r
toSocketLazy sock = loop where
  loop str = do 
    e <- S.next str
    case e of 
      Left r -> return r
      Right (b, rest) -> sendLazy sock b >> loop rest
{-# INLINABLE toSocketLazy #-}

-- | Like 'toSocket' but takes a @['BL.ByteSring']@ and sends it in a more
-- efficient manner (compared to converting it to a strict 'B.ByteString' and
-- sending it).
toSocketMany
  :: MonadIO m
  => Socket  -- ^Connected socket.
  -> Stream (Of [B.ByteString]) m r
  -> m r
toSocketMany sock = loop where
  loop str = do 
    e <- S.next str
    case e of 
      Left r -> return r
      Right (b, rest) -> sendMany sock b >> loop rest
{-# INLINABLE toSocketMany #-}



-- | Like 'toSocket', except with the first 'Int' argument you can specify
-- the maximum time that each interaction with the remote end can take. If such
-- time elapses before the interaction finishes, then an 'IOError' exception is
-- thrown. The time is specified in microseconds (1 second = 1e6 microseconds).
toSocketTimeout :: MonadIO m => Int -> Socket -> Q.ByteString m r -> m r
toSocketTimeout = _toSocketTimeout send "Pipes.Network.TCP.toSocketTimeout"
{-# INLINABLE toSocketTimeout #-}
-- | Like 'toSocket', except with the first 'Int' argument you can specify
-- the maximum time that each interaction with the remote end can take. If such
-- time elapses before the interaction finishes, then an 'IOError' exception is
-- thrown. The time is specified in microseconds (1 second = 1e6 microseconds).
toSocketTimeoutChunks :: MonadIO m => Int -> Socket -> Stream (Of B.ByteString) m r -> m r
toSocketTimeoutChunks = _toSocketTimeoutChunks send "Pipes.Network.TCP.toSocketTimeout"
{-# INLINABLE toSocketTimeoutChunks #-}

-- | Like 'toSocketTimeout' but takes a lazy 'BL.ByteSring' and sends it in a
-- more efficient manner (compared to converting it to a strict 'B.ByteString'
-- and sending it).
toSocketTimeoutLazy :: MonadIO m => Int -> Socket -> Stream (Of BL.ByteString) m r -> m r
toSocketTimeoutLazy =
    _toSocketTimeoutChunks sendLazy "Pipes.Network.TCP.toSocketTimeoutLazy"
{-# INLINABLE toSocketTimeoutLazy #-}

-- | Like 'toSocketTimeout' but takes a @['BL.ByteSring']@ and sends it in a
-- more efficient manner (compared to converting it to a strict 'B.ByteString'
-- and sending it).
toSocketTimeoutMany
  :: MonadIO m => Int -> Socket -> Stream (Of [B.ByteString]) m r -> m r
toSocketTimeoutMany =
    _toSocketTimeoutChunks sendMany "Pipes.Network.TCP.toSocketTimeoutMany"
{-# INLINABLE toSocketTimeoutMany #-}

_toSocketTimeoutChunks
  :: MonadIO m
  => (Socket -> a -> IO ())
  -> String
  -> Int
  -> Socket
  -> Stream (Of a) m r
  -> m r
_toSocketTimeoutChunks send' nm wait sock = loop where
  loop str = do 
    e <- S.next str
    case e of
      Left r -> return r
      Right (a, rest) -> do
          mu <- liftIO (timeout wait (send' sock a))
          case mu of
            Just () -> return ()
            Nothing -> liftIO $ ioError $ errnoToIOError nm eTIMEDOUT Nothing Nothing
          loop rest
{-# INLINABLE _toSocketTimeoutChunks #-}


_toSocketTimeout
  :: MonadIO m
  => (Socket -> B.ByteString -> IO ())
  -> String
  -> Int
  -> Socket
  -> Q.ByteString m r
  -> m r
_toSocketTimeout send' nm wait sock = loop where
  loop str = do 
    e <- Q.nextChunk str
    case e of
      Left r -> return r
      Right (a, rest) -> do
          mu <- liftIO (timeout wait (send' sock a))
          case mu of
            Just () -> return ()
            Nothing -> liftIO $ ioError $ errnoToIOError nm eTIMEDOUT Nothing Nothing
          loop rest
{-# INLINABLE _toSocketTimeout #-}
-- --------------------------------------------------------------------------------
--
-- -- $exports
-- --
-- -- [From "Network.Simple.TCP"]
-- --     'accept',
-- --     'acceptFork',
-- --     'bindSock',
-- --     'connect',
-- --     'connectSock',
-- --     'closeSock',
-- --     'HostPreference'('HostAny','HostIPv4','HostIPv6','Host'),
-- --     'listen',
-- --     'recv',
-- --     'send',
-- --     'sendLazy',
-- --     'sendMany',
-- --     'serve'.
-- --
-- -- [From "Network.Socket"]
-- --    'HostName',
-- --    'ServiceName',
-- --    'SockAddr',
-- --    'Socket',
-- --    'withSocketsDo'.
