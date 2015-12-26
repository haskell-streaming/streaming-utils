{-| This module is much more experimental than the other modules in this package.
    The focus throughout is on a type not much thematized in the @conduit@ libraries,
    @ConduitM () a m r@. This is equivalent to @Pipes.Producer a m r@ or @Stream (Of a) m r@
    The leading @conduit@ combinators structure the material so that the special case
    @ConduitM () a m ()@, given the synonym @Source m a@ predominates. But intuitively
    a @Source m a@ can e.g. be split or chunked, and this involves awakening the
    supressed return value:

> splitAt 4 :: ConduitM () a m r -> ConduitM () a m (ConduitM () a m r)

    or equivalently,

> splitAt 4 :: Source m a -> ConduitM () a m (Source m a)




-}

{-#LANGUAGE BangPatterns #-}
module Streaming.Conduit (
  -- * Conversions
  toStream
  , fromStream
  , toStreamingByteString
  , fromStreamingByteString

  -- * Folds and scans over conduit producers
  , fold
  , fold_
  , foldM
  , scan
  , scanM
  , folds
  , foldsM

  -- * Splitting conduits producers in half or into pieces
  , next
  , splitAt
  , chunksOf
  , span
  , concats
  , filter

  -- * Constructing a conduit producer from a step function
  , unfoldr

  -- * Performing only the effects of a conduit producer, preserving its return value
  , drain
  , drained

  -- * Apply a Conduit a b m () to a conduit
  , ($$$)
  , applyConduit
  ) where

import Data.Conduit
-- import qualified Conduit as C
import qualified Data.Conduit.Internal as CI
import Data.Conduit.Internal (Pipe (..), ConduitM (..))

import Streaming (Of(..))
import qualified Streaming as S
import qualified Streaming.Internal as S
import qualified Streaming.Prelude as S
import qualified Data.ByteString.Streaming as Q


import Prelude hiding (span, splitAt, filter)
import Control.Monad hiding (foldM)
import Control.Monad.Trans
import Data.Void
import qualified Data.ByteString as B
-- for ghci testing
--
-- import qualified Data.Conduit.List as C
-- import qualified Control.Foldl as L
-- import qualified Pipes as P
-- import qualified Pipes.Group as P
-- import qualified Pipes.Parse as P
-- import qualified Pipes.Prelude as P



fold :: Monad m
       =>  (x -> a -> x) -> x -> (x -> b)
       -> ConduitM () a m r -> m (Of b r)
fold f begin out (ConduitM src0) = go (src0 CI.Done) begin where

    go s b = case s of
      CI.Done r               -> return (out b :> r)
      CI.HaveOutput src _ a   -> go src Prelude.$! f b a
      CI.NeedInput _ c        -> go (c ()) b
      CI.Leftover src ()      -> go src b
      CI.PipeM msrc           -> do src <- msrc
                                    go src b

fold_ :: Monad m
       =>  (x -> a -> x) -> x -> (x -> b)
       -> ConduitM () a m r -> m b
fold_ f begin out (ConduitM src0) = go (src0 CI.Done) begin where

    go s b = case s of
      CI.Done r               -> return $ out b
      CI.HaveOutput src _ a   -> go src Prelude.$! f b a
      CI.NeedInput _ c        -> go (c ()) b
      CI.Leftover src ()      -> go src b
      CI.PipeM msrc           -> do src <- msrc
                                    go src b


scan :: Monad m
       =>  (x -> a -> x) -> x -> (x -> b)
       -> ConduitM () a m r -> ConduitM () b m r
scan step begin done con = ConduitM  (go begin (unConduitM con Done) >>=) where

    go !acc p = HaveOutput (loop acc p) (return ()) (done acc)
    loop !acc p =
         case p of
            Done r               -> return r
            HaveOutput src m a   ->
               let !acc1 = step acc a
               in go acc1 src
            NeedInput _ c        -> go acc (c ())
            Leftover src ()      -> go acc src
            PipeM msrc           -> do src <- lift msrc
                                       go acc src

scanM :: Monad m
       =>  (x -> a -> m x) -> m x -> (x -> m b)
       -> ConduitM () a m r -> ConduitM () b m r
scanM step begin done con = ConduitM $ \k -> do
      p <- lift $ do acc0 <- begin
                     yielder acc0 (unConduitM con Done)
      r <- p
      k r
  where
    yielder !acc p = do
      x <- done acc
      return $ HaveOutput (PipeM (loop acc p)) (return ()) x
    loop !acc p =
         case p of
            Done r               -> return (return r)
            HaveOutput src m a   ->
               do !acc1 <- step acc a
                  yielder acc1 src
            NeedInput _ c        -> loop acc (c ())
            Leftover src ()      -> loop acc src
            PipeM msrc           -> do src <- msrc
                                       loop acc src

foldM :: Monad m
       =>  (x -> a -> m x) -> m x -> (x -> m b)
       -> ConduitM () a m r -> m (Of b r)
foldM step begin out (ConduitM src0) = begin >>= go (src0 CI.Done) where

    go s b = case s of
      Done r               -> out b >>= \x -> return (x :> r)
      HaveOutput src _ a   -> do !b' <- step b a
                                 go src b'
      NeedInput _ c        -> go (c ()) b
      Leftover src ()      -> go src b
      PipeM msrc           -> do src <- msrc
                                 go src b

folds
  :: Monad m =>
     (x -> a -> x) -> x -> (x -> b)
     -> S.Stream (ConduitM () a m) m r
     -> ConduitM () b m r
folds step begin done = loop where

  loop str = do
    e <- lift $ S.inspect str
    case e of
      Left r -> return r
      Right cstr -> do
        (b :> rest) <- lift $ fold step begin done cstr
        yield b
        loop rest

foldsM
  :: Monad m =>
  (x -> a -> m x) -> m x -> (x -> m b)
     -> S.Stream (ConduitM () a m) m r
     -> ConduitM () b m r
foldsM step begin done = loop where

  loop str = do
    e <- lift $ S.inspect str
    case e of
      Left r -> return r
      Right cstr -> do
        (b :> rest) <- lift $ foldM step begin done cstr
        yield b
        loop rest

chunksOf :: Monad m => Int -> ConduitM () a m r -> S.Stream (ConduitM () a m) m r
chunksOf m con = loop m (unConduitM con Done) where

  loop m p = case p of
      Done r               -> return r
      PipeM msrc           -> S.Effect $ liftM (loop m) msrc
      NeedInput _ c        -> loop m (c ())
      Leftover src ()      -> loop m src
      HaveOutput src x a   -> S.wrap $ ConduitM $ \r2pipe -> do
          rest <- pipeSplit m (HaveOutput src x a)
          r2pipe $ loop m rest


splitAt  :: (Monad m) =>
   Int -> ConduitM () o m r -> ConduitM () o m (ConduitM () o m r)
splitAt n c = ConduitM $ \k -> do
    p <- pipeSplit n (unConduitM c Done)
    k (ConduitM (p >>=))
  where
    pipeSplit :: Monad m => Int
                       -> Pipe () () a () m r
                       -> Pipe () () a () m (Pipe () () a () m r)
    pipeSplit  = loop  where

      loop 0 p = return p
      loop n p = case p of
          Done r               -> return $ Done r
          PipeM msrc           -> PipeM $ liftM (loop n) msrc
          NeedInput _ c        -> loop n (c ())
          Leftover src ()      -> loop n src
          HaveOutput src x a   -> HaveOutput (loop (n-1) src) x a


unfoldr :: Monad m
   => (s -> m (Either r (a, s))) -> s -> ConduitM () a m r
unfoldr f s = ConduitM (loop s >>=) where

  loop seed = do
    e <- lift (f seed)
    case e of
      Right (a, seed') -> do
        pipeYield a
        loop seed'
      Left r -> return r

next :: Monad m => ConduitM () a m r -> m (Either r (a, ConduitM () a m r))
next c = do
  e <- pipeNext (unConduitM c Done)
  case e of
    Left r -> return $ Left r
    Right (a, p) -> return $ Right (a, ConduitM (p >>=))
 where
  pipeNext :: Monad m => Pipe () () a () m r -> m (Either r (a, Pipe () () a () m r))
  pipeNext = loop where

    loop p = case p of
      Done r               -> return (Left r)
      PipeM msrc           -> msrc >>= loop
      NeedInput _ c        -> loop (c ())
      Leftover src ()      -> loop src
      HaveOutput src _ a   -> return $ Right (a, src)

toStream :: Monad m => ConduitM () a m r -> S.Stream (S.Of a) m r
toStream c = S.unfoldr pipeNext (unConduitM c Done)
{-#INLINE toStream #-}

fromStream :: Monad m => S.Stream (S.Of a) m r -> ConduitM () a m r
fromStream = unfoldr S.next
{-#INLINE fromStream #-}

span  :: (Monad m)
       => (o -> Bool) -> ConduitM () o m r
      -> ConduitM () o m (ConduitM () o m r)
span pred c =  ConduitM $ \k -> do
    p <- pipeSpan (unConduitM c Done)
    k (ConduitM (p >>=))
  where
  pipeSpan c = do
    e <- lift $ pipeNext c
    case e of
      Left r -> return (return r)
      Right (a, rest) -> if pred a
        then pipeYield a >> pipeSpan rest
        else return (pipeYield a >> rest)
{-#INLINE span  #-}

pipeYield :: Monad m => o -> Pipe l i o u m ()
pipeYield = HaveOutput (return ()) (return ())

concats :: Monad m => S.Stream (ConduitM i o m) m a -> ConduitM i o m a
concats str = S.destroy str S.join (S.join . lift) return
-- this is monad-transformer-general
filter
  :: Monad m => (o -> Bool) -> ConduitM () o m r -> ConduitM i o m r
filter pred c = ConduitM (loop (unConduitM c Done) >>=) where

  loop s = do
    e <- lift (pipeNext s)
    case e of
      Left r -> return r
      Right (a, rest) -> do
        when (pred a) (pipeYield a)
        loop rest


toStreamingByteString :: Monad m => ConduitM () B.ByteString m r -> Q.ByteString m r
toStreamingByteString c = loop (unConduitM c Done) where
  loop p = do
    e <- lift (pipeNext p)
    case e of
      Left r -> return r
      Right (bs, rest) -> Q.chunk bs >> loop rest


fromStreamingByteString :: Monad m => Q.ByteString m r -> ConduitM () B.ByteString m r
fromStreamingByteString =  unfoldr Q.nextChunk


drain :: Monad m => ConduitM () a m r -> m r
drain (ConduitM k) = drainPipe (k Done) where
drainPipe p = do
    e <- pipeNext p
    case e of
      Left r -> return r
      Right (_, rest) -> drainPipe rest


drained :: (Monad m, MonadTrans t, Monad (t m)) => t m (ConduitM () a m r) -> t m r
drained = join . liftM (lift . drain)

($$$)
  :: Monad m =>
      ConduitM () i m r -> ConduitM i o m () -> ConduitM () o m r
f $$$ y = applyConduit y f


applyConduit
  :: Monad m =>
     ConduitM i o m () -> ConduitM () i m r -> ConduitM () o m r
applyConduit c c' = ConduitM $ \k -> do
     r <- loop (unConduitM c' Done)  (unConduitM c Done)
     k r
  where

  loop l r = do
    e <- lift $ pipeNext l
    case e of
      Left s -> case r of
        Leftover rr u -> loop (pipeYield u >> l) rr
        HaveOutput src _ u -> pipeYield u >> return s
        PipeM msrc -> PipeM (liftM (loop (return s)) msrc)
        NeedInput f c -> loop (return s) (c ())
        Done () -> return s

      Right (a, rest) -> case r of
        Done ()  -> lift $ drainPipe rest
        HaveOutput src _ u -> pipeYield u >> loop l src
        PipeM msrc -> PipeM (liftM (loop (pipeYield a >> rest)) msrc)
        NeedInput f c -> loop rest (f a)
        Leftover rr u -> loop (pipeYield u >> pipeYield a >> rest) rr
