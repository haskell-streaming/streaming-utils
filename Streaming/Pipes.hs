{-| "Pipes.Group.Tutorial" is the correct introduction to the use of this module,
    which is mostly just an optimized @Pipes.Group@, replacing @FreeT@ with @Stream@. 
    .
    The only systematic difference is that this simple module omits lenses, which 
    may make elementary usage easier to grasp. The lenses exported the pipes packages
    come into their own with the simple @StateT@ parsing procedure pipes promotes.
    I hope to make a corresponding @Streaming.Pipes.Lens@ soon.
    .
    The @pipes-group@ tutorial 
    is framed as a hunt for a genuinely streaming
    @threeGroups@. The formulation it opts for in the end would 
    be expressed here thus:

> import Pipes
> import Streaming.Pipes 
> import qualified Pipes.Prelude as P
>
> threeGroups :: (Monad m, Eq a) => Producer a m () -> Producer a m ()
> threeGroups = concats . takes 3 . groups

   The program splits the initial producer into a connected stream of
   producers containing  "equal" values; it takes three of those; and then
   erases the effects of splitting. So for example

>>> runEffect $ threeGroups (each "aabccoooooo") >-> P.print
'a'
'a'
'b'
'c'
'c'

   For the rest, only part of the tutorial that would need revision is 
   the bit at the end about writing explicit @FreeT@ programs. Here one does
   not proceed by pattern matching, but uses `inspect` in place of `runFreeT`

> inspect :: (Monad m, Functor f) => Stream f m r -> m (Either r (f (Stream f m r)))

   and for construction of a @Stream (Producer a m) m r@, the usual battery of combinators: 

> wrap   :: (Monad m, Functor f) => f (Stream f m r) -> Stream f m r
> effect :: (Monad m, Functor f) => m (Stream f m r) -> Stream f m r
> yields :: (Monad m, Functor f) => f r -> Stream f m r
> lift   :: (Monad m, Functor f) => m r -> Stream f m r 

   and so on. 

-}

{-#LANGUAGE RankNTypes, BangPatterns #-}



module Streaming.Pipes (
  -- * @Streaming@ \/ @Pipes@ interoperation
  fromStream,
  toStream,
  toStreamingByteString,
  fromStreamingByteString,
  
  -- * Splitting a 'Producer' into a connected stream of 'Producer's
  chunksOf,
  groups,
  groupsBy,
  groupsBy',
  split,
  breaks,
  
  -- * Rejoining a connected stream of 'Producer's
  concats, 
  intercalates,
  
  -- * Folding over the separate layers of a connected stream of 'Producer's
  folds,
  foldsM,
  
  -- * Transforming a connected stream of 'Producer's
  takes,
  takes',
  maps,
  
  -- * Streaming division of a 'Producer' into two
  span,
  break,
  splitAt,
  group,
  groupBy,
  

  ) where

import Pipes
import Streaming hiding (concats, groups, chunksOf)
import qualified Streaming.Internal as SI
import qualified Pipes.Internal as PI
import qualified Pipes.Prelude as P
import qualified Pipes as P


import qualified Streaming.Prelude as S
import Control.Monad (liftM)
import Prelude hiding (span, splitAt, break)
import qualified Data.ByteString as B
import qualified Data.ByteString.Streaming as Q
import qualified Data.ByteString.Streaming.Internal as Q


{- | Construct an ordinary pipes 'Producer' from a 'Stream' of elements

>>> runEffect $ fromStream (S.each  [1..3]) >-> P.print
1
2
3

-}
fromStream :: Monad m => Stream (Of a) m r -> Producer' a m r
fromStream = loop where
  loop stream = case stream of -- this should be rewritten without constructors
    SI.Return r -> PI.Pure r
    SI.Effect m  -> PI.M (liftM loop m)
    SI.Step (a:>rest) -> PI.Respond a  (\_ -> loop rest)
{-# INLINABLE fromStream #-}

{- | Construct a 'Stream' of elements from a @pipes@ 'Producer'

>>> S.print $ toStream $ P.each [1..3]
1
2
3

-}
toStream :: Monad m => Producer a m r -> Stream (Of a) m r
toStream = loop where
  loop stream = case stream of
    PI.Pure r -> SI.Return r 
    PI.M m -> SI.Effect (liftM loop m)
    PI.Respond a f -> SI.Step (a :> loop (f ()))
    PI.Request x g -> PI.closed x
{-# INLINABLE toStream #-}

{-| Link the chunks of a producer of bytestrings into a single byte stream
-}
toStreamingByteString :: Monad m => Producer B.ByteString m r -> Q.ByteString m r
toStreamingByteString = loop where
  loop stream = case stream of
    PI.Pure r -> Q.Empty r 
    PI.M m    -> Q.Go (liftM loop m)
    PI.Respond a f -> Q.Chunk a (loop (f ()))
    PI.Request x g -> PI.closed x
{-# INLINABLE toStreamingByteString #-}


{-| Successively yield the chunks hidden in a byte stream. 
-}
fromStreamingByteString :: Monad m => Q.ByteString m r -> Producer' B.ByteString m r
fromStreamingByteString = loop where
  loop stream = case stream of -- this should be rewritten without constructors
    Q.Empty r      -> PI.Pure r
    Q.Go m         -> PI.M (liftM loop m)
    Q.Chunk a rest -> PI.Respond a  (\_ -> loop rest)
{-# INLINABLE fromStreamingByteString #-}



{-| 'span' splits a 'Producer' into two 'Producer's; the outer 'Producer' 
    is the longest consecutive group of elements that satisfy the predicate.
    Its inverse is 'Control.Monad.join'
-}
span :: Monad m => (a -> Bool) -> Producer a m r -> Producer a m (Producer a m r)
span predicate = loop where
  loop p = do
    e <- lift (next p)
    case e of
      Left   r      -> return (return r)
      Right (a, p') ->
          if predicate a
          then yield a >> loop p'
          else return (yield a >> p')
{-# INLINABLE span #-}



{-| 'break' splits a 'Producer' into two 'Producer's; the outer 'Producer' 
    is the longest consecutive group of elements that fail the predicate.
    Its inverse is 'Control.Monad.join'
-}
break :: Monad m => (a -> Bool) -> Producer a m r -> Producer a m (Producer a m r)
break predicate = span (not . predicate)

split :: (Eq a, Monad m) =>
      a -> Producer a m r -> Stream (Producer a m) m r
split t  = loop  where
  loop stream = do
    e <- lift $ next stream
    case e of
      Left   r      ->  SI.Return r
      Right (a, p') -> 
        if a /= t
          then SI.Step $ fmap loop (yield a >> span (/= t) p')
          else loop p'
{-#INLINABLE split #-}

breaks :: (Eq a, Monad m) =>
      (a -> Bool) -> Producer a m r -> Stream (Producer a m) m r
breaks predicate  = loop  where
  loop stream = do
    e <- lift $ next stream
    case e of
      Left   r      ->  SI.Return r
      Right (a, p') -> 
        if not (predicate a)
          then SI.Step $ fmap loop (yield a >> break (predicate) p')
          else loop p'
{-#INLINABLE breaks #-}

{-| 'splitAt' divides a 'Producer' into two 'Producer's 
    after a fixed number of elements. Its inverse is 'Control.Monad.join'

-}
splitAt
    :: Monad m
    => Int -> Producer a m r -> Producer a m (Producer a m r)
splitAt = loop where 
  loop n p | n <= 0 = return p
  loop n p = do
    e <- lift (next p)
    case e of
      Left   r      -> return (return r)
      Right (a, p') -> yield a >> loop (n - 1) p'
{-# INLINABLE splitAt #-}

{-| 'groupBy' splits a 'Producer' into two 'Producer's; the second
     producer begins where we meet an element that is different
     according to the equality predicate. Its inverse is 'Control.Monad.join'
-}
groupBy
    :: Monad m
    => (a -> a -> Bool) -> Producer a m r -> Producer a m (Producer a m r)
groupBy equals = loop where
  loop p = do
    x <- lift (next p)
    case x of
      Left   r      -> return (return r)
      Right (a, p') -> span (equals a) (yield a >> p') 
{-# INLINABLE groupBy #-}

-- | Like 'groupBy', where the equality predicate is ('==')
group
    :: (Monad m, Eq a) => Producer a m r -> Producer a m (Producer a m r)
group = groupBy (==)
{-# INLINABLE group #-}

{-| 'groupsBy' splits a 'Producer' into a 'Stream' of 'Producer's of equal items.
    Its inverse is 'concats'
-}
groupsBy
    :: Monad m
    => (a -> a -> Bool)
    -> Producer a m r -> Stream (Producer a m) m r 
groupsBy equals = loop where
  loop p = SI.Effect $ do
    e <- next p
    return $ case e of
      Left   r      -> SI.Return r
      Right (a, p') -> SI.Step (fmap loop (yield a >> span (equals a) p'))
{-# INLINABLE groupsBy #-}

{-| @groupsBy'@ splits a 'Producer' into a 'Stream' of 'Producer's grouped using
    the given relation. Its inverse is 'concats'

    This differs from 'groupsBy' by comparing successive elements
    instead of comparing each element to the first member of the group

>>> import Pipes (yield, each)
>>> import Pipes.Prelude (toList)
>>> let rel c1 c2 = succ c1 == c2
>>> (toList . intercalates (yield '|') . groupsBy' rel) (each "12233345")
"12|23|3|345"
>>> (toList . intercalates (yield '|') . groupsBy  rel) (each "12233345")
"122|3|3|34|5"
-}
groupsBy'
    :: Monad m
    => (a -> a -> Bool) -> Producer a m r -> Stream (Producer a m) m r
groupsBy' equals = loop where
  loop p = SI.Effect $ do
    e <- next p
    return $ case e of
      Left   r      -> SI.Return r
      Right (a, p') -> SI.Step (fmap loop (loop0 (yield a >> p')))
  loop0 p1 = do
    e <- lift (next p1)
    case e of
        Left   r      -> return (return r)
        Right (a2, p2) -> do
            yield a2
            let loop1 a p = do
                    e' <- lift (next p)
                    case e' of
                        Left   r      -> return (return r)
                        Right (a', p') ->
                            if equals a a'
                            then do
                                yield a'
                                loop1 a' p'
                            else return (yield a' >> p')
            loop1 a2 p2
{-# INLINABLE groupsBy' #-}

groups:: (Monad m, Eq a)
    =>  Producer a m r -> Stream (Producer a m) m r
groups = groupsBy (==)


{-| 'chunksOf' splits a 'Producer' into a 'Stream' of 'Producer's of a given length.
    Its inverse is 'concats'.

>>> let listN n = L.purely P.folds L.list . P.chunksOf n
>>> runEffect $ listN 3 P.stdinLn >-> P.take 2 >-> P.map unwords >-> P.print
1<Enter>
2<Enter>
3<Enter>
"1 2 3"
4<Enter>
5<Enter>
6<Enter>
"4 5 6"
>>> let stylish = P.concats . P.maps (<* P.yield "-*-") . P.chunksOf 2
>>> runEffect $ stylish (P.each $ words "one two three four five six") >-> P.stdoutLn
one
two
-*-
three
four
-*-
five
six
-*-

-}

chunksOf
    :: Monad m => Int -> Producer a m r -> Stream (Producer a m) m r
chunksOf n = loop where
  loop p = SI.Effect $ do
    e <- next p
    return $ case e of
      Left   r      -> SI.Return r
      Right (a, p') -> SI.Step (fmap loop (splitAt n (yield a >> p')))
{-# INLINABLE chunksOf #-}

-- | Join a stream of 'Producer's into a single 'Producer'
concats :: Monad m => Stream (Producer a m) m r -> Producer a m r
concats = loop where
  loop stream = case stream of
    SI.Return r -> return r
    SI.Effect m -> PI.M $ liftM loop m
    SI.Step p -> do 
      rest <- p
      loop rest 
{-# INLINABLE concats #-}

-- {-| Join a 'FreeT'-delimited stream of 'Producer's into a single 'Producer' by
--     intercalating a 'Producer' in between them
-- -}
-- intercalates
--     :: Monad m => Producer a m () -> Stream (Producer a m) m r -> Producer a m r
-- intercalates sep = loop where
--   loop stream = case stream of
--
--       x <- lift (runFreeT f)
--       case x of
--           Pure r -> return r
--           Free p -> do
--               f' <- p
--               go1 f'
--   go1 f = do
--       x <- lift (runFreeT f)
--       case x of
--           Pure r -> return r
--           Free p -> do
--               sep
--               f' <- p
--               go1 f'
-- {-# INLINABLE intercalates #-}

{- $folds
    These folds are designed to be compatible with the @foldl@ library.  See
    the 'Control.Foldl.purely' and 'Control.Foldl.impurely' functions from that
    library for more details.

    For example, to count the number of 'Producer' layers in a 'Stream', you can
    write:

> import Control.Applicative (pure)
> import qualified Control.Foldl as L
> import Pipes.Group
> import qualified Pipes.Prelude as P
>
> count :: Monad m => Stream (Producer a m) m () -> m Int
> count = P.sum . L.purely folds (pure 1)
-}

{-| Fold each 'Producer' in a producer 'Stream'

> purely folds
>     :: Monad m => Fold a b -> Stream (Producer a m) m r -> Producer b m r
-}

folds
    :: Monad m
    => (x -> a -> x)
    -- ^ Step function
    -> x
    -- ^ Initial accumulator
    -> (x -> b)
    -- ^ Extraction function
    -> Stream (Producer a m) m r
    -- ^
    -> Producer b m r
folds step begin done = loop where
  loop stream = case stream of 
    SI.Return r -> return r
    SI.Effect m  -> PI.M $ liftM loop m
    SI.Step p   -> do
        (stream', b) <- lift (fold p begin)
        yield b
        loop stream'
  fold p x = do
      y <- next p
      case y of
          Left   f      -> return (f, done x)
          Right (a, p') -> fold p' $! step x a
{-# INLINABLE folds #-}



{-| Fold each 'Producer' in a 'Producer' stream, monadically

> impurely foldsM
>     :: Monad m => FoldM a b -> Stream (Producer a m) m r -> Producer b m r
-}
foldsM
    :: Monad m
    => (x -> a -> m x)
    -- ^ Step function
    -> m x
    -- ^ Initial accumulator
    -> (x -> m b)
    -- ^ Extraction function
    -> Stream (Producer a m) m r
    -- ^
    -> Producer b m r
foldsM step begin done = loop where
  loop stream = case stream of 
    SI.Return r -> return r
    SI.Effect m -> PI.M (liftM loop m)
    SI.Step p -> do
      (f', b) <- lift $ begin >>=  foldM p 
      yield b
      loop f'

  foldM p x = do
    y <- next p
    case y of
      Left   f      -> do
          b <- done x
          return (f, b)
      Right (a, p') -> do
          x' <- step x a
          foldM p' $! x'
{-# INLINABLE foldsM #-}

{-| @(takes' n)@ only keeps the first @n@ 'Producer's of a linked 'Stream' of 'Producers'

    Unlike 'takes', 'takes'' is not functor-general - it is aware that a 'Producer'
    can be /drained/, as functors cannot generally be. Here, then, we drain 
    the unused 'Producer's in order to preserve the return value.  
    This makes it a suitable argument for 'maps'.
-}
takes' :: Monad m => Int -> Stream (Producer a m) m r -> Stream (Producer a m) m r
takes' = loop where
  
  loop !n stream | n <= 0 = drain_loop stream
  loop n stream = case stream of
    SI.Return r -> SI.Return r
    SI.Effect  m -> SI.Effect (liftM (loop n) m)
    SI.Step p   -> SI.Step  (fmap (loop (n - 1)) p)

  drain_loop stream = case stream of
    SI.Return r -> SI.Return r
    SI.Effect  m -> SI.Effect (liftM drain_loop m)
    SI.Step p   -> SI.Effect $ do 
      stream' <- runEffect (P.for p P.discard)
      return $ drain_loop stream'
{-# INLINABLE takes' #-}

