{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleInstances  #-}
{-# LANGUAGE RankNTypes         #-}
{- | The @encode@, @decode@ and @decoded@ functions replicate 
     the similar functions in Renzo Carbonara's 
     <http://hackage.haskell.org/package/pipes-aeson pipes-aeson> .
     Note that @aeson@ accumulates a whole top level json array or object before coming to any conclusion.
     This is the only default that could cover all cases. 

     The @streamParse@ function accepts parsers from the 
     <http://hackage.haskell.org/package/json-stream json-streams> library.
     The 'json-streams' parsers use aeson types, but will stream suitable elements
     as they arise.  For this reason, of course, it cannot validate the entire json 
     entity before acting, but carries on validation as it moves along, reporting 
     failure when it comes. Though it is generally faster and accumulates less memory than
     the usual aeson parsers, it is by no means a universal replacement for 
     aeson\'s behavior.  It will certainly be sensible, for example, wherever 
     you are executing a left fold over the subordinate elements, e.g. gathering certain
     statistics about them. 

     Here we use a long top level array of objects from 
     <https://raw.githubusercontent.com/ondrap/json-stream/master/benchmarks/json-data/buffer-builder.json a file> 
     @json-streams@ benchmarking directory. Each object in the top level array 
     has a \"friends\" field with an assocated array of friends; each of these has a \"name\".
     Here, we extract the name of each friend of each person recorded in the level array, and
     enumerate them all:

> {-#LANGUAGE OverloadedStrings #-}
> import Streaming
> import qualified Streaming.Prelude as S
> import Data.ByteString.Streaming.HTTP 
> import Data.ByteString.Streaming.Aeson (streamParse)
> import Data.JsonStream.Parser (string, arrayOf, (.:), Parser)
> import Data.Text (Text)
> import Data.Function ((&))
> main = do
>    req <- parseRequest "https://raw.githubusercontent.com/ondrap/json-stream/master/benchmarks/json-data/buffer-builder.json"
>    m <- newManager tlsManagerSettings
>    withHTTP req m $ \resp -> do 
>      let names, friend_names :: Parser Text
>          names = arrayOf ("name" .: string)
>          friend_names = arrayOf ("friends" .: names)
>      responseBody resp                           -- raw bytestream from http-client
>       & streamParse friend_names                 -- find name fields in each sub-array of friends
>       & void                                     -- drop material after any bad parse
>       & S.zip (S.each [1..])                     -- number the friends' names
>       & S.print                                  -- successively print to stdout
>
> -- (1,"Joyce Jordan")
> -- (2,"Ophelia Rosales")
> -- (3,"Florine Stark")
> -- ...
> -- (287,"Hilda Craig")
> -- (288,"Leola Higgins")

   This program does not accumulate the whole byte stream, as an aeson parser 
   for a top-level json entity would. Rather it streams and enumerates 
   friends\' names as soon as they come. With appropriate instances, we could
   of course just stream the objects in the top-level array instead. 

-}


module Data.ByteString.Streaming.Aeson
  ( DecodingError(..)
  , encode
  , decode
  , decoded
  , streamParse
  ) where
import           Control.Exception                (Exception)
import           Control.Monad.Trans
import qualified Control.Monad.Trans.State.Strict as S
import           Control.Monad.Trans.State.Strict (StateT(..))

import qualified Data.Aeson                       as Ae
import qualified Data.Attoparsec.ByteString       as Attoparsec
import qualified Data.ByteString                  as S
import qualified Data.ByteString.Internal         as S (isSpaceWord8)
import           Data.Data                        (Data, Typeable)
-- import           Pipes
import qualified Data.Attoparsec.ByteString.Streaming  as PA
import           Data.ByteString.Streaming 
import Data.ByteString.Streaming.Internal
import qualified Data.ByteString.Streaming as B
import Streaming
import Streaming.Internal (Stream(..))
import Streaming.Prelude (yield)
import qualified Data.JsonStream.Parser as J
import Data.JsonStream.Parser (ParseOutput (..))
--------------------------------------------------------------------------------
-- | An error while decoding a JSON value.

type ParsingError = ([String],String)

data DecodingError
  = AttoparsecError ParsingError
    -- ^An @attoparsec@ error that happened while parsing the raw JSON string.
  | FromJSONError String
    -- ^An @aeson@ error that happened while trying to convert a
    -- 'Data.Aeson.Value' to an 'A.FromJSON' instance, as reported by
    -- 'Data.Aeson.Error'.
  deriving (Show, Eq, Data, Typeable)

instance Exception DecodingError

-- | This instance allows using 'Pipes.Lift.errorP' with 'Pipes.Aeson.decoded'
-- and 'Pipes.Aeson.decodedL'
-- instance Error (DecodingError, Producer a m r)

--------------------------------------------------------------------------------

-- | Consecutively parse 'a' elements from the given 'Producer' using the given
-- parser (such as 'Pipes.Aeson.decode' or 'Pipes.Aeson.parseValue'), skipping
-- any leading whitespace each time.
--
-- This 'Producer' runs until it either runs out of input or until a decoding
-- failure occurs, in which case it returns 'Left' with a 'DecodingError' and
-- a 'Producer' with any leftovers. You can use 'Pipes.Lift.errorP' to turn the
-- 'Either' return value into an 'Control.Monad.Trans.Error.ErrorT'
-- monad transformer.


-- | Like 'Pipes.Aeson.encode', except it accepts any 'Ae.ToJSON' instance,
-- not just 'Ae.Array' or 'Ae.Object'.
encode :: (Monad m, Ae.ToJSON a) => a -> ByteString m ()
encode = fromLazy . Ae.encode


{-| Given a bytestring, parse a top level json entity - returning any leftover
    bytes. 
-}
decode
  :: (Monad m, Ae.FromJSON a)
  => StateT (ByteString m x) m (Either DecodingError a)
decode = do
      mev <- StateT (PA.parse Ae.json')
      return $ case mev of
         Right l      -> Left (AttoparsecError l)
         Left v -> case Ae.fromJSON v of
            Ae.Error e   -> Left (FromJSONError e)
            Ae.Success a -> Right a

{-| Resolve a succession of top-level json items into a corresponding stream of Haskell
    values. 
            
-}
decoded  :: (Monad m, Ae.FromJSON a) =>
     ByteString m r
     -> Stream (Of a) m (Either (DecodingError, ByteString m r) r)
decoded = consecutively decode 
  where
  consecutively
    :: (Monad m)
    => StateT (ByteString m r) m (Either e a)
    -> ByteString m r  
    -> Stream (Of a) m (Either (e, ByteString m r) r)
  consecutively parser = step where
    step p0 = do
      x <- lift $ nextSkipBlank p0
      case x of
        Left r -> Return (Right r)
        Right (bs, p1) -> do
          (mea, p2) <- lift $ S.runStateT parser (Chunk bs p1)
          case mea of
            Right a -> do 
              yield a
              step p2
            Left  e -> Return (Left (e, p2))

  
  nextSkipBlank p0 = do
        x <- nextChunk p0
        case x of
           Left  _      -> return x
           Right (a,p1) -> do
              let a' = S.dropWhile S.isSpaceWord8 a
              if S.null a' then nextSkipBlank p1
                           else return (Right (a', p1))

{- | Experimental. Parse a bytestring with a @json-streams@ parser. 
     The function will read through
     the whole of a single top level json entity, streaming the valid parses as they
     arise. (It will thus for example parse an infinite json bytestring, though these
     are rare in practice ...) 
                           
     If the parser is fitted to recognize only one thing, 
     then zero or one item will be yielded; if it uses combinators like @arrayOf@, 
     it will stream many values as they arise. See the example at the top of this module,
     in which values inside a top level array are emitted as they are parsed. Aeson would
     accumulate the whole bytestring before declaring on the contents of the array.
     This of course makes sense, since attempt to parse a json array may end with 
     a bad parse, invalidating the json as a whole.  With @json-streams@, a bad 
     parse will also of course emerge in the end, but only after the initial good parses
     are streamed. This too makes sense though, but in a smaller range of contexts 
     -- for example, where one is folding over the parsed material.
      
                           
     This function is closely modelled on 
     'Data.JsonStream.Parser.parseByteString' and 
     'Data.JsonStream.Parser.parseLazyByteString' from @Data.JsonStream.Parser@.
                           
      -}
streamParse
  :: (Monad m) =>
     J.Parser a
     -> ByteString m r 
     -> Stream (Of a) m (Maybe String, ByteString m r)
streamParse parser input = loop input (J.runParser parser)  where
  loop bytes p0 = case p0 of 
    ParseFailed s -> return (Just s,bytes)
    ParseDone bs  -> return (Nothing, chunk bs >> bytes)
    ParseYield a p1 -> yield a >> loop bytes p1
    ParseNeedData f -> do 
       e <- lift $ nextChunk bytes
       case e of
         Left r    -> return (Just "Not enough data",return r)
         Right (bs, rest) -> loop rest (f bs)

                           