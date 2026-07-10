# flate

Pure-MoonBit **DEFLATE** (RFC 1951) — a runtime-agnostic, suspendable, io-free
compression engine, with thin **gzip** (RFC 1952) and **zlib** (RFC 1950)
wrappers.

## Install

```bash
moon add moonbit-community/flate
```

## Quick start

The one-shot API is useful when the complete payload is already in memory:

```mbt check
///|
test "README raw DEFLATE round-trip" {
  let source = b"runtime-agnostic streaming compression"
  let compressed = @flate.deflate_all(source)
  assert_eq(@flate.inflate_all(compressed), source)
}
```

The streaming API is a pure push state machine. It owns no I/O object, so both
an async event loop and a future synchronous reader/writer adapter can feed and
drain the same engine with whatever buffers their runtime provides:

```mbt check
///|
test "README streaming Deflater" {
  let source = b"small buffers exercise suspension and resume"
  let encoder = @flate.Deflater::new()
  let chunk = FixedArray::make(3, b'\x00')
  let compressed = Buffer()
  let mut first = true
  for ;; {
    let input = if first { source[:] } else { b""[:] }
    let status = encoder.step(
      input,
      chunk.mut_view(),
      action=if first { Finish } else { Continue },
    )
    let consumed = encoder.last_consumed()
    let produced = encoder.last_produced()
    assert_eq(consumed, if first { source.length() } else { 0 })
    first = false
    for i in 0..<produced {
      compressed.write_byte(chunk[i])
    }
    if status is Done {
      break
    }
  }
  assert_eq(@flate.inflate_all(compressed.to_bytes()), source)
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
- Raw `Inflater::step(..., end=true)` and the container decoders turn physical
  EOF before `Done` into a stable truncation error. After any decoder error,
  discard or reset the raw engine; container decoder instances stably rethrow
  the same error.
- Once `Done` is returned, new input is not consumed; reset the raw engine or
  create a new wrapper before reuse.
- Configure a raw preset dictionary through `Deflater::new`/`Inflater::new`, or
  while starting a fresh stream through `reset(dictionary=...)`; dictionary
  selection cannot be mutated after a stream begins.
- gzip/zlib decoders may accept transport read-ahead beyond their trailer;
  after `Done`, recover that suffix with `unused_input()` before parsing the
  next protocol frame. For an exact one-member gzip boundary, construct the
  decoder with `multistream=false`.
- Raw failures expose a stable `InflateErrorKind` (`Truncated`, `Corrupt`,
  `TrailingData`, or `OutputLimitExceeded`) alongside diagnostic text; gzip/zlib
  similarly expose `GzipErrorKind`/`ZlibErrorKind`.

### Exact and bounded one-shot decoding

`inflate_all` remains the convenient trusted-input API: it accepts a raw
DEFLATE prefix and grows its output without a limit. Use `inflate_exact` when the
input must contain exactly one raw stream, and `inflate_all_limited` when decoded
size must be bounded:

```mbt check
///|
test "README exact and limited inflate" {
  let source = b"bounded convenience API"
  let compressed = @flate.deflate_all(source)
  assert_eq(@flate.inflate_exact(compressed), source)
  assert_eq(
    @flate.inflate_all_limited(compressed, max_output=source.length()),
    source,
  )
}
```

## Architecture

```
ENCODE: bytes → raw DEFLATE
═══════════════════════════

 deflate_all     Deflater::step             deflate_all_optimal(input)
  one-shot         streaming, suspendable;    one-shot, offline (zopfli-style)
  greedy           sync flush, preset dict
        │              │                           │
        └──────┬───────┘                           │
               ▼                                    ▼
 ┌─ parser ─────────────────┐    ┌─ parser ───────────────────┐
 │ lz77.mbt                 │    │ optimal_parse.mbt          │
 │ greedy/lazy hash chains  │    │ squeeze: iterated          │
 │ (levels 1-9; 0 = stored) │    │ cost-optimal shortest path │
 ├─ block driver ───────────┤    ├─ planner ──────────────────┤
 │ block_planner.mbt (strm) │    │ optimal_plan.mbt           │
 │ or deflate_all.mbt inline│    │ content-driven splitting   │
 │ both: 16 KB blocks       │    │ (FindMinimum + resplit)    │
 └────────────┬─────────────┘    └─────────────┬──────────────┘
              └────────────┬───────────────────┘
                           ▼
           packed tokens + caller-owned frequencies
                           │              ← the seam: any parser/planner
                           │                pair feeds the same writer
                           ▼
           block_writer.mbt  ◄──  huffman_build.mbt
           one block: stored /      (package-merge length-limited
           fixed / dynamic,          canonical codes)
           whichever is smallest
                           │
                           ▼
           bitwriter.mbt (LSB-first)  →  raw DEFLATE bit stream


DECODE: raw DEFLATE → bytes
═══════════════════════════

           raw DEFLATE bit stream
                    │
           huffman_table.mbt — code lengths → zlib-style chunked tables
                    │
        ┌───────────┴─────────────┐
        ▼                         ▼
 Inflater::step             inflate_all
 (inflate.mbt)              (inflate_all.mbt)
 streaming, suspendable     one-shot, growable output —
 (internal atomic staging); trusted input only
 32 KB window, 1-byte
 output progress,
 preset dictionary


CONTAINERS: thin framing over the engine
════════════════════════════════════════

 gzip/  Encoder/Decoder, gzip_compress/gunzip            (RFC 1952)
        10 B header (optional fields skipped in O(1)) + CRC-32 + ISIZE;
        decodes concatenated multi-member streams (§2.2)
 zlib/  Encoder/Decoder, zlib_compress/zlib_decompress   (RFC 1950)
        2 B header (+ FDICT dictionary id) + Adler-32
 checksum/  incremental CRC-32 / Adler-32 digests

 shared by both pipelines:
   tables.mbt  RFC 1951 symbol tables, fixed codes, window size
   decode_rules.mbt  pure distance/count/stored-block/history validation shared
                     by the one-shot and streaming decoders
   status.mbt  Done / NeedMoreInput / NeedMoreOutput
```

`inflate_all` intentionally keeps its direct, growable-output `MemDecoder` fast
path instead of paying the streaming state machine's staging and circular-window
costs. Both decoders call the same pure RFC validation rules, and a deterministic
differential-fuzz suite checks them across randomized chunk/output schedules,
truncations, and bit flips.

## Effort tiers

All standard DEFLATE on the wire. Levels 0-9 (zlib's tuning table) on
`deflate_all` / `Deflater`; `deflate_all_optimal` adds zopfli-style iterated
optimal parsing (`optimal_parse.mbt`) plus content-driven block splitting
(`optimal_plan.mbt`) — drop-in replacements for the greedy parser (`lz77.mbt`)
and the threshold planner (`block_planner.mbt`) behind the same
(tokens, frequencies) → `emit_block` seam.

The containers expose both tiers: `gzip_compress` / `zlib_compress` and their
streaming `Encoder`s take `level` 0-9; `gzip_compress_optimal` /
`zlib_compress_optimal` apply the offline zopfli path (one-shot only — a
streaming encoder cannot suspend a whole-input optimal parse), for
compress-once, serve-forever artifacts.
