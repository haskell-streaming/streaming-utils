# streaming-utils
experimental http, attoparsec and pipes material for `streaming` and `streaming-bytestring`

`Streaming.Pipes` reimplements some of the standard pipes splitting and joining operations with `Stream` in place of @FreeT`. The operations are all plain functions, not lenses, so they will be simpler to use, unless of course you are using pipes' StateT parsing. Another module is planned to recover this.

`streaming bytestring` just replicates `Pipes.HTTP` (barely a character is changed) so that exchange
is via `ByteString m r` rather than @Producer ByteString m r`.

`Streaming.Attoparsec` pretty much replicates Renzo Carbonara's `Pipes.Attoparsec` module.
