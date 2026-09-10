# MacBook Pro M3 Max Results

Latest paired run: **2026-09-10**. This page replaces the historical tables with
a current snapshot; older reports remain in Git history.

## Environment and method

- Apple M3 Max, 16 CPU cores, macOS 26.6.2 arm64.
- flate `065f737`, clean source at build time; native release.
- Moon `0.1.20260904`; moonc `0.10.12+1634b282e`.
- Homebrew libdeflate `1.25`; C runner built with Apple Clang 21, `-O3 -DNDEBUG`.
- Quick suite, **5 rounds, >=100 ms per final batch**, alternating execution order.
  32 configurations, 960 samples; elapsed 290.6 seconds.
- Both decoders validated both producers' fixtures; Python zlib independently
  validated complete streams. No timed workloads ran concurrently.

```sh
python3 benchmark/run.py --profile quick --rounds 5 --milliseconds 100
```

Rates below are median **MiB/s**. Compression levels are numerically equal,
not necessarily equal quality. These are current flate/libdeflate comparisons,
not isolated before/after measurements of the latest optimization.

## Raw direct — level 6

Both implementations reuse codecs and caller-owned output buffers.
Inputs below are 262144 bytes except precompressed (67938 bytes).

### Compression

| Corpus | flate | libdeflate | Compressed bytes flate / libdeflate | Spread flate / libdeflate |
| --- | ---: | ---: | ---: | ---: |
| repetitive-256k | 811.8 | 1155.1 | 1033 / 833 | 1.7% / 8.1% |
| random-256k | 54.1 | 136.0 | 262224 / 262169 | 1.1% / 2.0% |
| mixed-256k | 102.6 | 264.3 | 131739 / 131646 | 1.1% / 2.8% |
| source | 41.4 | 115.5 | 65225 / 65145 | 1.0% / 1.8% |
| json-256k | 76.5 | 151.0 | 41115 / 37082 | 1.7% / 2.4% |
| precompressed | 60.9 | 177.2 | 67963 / 67948 | 0.1% / 1.5% |

### Decompression

Each cell is **flate / libdeflate** throughput decoding the same exact fixture.
Maximum spread among these decode measurements: 6.4%.

| Corpus | flate-produced fixture | libdeflate-produced fixture |
| --- | ---: | ---: |
| repetitive-256k | 4304.2 / 6265.6 | 6190.2 / 13685.3 |
| random-256k | 38593.3 / 68749.1 | 38035.6 / 67924.8 |
| mixed-256k | 6276.8 / 11319.1 | 8742.5 / 21723.2 |
| source | 268.0 / 1656.0 | 273.0 / 1778.8 |
| json-256k | 538.5 / 2410.8 | 599.6 / 2962.8 |
| precompressed | 53219.6 / 90678.8 | 50828.7 / 92416.1 |

## One-shot wrappers — source, level 6

Each throughput cell is **flate / libdeflate**. Decode columns use the
libdeflate-produced fixture. Allocation/release is included; libdeflate knows
the output size while flate grows its output, so this is an application-cost
comparison. Maximum spread in these selected measurements is 7.1%.

| Format | Compression | Decompression | Compressed bytes flate / libdeflate |
| --- | ---: | ---: | ---: |
| zlib | 40.4 / 114.5 | 168.4 / 1712.2 | 65231 / 65151 |
| gzip | 39.8 / 112.9 | 164.4 / 1709.9 | 65243 / 65163 |

## Notes and artifacts

- Complete results also include L0/L1/L9, small/large inputs and other one-shot
  cases. Of 192 implementation/workload summaries, 23 exceed 10% spread
  (`NOISY`); none of the selected measurements above do. Spread is
  `(max - min) / median`, not a confidence interval.
- Warm buffers; no CPU affinity or thermal control. No JS/Wasm or streaming
  throughput claims. See [benchmark methodology](./README.md).
- Source corpus SHA-256:
  `2a0a7de7aea6ec2ccdbc0f3cd8671fca1e780ca703a6c42142ab0959644d6e98`.
  Repository-derived inputs and toolchains differ from older runs; do not
  infer an optimization speedup from those tables.
- Full report, samples, metadata, source snapshot and exact corpus/fixtures:
  `.local/bench/20260910T063727.794212Z/` (local, ignored by Git).
