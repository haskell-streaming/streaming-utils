# streaming-utils

*Experimental http, json, attoparsec and pipes material for `streaming` and `streaming-bytestring`*

`Streaming.Pipes` reimplements some of the standard pipes splitting and joining operations with `Stream` in place of `FreeT`. The operations are all plain functions, not lenses, so they will be simpler to use, unless of course you are using pipes' `StateT` parsing. Another module is planned to recover this.

`Data.ByteString.Streaming.HTTP` just replicates [`Pipes.HTTP`](https://hackage.haskell.org/package/pipes-http-1.0.2/docs/Pipes-HTTP.html) (barely a character is changed) so that the response takes the form of a `ByteString m ()` rather than `Producer ByteString m ()`.  This is the intuitively correct response type. Where `Producer ByteString m ()`, `Conduit.Source m ByteString`, `IOStreams.InputStream ByteString`, etc. are used as the response type, the defective model of the `enumerator` (and here `http-enumerator`) library is followed: the underlying bytestring chunks are treated as semantically significant Haskell values. But they are not semantically significant Haskell values. This mistake is not made where e.g. lazy bytestring is used for responses, and should not be made by streaming libraries.

`Data.ByteString.Streaming.Aeson` replicates Renzo Carbonara's [`Pipes.Aeson`](https://hackage.haskell.org/package/pipes-aeson-0.4.1.5/docs/Pipes-Aeson.html) but also includes materials for appying parsers from `json-streams` library, which have some advantages for properly streaming applications as is explained in the documentation. 

`Data.Attoparsec.ByteString.Streaming` pretty much replicates Renzo Carbonara's [`Pipes.Attoparsec` module](https://hackage.haskell.org/package/pipes-attoparsec-0.5.1.2/docs/Pipes-Attoparsec.html). It permits parsing an effectful bytestring with an attoparsec parser, and also the (streaming) conversion of an effectful bytestring into stream of parsed values.

