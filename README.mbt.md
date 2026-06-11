# flate

Pure-MoonBit **DEFLATE** (RFC 1951) — a runtime-agnostic, suspendable, io-free
compression engine, with thin **gzip** (RFC 1952) and **zlib** (RFC 1950)
wrappers.
layout

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
           (tokens, ll_freq, d_freq)    ← the seam: any parser/planner
                           │              pair feeds the same writer
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
 (snapshot/rollback retry); trusted input only
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
   status.mbt  Done / NeedMoreInput / NeedMoreOutput
```

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
