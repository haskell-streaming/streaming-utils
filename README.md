# streaming-utils

*Experimental http, attoparsec and pipes material for `streaming` and `streaming-bytestring`*

`Streaming.Pipes` reimplements some of the standard pipes splitting and joining operations with `Stream` in place of `FreeT`. The operations are all plain functions, not lenses, so they will be simpler to use, unless of course you are using pipes' `StateT` parsing. Another module is planned to recover this.

`Data.ByteString.Streaming.HTTP` just replicates [`Pipes.HTTP`](https://hackage.haskell.org/package/pipes-http-1.0.2/docs/Pipes-HTTP.html) (barely a character is changed) so that exchange is via `ByteString m r` rather than `Producer ByteString m r`.

`Data.Attoparsec.ByteString.Streaming` pretty much replicates Renzo Carbonara's [`Pipes.Attoparsec` module](https://hackage.haskell.org/package/pipes-attoparsec-0.5.1.2/docs/Pipes-Attoparsec.html). It permits parsing an effectful bytestring with an attoparsec parser, and also the
(streaming) conversion of an effectful bytestring into stream of parsed values.

`Data.ByteString.Streaming.Aeson` replicates Renzo Carbonara's [`Pipes.Aeson`](https://hackage.haskell.org/package/pipes-aeson-0.4.1.5/docs/Pipes-Aeson.html) but also includes materials for appying parsers from `json-streams` library, which have some advantages in a "streaming" context as is explained in the documentation. 
