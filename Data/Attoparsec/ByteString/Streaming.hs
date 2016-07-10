{- | Here is a simple use of 'parsed' and standard @Streaming@ segmentation devices to 
     parse a file in which groups of numbers are separated by blank lines. Such a problem
     of \'nesting streams\' is described in the @conduit@ context in 
     <http://stackoverflow.com/questions/32957258/how-to-model-nested-streams-with-conduits/32961296 this StackOverflow question> 

> -- $ cat nums.txt
> -- 1
> -- 2
> -- 3
> --
> -- 4
> -- 5
> -- 6
> --
> -- 7
> -- 8

   We will sum the groups and stream the results to standard output:

> import Streaming
> import qualified Streaming.Prelude as S
> import qualified Data.ByteString.Streaming.Char8 as Q
> import qualified Data.Attoparsec.ByteString.Char8 as A
> import qualified Data.Attoparsec.ByteString.Streaming as A
> import Data.Function ((&))
>
> main = Q.getContents           -- raw bytes
>        & A.parsed lineParser   -- stream of parsed `Maybe Int`s; blank lines are `Nothing`
>        & void                  -- drop any unparsed nonsense at the end
>        & S.split Nothing       -- split on blank lines
>        & S.maps S.concat       -- keep `Just x` values in the sub-streams (cp. catMaybes)
>        & S.mapped S.sum        -- sum each substream
>        & S.print               -- stream results to stdout
>
> lineParser = Just <$> A.scientific <* A.endOfLine <|> Nothing <$ A.endOfLine

> -- $ cat nums.txt | ./atto
> -- 6.0
> -- 15.0
> -- 15.0

-} 
module Data.Attoparsec.ByteString.Streaming
    (Message
    , parse
    , parsed
--    , module Data.Attoparsec.ByteString
    )
    where

import qualified Data.ByteString as B
import qualified Data.Attoparsec.ByteString as A
import qualified Data.Attoparsec.Internal.Types as T
import Data.Attoparsec.ByteString
    hiding (IResult(..), Result, eitherResult, maybeResult,
            parse, parseWith, parseTest)

import Streaming hiding (concats, unfold)
import Streaming.Internal (Stream (..))
import Data.ByteString.Streaming
import Data.ByteString.Streaming.Internal
import Data.Monoid 

type Message = ([String], String)

{- | The result of a parse (@Either a ([String], String)@), with the unconsumed byte stream.

>>> :set -XOverloadedStrings  -- the string literal below is a streaming bytestring
>>> (r,rest1) <- AS.parse (A.scientific <* A.many' A.space) "12.3  4.56  78.3" 
>>> print r
Left 12.3
>>> (s,rest2) <- AS.parse (A.scientific <* A.many' A.space) rest1
>>> print s
Left 4.56
>>> (t,rest3) <- AS.parse (A.scientific <* A.many' A.space) rest2
>>> print t
Left 78.3
>>> Q.putStrLn rest3

-}
parse :: Monad m 
      => A.Parser a 
      -> ByteString m x -> m (Either a Message, ByteString m x)
parse p s  = case s of
    Chunk x xs -> go (A.parse p x) xs
    Empty r    -> go (A.parse p B.empty) (Empty r)
    Go m       -> m >>= parse p
  where
  go (T.Fail x stk msg) ys      = return $ (Right (stk, msg), Chunk x ys)
  go (T.Done x r) ys            = return $ (Left r, Chunk x ys)
  go (T.Partial k) (Chunk y ys) = go (k y) ys
  go (T.Partial k) (Go m)       = m >>= go (T.Partial k)
  go (T.Partial k) blank        = go (k B.empty) blank


{-| Apply a parser repeatedly to a stream of bytes, streaming the parsed values, but 
    ending when the parser fails.or the bytes run out.

>>> S.print $ AS.parsed (A.scientific <* A.many' A.space) $ "12.3  4.56  78.9"
12.3
4.56
78.9
18.282

-}
parsed
  :: Monad m
  => A.Parser a     -- ^ Attoparsec parser
  -> ByteString m r -- ^ Raw input
  -> Stream (Of a) m (Either (Message, ByteString m r) r)
parsed parser = go
  where
    go p0 = do
      x <- lift (nextChunk p0)
      case x of
        Left r       -> Return (Right r)
        Right (bs,p1) -> step (chunk bs >>) (A.parse parser bs) p1
    step diffP res p0 = case res of
      A.Fail _ c m -> Return (Left ((c,m), diffP p0))
      A.Done bs b  -> Step (b :> go (chunk bs >> p0))
      A.Partial k  -> do
        x <- lift (nextChunk p0)
        case x of
          Left e -> step diffP (k mempty) (return e)
          Right (a,p1) -> step (diffP . (chunk a >>)) (k a) p1
{-# INLINABLE parsed #-}

-- | Run a parser and return its result, using @StateT (ByteString m x)@ in the style
-- of pipes parse
-- atto :: Monad m => A.Parser a -> StateT (ByteString m x) m (Result a)
-- atto p = StateT (parse p)

-- atto_ :: Monad m => A.Parser a -> ExceptT ([String], String) (StateT (ByteString m x) m) a
-- atto_ p = ExceptT $ StateT loop where
--   loop s  = case s of
--       Chunk x xs -> go (A.parse p x) xs
--       Empty r    -> go (A.parse p B.empty) (Empty r)
--       Go m       -> m >>= loop
--
--   go (T.Fail x stk msg) ys      = return $ (Left (stk, msg), Chunk x ys)
--   go (T.Done x r) ys            = return $ (Right r, Chunk x ys)
--   go (T.Partial k) (Chunk y ys) = go (k y) ys
--   go (T.Partial k) (Go m)       = m >>= go (T.Partial k)
--   go (T.Partial k) blank        = go (k B.empty) blank


