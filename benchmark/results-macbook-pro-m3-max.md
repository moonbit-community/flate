# MacBook Pro M3 Max Results

A subsequent [complete-match decode study](./decode-fastloop-20260910.md)
compares the next optimization against a frozen baseline. The paired libdeflate
tables below retain their original run and do not include that later change.

Latest paired run: **2026-09-10 07:47 UTC** (15:47 Asia/Shanghai).
This is a snapshot of the current worktree, including the match-copy and Huffman
optimizations. Older results remain in Git history.

## Environment and method

- Apple M3 Max, 16 CPU cores, macOS 26.6.2 arm64.
- flate `8316883` **plus uncommitted changes** in `inflate_all.mbt`
  and `huffman_build.mbt`, and their new tests; native release. The run saves
  the source diff, exact source files and hashes, including untracked tests.
- Moon `0.1.20260904`; moonc `0.10.12+1634b282e`.
- Homebrew libdeflate `1.25`; C runner built with Apple Clang 21,
  `-O3 -DNDEBUG`.
- Quick suite, **5 rounds, >=100 ms per final batch**, alternating execution order.
  32 configurations, 960 samples; elapsed 287.4 seconds.
- Both decoders validated both producers' fixtures; Python zlib independently
  validated complete streams. No timed workloads ran concurrently.

```sh
python3 benchmark/run.py --profile quick --rounds 5 --milliseconds 100
```

Rates below are median **MiB/s**. Compression levels are numerically equal,
not necessarily equal quality. `NOISY` marks a measurement pair where either
implementation exceeds 10% spread; those rates need a repeat before drawing
conclusions. Spread is `(max - min) / median` of seconds per operation.

These are current flate/libdeflate comparisons. The source corpus was regenerated
from the current worktree, so differences from the previous device report do
not isolate optimization gains. For a fixed-corpus before/after comparison, see
[match copying and Huffman construction](./optimization-20260910.md).

## Raw direct — level 6

Both implementations reuse codecs and caller-owned output buffers.
Inputs below are 262144 bytes except precompressed (69223 bytes).

### Compression

| Corpus | flate | libdeflate | Compressed bytes flate / libdeflate | Spread flate / libdeflate |
| --- | ---: | ---: | ---: | ---: |
| repetitive-256k | 811.7 | 1156.4 | 1033 / 833 | 0.7% / 0.9% |
| random-256k | 56.5 | 136.8 | 262224 / 262169 | 1.0% / 1.0% |
| mixed-256k | 107.6 | 263.6 | 131739 / 131646 | 2.8% / 3.4% |
| source | 41.6 | 116.1 | 65565 / 65435 | 0.6% / 1.2% |
| json-256k | 78.2 | 152.2 | 41115 / 37082 | 1.3% / 0.5% |
| precompressed | 63.8 | 176.2 | 69248 / 69233 | 1.4% / 1.7% |

### Decompression

Each throughput cell is **flate / libdeflate** decoding the same exact fixture.
The adjacent spread column follows the same implementation order.

| Corpus | flate-produced fixture | Spread flate / libdeflate | libdeflate-produced fixture | Spread flate / libdeflate |
| --- | ---: | ---: | ---: | ---: |
| repetitive-256k | 6273.1 / 6294.3 | 1.0% / 0.6% | 10643.6 / 14113.4 | 1.3% / 0.7% |
| random-256k | 38320.8 / 68602.2 | 2.1% / 1.0% | 37965.6 / 67865.7 | 0.5% / 1.7% |
| mixed-256k | 8026.8 / 11308.5 | 0.7% / 0.9% | 12463.5 / 21705.8 | 0.4% / 0.5% |
| source | 304.1 / 1646.2 | 1.5% / 1.0% | 306.3 / 1763.7 | 1.1% / 0.3% |
| json-256k | 609.6 / 2411.5 | 1.0% / 0.6% | 663.6 / 2970.4 | 0.6% / 0.4% |
| precompressed | 49845.5 / 86206.8 | 1.8% / 3.6% | 47224.7 / 87075.6 | 7.0% / 4.3% |

## One-shot wrappers — source, level 6

Each throughput cell is **flate / libdeflate**. Decode columns use the
libdeflate-produced fixture. Allocation/release is included; libdeflate knows
the output size while flate grows its output, so this is an application-cost
comparison. Both implementations verify checksums.

| Format | Compression | Spread flate / libdeflate | Decompression | Spread flate / libdeflate | Compressed bytes flate / libdeflate |
| --- | ---: | ---: | ---: | ---: | ---: |
| zlib | 40.7 / 115.0 | 0.7% / 1.1% | 167.0 / 1707.1 | 0.4% / 0.3% | 65571 / 65441 |
| gzip | 40.3 / 114.9 | 0.5% / 3.2% | 164.0 / 1715.8 | 0.4% / 0.5% | 65583 / 65453 |

## Notes and artifacts

- Complete results also include L0/L1/L9, small/large inputs and other one-shot
  cases. All 192 implementation/workload summaries are below 10% spread
  (maximum 9.7%). Spread is not a confidence interval.
- Warm buffers; no CPU affinity or thermal control. No JS/Wasm, peak-memory or
  streaming throughput claims. See [benchmark methodology](./README.md).
- Source corpus SHA-256:
  `cf1e62e2fae8f95cc7b94018abb0648a130f83e7f307fc7b8f03ac64e64cffec`.
- Precompressed corpus SHA-256 (69223 bytes):
  `e2aa3ce54481208808b746ce0cca45445a9ad696894c5dac812da83b111b5fda`.
  These repository-derived corpora differ from the prior run. Compare corpus
  hashes before using historical throughput or compressed-size differences.
- Full report, samples, metadata, source snapshot and exact corpus/fixtures:
  `.local/bench/20260910T074714.890399Z/` (local, ignored by Git).
