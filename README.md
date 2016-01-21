# streaming-utils

*http, json, attoparsec and pipes material for* `streaming` *and* `streaming-bytestring`

`Streaming.Pipes` reimplements some of the standard pipes splitting and joining operations with `Stream` in place of `FreeT`. The operations are all plain functions, not lenses. They will thus be simpler to use, unless of course you are using pipes' `StateT` parsing. Another module is planned to recover this style of parsing.

`Data.ByteString.Streaming.HTTP` just replicates [`Pipes.HTTP`](https://hackage.haskell.org/package/pipes-http-1.0.2/docs/Pipes-HTTP.html) (barely a character is changed) so that the response takes the form of a `ByteString m ()` rather than `Producer ByteString m ()`.  Something like this is the intuitively correct response type, insofar as a pipes Producer (like a conduit Source and an io-streams InputStream) is properly a succession of independent semantically significant values.

`Data.ByteString.Streaming.Aeson` replicates Renzo Carbonara's [`Pipes.Aeson`](https://hackage.haskell.org/package/pipes-aeson-0.4.1.5/docs/Pipes-Aeson.html). It also includes materials for appying the additional parsers exported by `json-streams` library, which have some advantages for properly streaming applications as is explained in the documentation. 

`Data.Attoparsec.ByteString.Streaming` in turn pretty much replicates Renzo Carbonara's [`Pipes.Attoparsec` module](https://hackage.haskell.org/package/pipes-attoparsec-0.5.1.2/docs/Pipes-Attoparsec.html). It permits parsing an effectful bytestring with an attoparsec parser, and also the conversion of an effectful bytestring into stream of parsed values.

