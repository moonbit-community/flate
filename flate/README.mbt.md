# flate

Pure-MoonBit **DEFLATE** (RFC 1951) — a runtime-agnostic, suspendable, io-free
compression engine, with **gzip** (RFC 1952), **zlib** (RFC 1950), and
**zip** (APPNOTE.TXT) container wrappers.

CRC-32 and Adler-32 are provided by the `moonbit-community/flate/checksum`
package. It depends only on MoonBit core and is shared by gzip, zlib, and zip.

## Install

```bash
moon add moonbit-community/flate
```

## Quick start

The one-shot API is useful when the complete payload is already in memory.
Read-only codec inputs accept `BytesView`, so a slice of a larger buffer needs
no ownership conversion at the call site:

```mbt check
///|
test "README raw DEFLATE round-trip" {
  let source = b"runtime-agnostic streaming compression"
  let compressed = @flate.deflate_all(source)
  @test.assert_eq(@flate.inflate_all(compressed), source)
}
```

For whole-buffer callers that already own their output storage, use the direct
buffer API. `deflate_bound` supplies a conservative DEFLATE capacity (it panics
for a negative input length or an unrepresentable bound);
compression returns `None` if its encoded output does not fit, while decompression
raises `OutputLimitExceeded` if its decoded output does not fit. Reuse
`Compressor` and `Decompressor` across streams to retain their workspace.

```mbt check
///|
test "README caller-buffer DEFLATE" {
  let source = b"direct input and caller-owned output"
  let compressor = @flate.Compressor(level=6)
  let compressed_buffer = FixedArray::make(
    @flate.deflate_bound(source.length()),
    b'\x00',
  )
  guard compressor.compress_into(source, compressed_buffer)
    is Some(compressed_len) else {
    @test.fail("deflate_bound was too small")
  }
  let compressed = Bytes::from_array(compressed_buffer[:compressed_len])
  let decompressor = @flate.Decompressor()
  let output = FixedArray::make(source.length(), b'\x00')
  let decoded_len = decompressor.decompress_into(compressed, output)
  @test.assert_eq(Bytes::from_array(output[:decoded_len]), source)
}
```

`deflate_into` and `inflate_into` are single-use convenience forms of those
methods. Like `inflate_all`, `inflate_into` ignores trailing bytes after a valid
final DEFLATE block. Use the streaming APIs when input or output must suspend
under backpressure.

`Compressor::compress(input)` returns independent `Bytes` and reuses its
workspace across calls, without requiring a caller-owned output buffer.

The streaming API is a pure push state machine. It owns no I/O object, so both
synchronous and asynchronous callers can supply input and drain output:

```mbt check
///|
test "README streaming Deflater" {
  let source = b"small buffers exercise suspension and resume"
  let encoder = @flate.Deflater()
  let chunk = FixedArray::make(3, b'\x00')
  let compressed = @buffer.Buffer()
  let mut first = true
  for ;; {
    let input = if first { source[:] } else { b"" }
    let status = encoder.step(
      input,
      chunk.mut_view(),
      action=if first { Finish } else { Continue },
    )
    let consumed = encoder.last_consumed()
    let produced = encoder.last_produced()
    @test.assert_eq(consumed, if first { source.length() } else { 0 })
    first = false
    for i in 0..<produced {
      compressed.write_byte(chunk[i])
    }
    if status is Done {
      break
    }
  }
  @test.assert_eq(@flate.inflate_all(compressed.to_bytes()), source)
}
```

### State-machine contract

- `step` returns the state-machine `Status`; `last_consumed()` and
  `last_produced()` describe exactly the prefixes accepted and written by that
  call. Drop only `input[:consumed]`; large input views may be
  partially consumed when output is backpressured, keeping internal memory
  bounded.
- `NeedMoreOutput` preserves all pending work. Resume with another non-empty
  output view; one byte is sufficient.
- `Inflater` owns the bounded tail of an incomplete atomic unit. On
  `NeedMoreInput`, feed the next non-overlapping chunk; no growing replay window
  is required.
- Encoders take one `DeflateAction`: `Continue`, `SyncFlush`, or `Finish`.
  Pass the requested action with the final input of that batch. If
  `consumed < input.length()`, re-present that suffix with the same action. Once
  the complete view is accepted, the request remains latched across output
  backpressure.
- `Inflater::step_into(input, output)` accepts a complete `FixedArray[Byte]`
  and uses bulk window copies. It has the same consumption and backpressure
  semantics as `step`, which accepts arbitrary mutable output views. Both
  release caller buffers after each call.
- gzip and zlib `Decoder::step_into(input, output)` accept a complete
  `FixedArray[Byte]` and checksum decoded output in batches. Use it when the caller owns a fixed
  output buffer; `step` accepts arbitrary mutable views. Both drain pending
  body input before accepting more, so output can be produced while
  `last_consumed()` is zero. Re-present the unaccepted input on the next call.
- Raw `Inflater::step(..., end=true)` and the container decoders turn physical
  EOF before `Done` into a stable truncation error. After any decoder error,
  discard or reset the raw engine; container decoder instances stably rethrow
  the same error.
- Once `Done` is returned, new input is not consumed; reset the raw engine or
  the zlib `Encoder` (`reset(dictionary?)`), or create a new wrapper, before
  reuse. A reset encoder produces exactly the bytes of a freshly constructed
  one with the same options and driving schedule, while reusing its workspace.
- Configure a raw preset dictionary through `Deflater(...)`/`Inflater(...)`, or
  while starting a fresh stream through `reset(dictionary=...)`; dictionary
  selection cannot be mutated after a stream begins.
- gzip/zlib decoders may accept transport read-ahead beyond their trailer;
  after `Done`, recover that suffix with `unused_input()` before parsing the
  next protocol frame. For an exact one-member gzip boundary, construct the
  decoder with `multistream=false`.
- Raw failures expose a stable `InflateErrorKind` (`Truncated`, `Corrupt`,
  `TrailingData`, `OutputLimitExceeded`, or `Cancelled`) alongside diagnostic
  text; gzip/zlib similarly expose `GzipErrorKind`/`ZlibErrorKind`.
- One-shot decoding (`inflate_all`, `inflate_exact`)
  accepts an optional `cancelled` callback, polled at entry and then every
  ~4-8 KiB of decoded output; returning `true` raises
  `InflateError(Cancelled, _)`, so untrusted-input loops can react to
  cancellation without streaming plumbing.

### Exact and bounded one-shot decoding

`inflate_all` remains the convenient trusted-input API: it accepts a raw
DEFLATE prefix and grows its output without a limit. Use `inflate_exact` when the
input must contain exactly one raw stream. Both accept `max_output` to bound
the decoded size:

```mbt check
///|
test "README exact and limited inflate" {
  let source = b"bounded convenience API"
  let compressed = @flate.deflate_all(source)
  @test.assert_eq(@flate.inflate_exact(compressed), source)
  @test.assert_eq(
    @flate.inflate_all(compressed, max_output=source.length()),
    source,
  )
  @test.assert_eq(
    @flate.inflate_exact(compressed, max_output=source.length()),
    source,
  )
}
```

`inflate_exact` combines exact framing with optional bounds: `max_output` caps
the decoded size (raising `OutputLimitExceeded` before any oversized result is
returned; negative limits are rejected), and `preallocated=true` replays the
deterministic decode a second time into one exactly sized allocation. The
preallocated mode trades roughly double the decode work for a peak memory of
about one decoded output (instead of a growing buffer plus a final copy), which
matters for very large single streams. The default stays single-pass for
callers that do not need the memory bound.

## ZIP container

The `@zip` package reads and writes ZIP archives using the same compression
engine. Use `Archive` for in-memory editing and serialization:

```mbt check
///|
test "README zip round-trip" {
  let archive = @zip.Archive()
  archive.add("hello.txt", b"hello, zip")
  let bytes = @zip.write(archive)
  let parsed = @zip.read(bytes)
  @test.assert_eq(parsed.get("hello.txt"), Some(b"hello, zip"))
}
```

Supported features include STORED and DEFLATE entries, ZIP64, data descriptors,
UTF-8 names, and archive comments. `read` accepts `ReadLimits` to bound archive
size, entry count, decompressed sizes, and the complete retained source, plus a
`cancelled` callback. Exceeding a limit raises
`ZipError(LimitExceeded(kind, limit, actual), message)`.

`read` verifies each entry's CRC-32, raising `ChecksumMismatch` for a damaged
payload. Cancellation remains `Cancelled` throughout parsing, decoding and
checksum verification.

`write(archive, preserve=true)` reuses unchanged source records; an unmodified
archive round-trips byte-for-byte, including prefixes, gaps and directory order.
After an edit, local records and directory entries keep their respective order;
bytes outside records, such as prefixes and gaps, are omitted.
`max_preserved_source_bytes` covers the full source, including these bytes.
Supply `max_output_bytes` to bound the serialized size before allocating it.
`write` returns the complete ZIP as `Bytes`.

For incremental output, use `Writer` with a synchronous sink. `add` accepts a
complete file; `begin_entry` / `write` / `end_entry` accept chunks. Supply `size`
when known; unknown sizes use ZIP64.

```mbt check
///|
test "README incremental ZIP writer" {
  // A real folder adapter passes a buffered file-write callback here.
  let output = @buffer.Buffer()
  let writer = @zip.Writer(chunk => output.write_bytes(chunk))
  writer.add("small.txt", b"small file")
  writer.begin_entry("chunked.txt", size=6UL)
  writer.write(b"abc")
  writer.write(b"def")
  writer.end_entry()
  writer.finish()
  let archive = @zip.read(output.to_bytes())
  @test.assert_eq(archive.get("chunked.txt"), Some(b"abcdef"))
}
```

Call `finish` to write the central directory. The sink must consume each chunk
before returning. If it raises an error, the writer becomes unusable and the
partial output must be discarded.

`Writer` retains directory metadata, current-entry metadata and codec buffers.
`add` processes a complete file during the call; `write` feeds chunks through
the codec or directly to the sink. Folder traversal and file I/O belong to
the caller.

## Architecture

The raw engine shares Huffman construction, block writing and format validation
across its encoding and decoding paths:

| Path | Implementation |
| --- | --- |
| Whole-buffer compression | `deflate_all.mbt`, `lz77.mbt` |
| Streaming compression | `deflate.mbt`, `block_planner.mbt`, `lz77.mbt` |
| Content-driven block splitting | `split_plan.mbt` |
| Iterated optimal parsing and splitting | `optimal_parse.mbt`, `optimal_plan.mbt` |
| Block encoding and bit output | `block_writer.mbt`, `huffman_build.mbt`, `bitwriter.mbt` |
| Whole-buffer decompression | `inflate_all.mbt` |
| Streaming decompression | `inflate.mbt` |
| Shared decoding tables and validation | `huffman_table.mbt`, `tables.mbt`, `decode_rules.mbt` |

Unbounded `inflate_all` uses the direct `MemDecoder` path. Bounded
`inflate_all` and `inflate_exact` drive the streaming inflater.
`Decompressor::decompress_into` uses the direct decoder with caller-owned output.
Differential tests compare one-shot and streaming decoding across randomized
chunk/output schedules, truncations and bit flips.

The gzip and zlib packages add framing, checksums and streaming wrappers.
ZIP provides in-memory archives and a synchronous incremental writer.
The checksum package supplies CRC-32 and Adler-32 independently of the codecs.

## Optional fast stored blocks

`fast_store=true` opts into a heuristic speed/ratio trade-off. It samples byte
variety, frequency skew and local repetition; small inputs also get a periodicity
check. Inputs below 1 KiB skip the classifier. A candidate judged unlikely to compress is emitted as DEFLATE stored
blocks without match search or Huffman construction. The default is `false`:
existing calls retain their normal compression behavior.

```moonbit nocheck
///|
let codec = @flate.Compressor(level=6, fast_store=true)

///|
let raw = @flate.deflate_all(input, fast_store=true)

///|
let stream = @flate.Deflater(level=6, fast_store=true)

///|
let archive_bytes = @zip.write(archive, fast_store=true)
```

The option is also available on `deflate_into`, split/optimal convenience APIs,
gzip/zlib compression functions and streaming encoders, all ZIP serialization
functions, and `zip.Writer`. Whole-buffer APIs classify the entire input;
streaming encoders decide per block and retain stored bytes as match history.
ZIP entries declared `Deflate` remain method 8; this option selects stored blocks
inside DEFLATE, rather than changing the entry to ZIP method 0. Preserved ZIP
payloads are reused; record offsets may be patched.

This is **not a proof of incompressibility**. Long repeated patterns or useful
dictionary matches can be missed, potentially making output much larger. Enable
it only when that compression-ratio trade-off is acceptable. Decoding remains
lossless, and the normal output bounds and output limits still apply.

## Effort tiers

All standard DEFLATE on the wire. Levels 0-9 are available on
`deflate_all` / `Deflater`. The default level 6 uses distance-aware lazy
matching and a sampled minimum match length; the other levels retain their
zlib-derived tuning. Whole-buffer compression uses 65,535-byte block targets,
while streaming keeps its bounded 16 KiB input blocks. `deflate_all_split`
tokenizes each input range once with the full 32 KB history and cuts blocks
where the literal/match observation distribution drifts (libdeflate's
observation-divergence splitter, `split_plan.mbt`), arbitrating each chunk
against fixed-cadence cuts using estimated block costs. `deflate_all_optimal`
adds zopfli-style iterated optimal parsing (`optimal_parse.mbt`) plus
content-driven block splitting (`optimal_plan.mbt`). Both paths use the shared
block writer. Output size depends on the input and chosen parsing strategy.

The containers expose both tiers: `@gzip.compress` / `@zlib.compress` and their
streaming `Encoder`s take `level` 0-9; `@gzip.compress_optimal` /
`@zlib.compress_optimal` apply the offline zopfli path (one-shot only — a
streaming encoder cannot suspend a whole-input optimal parse), for
compress-once, serve-forever artifacts.

## API conventions

Read-only inputs accept `BytesView`; existing `Bytes` values convert at the
call site without copying. `Compressor::compress` and `compress_into` reuse
workspace for repeated streams, and `@checksum.adler32` accepts views directly.

Both `inflate_all` and `inflate_exact` take a plain optional integer ceiling:
`max_output=n`. Omit it for unbounded output. `inflate_all` accepts a raw stream
prefix; `inflate_exact` rejects trailing bytes.

ZIP writing uses `write(archive, preserve=true, max_output_bytes=n)` for
byte-preserving, bounded output. The options are independent. Construct read
bounds with `ReadLimits(max_entries=..., max_package_bytes=...,
max_entry_uncompressed_bytes=..., max_total_uncompressed_bytes=...,
max_preserved_source_bytes=...)`.

Internal format and tuning constants are private. Use `deflate_bound` to size
compression output. Filename-based compression selection belongs to the caller;
the CLI supplies its own policy.

ZIP payload CRC and gzip FHCRC are verified. A damaged checksum raises
`ChecksumMismatch`; malformed ZIP DEFLATE data raises `InvalidDeflate`, and
cancellation during ZIP decompression remains `Cancelled`.
`deflate_bound` rejects negative or unrepresentable capacities.

Use `!=` for inequality and `@debug.Repr(value)` for debugging.
