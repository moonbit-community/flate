# MacBook Pro M3 Max Results

Latest paired native-release run: **2026-09-21 08:22 UTC** (16:22 Asia/Shanghai), at **`83b26bb`**. These tables replace the older device results and include the committed default-compression optimizations. `fast_store=false` (the default) throughout.

This is a fresh flate/libdeflate comparison, not a before/after attribution to a single optimization. Both current encoders generated new fixtures, and each decoder decoded both producers’ exact bytes. The earlier focused experiments and full ZIP timings are separate measurements; they are not inputs to these tables.

## Environment and method

- Apple M3 Max, 16 CPU cores; macOS 26.6.2 arm64.
- Clean measured checkout at `83b26bb`; Moon `0.1.20260920`, moonc `0.10.14+7d59c7ec9`; native release.
- Installed libdeflate **1.25**, using the repository benchmark harness. Exact compiler commands, versions and linked-library hashes are in `metadata.json`.
- Quick raw-direct suite: **3 rounds, >=200 ms per final batch**, 23 configurations, **414 timed samples**, 138 implementation/workload summaries.
- Nine frozen inputs replayed from `.local-analysis/lz77-industrial/baseline/corpus.json`, with every input hash checked before timing. L1/L6/L9 plus selected L0 and size controls.
- Reused codecs and caller-owned output. Compression capacity is the maximum of both declared bounds; both decoders receive exactly N output bytes.
- Caller-buffer allocation, construction and file I/O are outside timing. Per-stream reset and Huffman construction remain inside; this is not a zero-internal-allocation claim.
- Every fixture is independently validated by Python zlib, including full stream termination; both benchmark decoders validate its contents. Timed workloads execute sequentially and alternate order.

```sh
python3 benchmark/run.py --profile quick --rounds 3 --milliseconds 200 \
  --corpus-manifest .local-analysis/lz77-industrial/baseline/corpus.json \
  --output .local-analysis/bench-20260921-83b26bb
```

Use a new output directory when repeating the command. The retained run also contains its own `corpus.json`, so it can serve as the replay source.

Rates are median **MiB/s**. Multipliers are the median of **paired per-round flate time / libdeflate time**; a value above 1 means libdeflate is faster. Paired minimum–maximum ranges are not confidence intervals and need not equal a quotient of displayed medians.

Equal numeric compression levels do not imply equal compressed size. Spread is `(max-min)/median` of seconds per operation. If either implementation exceeds 10% spread, the speed multiplier is suppressed.

## Raw direct — level 6 compression

The first five inputs are 262144 bytes; precompressed is **84345 bytes**. Source-4k, repetitive-512 and repetitive-1m are 4096, 512 and 1048576 bytes.

| Corpus | flate MiB/s | libdeflate MiB/s | libdeflate / flate (paired range) | Compressed bytes flate / libdeflate | Spread flate / libdeflate |
| --- | ---: | ---: | ---: | ---: | ---: |
| repetitive-256k | 1380.3 | 1167.7 | 0.85× (0.84–0.87) | 872 / 833 | 3.7% / 1.8% |
| random-256k | 69.0 | 142.8 | 2.07× (2.05–2.12) | 262166 / 262169 | 0.7% / 2.9% |
| mixed-256k | 156.6 | 265.0 | 1.69× (1.68–1.74) | 131575 / 131646 | 2.2% / 1.2% |
| source | 84.3 | 116.2 | 1.38× (1.30–1.50) | 64367 / 64515 | 5.1% / 8.8% |
| json-256k | 124.4 | 151.1 | 1.21× (1.21–1.23) | 37021 / 37082 | 2.9% / 1.7% |
| precompressed | 71.8 | 158.1 | 2.22× (2.11–2.31) | 84355 / 84355 | 1.6% / 8.6% |
| source-4k | 127.1 | 188.0 | 1.49× (1.48–1.53) | 1445 / 1444 | 0.9% / 3.7% |
| repetitive-512 | 166.0 | 95.4 | 0.59× (0.57–0.60) | 62 / 65 | 4.9% / 3.2% |
| repetitive-1m | 1420.2 | 1150.4 | 0.81× (0.78–0.82) | 3337 / 3178 | 2.2% / 3.7% |

## Raw direct — level 6 decompression, flate-produced fixtures

Both decoders receive the same compressed fixture in each row.

| Corpus | flate MiB/s | libdeflate MiB/s | libdeflate / flate (paired range) | Shared fixture bytes | Spread flate / libdeflate |
| --- | ---: | ---: | ---: | ---: | ---: |
| repetitive-256k | 11391.9 | 10852.1 | 0.95× (0.95–0.96) | 872 | 1.6% / 0.7% |
| random-256k | 66373.3 | 71524.9 | 1.07× (1.07–1.08) | 262166 | 0.5% / 0.8% |
| mixed-256k | 18231.3 | 20933.7 | 1.15× (1.15–1.15) | 131575 | 1.0% / 1.3% |
| source | 1340.5 | 1925.9 | NOISY — suppressed | 64367 | 10.9% / 3.2% |
| json-256k | 2415.2 | 2775.3 | 1.15× (1.14–1.18) | 37021 | 3.0% / 0.5% |
| precompressed | 85291.4 | 89016.6 | 1.04× (0.98–1.05) | 84355 | 7.1% / 1.2% |
| source-4k | 686.8 | 793.4 | 1.16× (1.11–1.16) | 1445 | 0.3% / 4.8% |
| repetitive-512 | 1404.0 | 1726.8 | 1.23× (1.23–1.24) | 62 | 0.8% / 1.6% |
| repetitive-1m | 11116.3 | 12559.3 | 1.10× (1.09–1.13) | 3337 | 4.7% / 5.3% |

## Raw direct — level 6 decompression, libdeflate-produced fixtures

Both decoders receive the same compressed fixture in each row.

| Corpus | flate MiB/s | libdeflate MiB/s | libdeflate / flate (paired range) | Shared fixture bytes | Spread flate / libdeflate |
| --- | ---: | ---: | ---: | ---: | ---: |
| repetitive-256k | 13173.1 | 13741.2 | 1.05× (1.04–1.05) | 833 | 1.7% / 1.5% |
| random-256k | 65407.1 | 71648.8 | 1.09× (1.09–1.13) | 262169 | 3.7% / 0.1% |
| mixed-256k | 16628.6 | 22148.7 | 1.32× (1.31–1.33) | 131646 | 2.6% / 3.7% |
| source | 1258.6 | 1832.8 | 1.46× (1.39–1.47) | 64515 | 6.7% / 1.0% |
| json-256k | 2494.1 | 2932.5 | 1.17× (1.17–1.19) | 37082 | 2.1% / 1.1% |
| precompressed | 85294.3 | 87879.5 | 1.03× (1.01–1.04) | 84355 | 8.4% / 9.0% |
| source-4k | 681.8 | 799.6 | 1.17× (1.13–1.19) | 1444 | 0.1% / 5.4% |
| repetitive-512 | 340.2 | 282.0 | 0.84× (0.83–0.85) | 65 | 3.0% / 2.4% |
| repetitive-1m | 12801.3 | 15614.7 | 1.23× (1.19–1.23) | 3178 | 1.4% / 3.9% |

## Interpretation

- source L6 compression: flate **84.3 MiB/s**, libdeflate **116.2 MiB/s**; paired libdeflate advantage **1.38× (1.30–1.50)**. Outputs are **64367 / 64515 bytes**.
- json-256k L6 compression: flate **124.4 MiB/s**, libdeflate **151.1 MiB/s**; paired libdeflate advantage **1.21× (1.21–1.23)**. Outputs are **37021 / 37082 bytes**.
- random-256k L6 compression: flate **69.0 MiB/s**, libdeflate **142.8 MiB/s**; paired libdeflate advantage **2.07× (2.05–2.12)**. Outputs are **262166 / 262169 bytes**.
- precompressed L6 compression: flate **71.8 MiB/s**, libdeflate **158.1 MiB/s**; paired libdeflate advantage **2.22× (2.11–2.31)**. Outputs are **84355 / 84355 bytes**.
- Compression changes include distance-aware L6 matching, compact predecessor distances, a linear Huffman construction fast path and larger whole-buffer L6 blocks. Small inputs retain the earlier parser; streaming keeps bounded 16 KiB input blocks.
- Do not interpret decoder changes relative to older tables as decoder-only speedups: changed encoder output also changes the decoding workload. Inspect the exact fixture hashes.
- This replay differs from the 2026-09-11 device report’s source and precompressed inputs. Cross-date throughput quotients are not isolated optimization measurements.

## Noise and limits

**4 of 138 summaries exceed 10% spread.** All samples are retained; noisy multipliers are suppressed, not selectively replaced.

| Corpus | Level | Operation | Producer | Implementation | Spread |
| --- | ---: | --- | --- | --- | ---: |
| random-256k | 0 | compress | none | flate | 11.3% |
| source | 1 | compress | none | libdeflate | 13.9% |
| source | 6 | decompress | flate | flate | 10.9% |
| source | 9 | decompress | flate | flate | 12.5% |

These are warm-buffer measurements without CPU affinity or thermal control. Very high stored-data decode rates describe cache-resident copies. This suite does not measure complete ZIP I/O, streaming throughput, JS/Wasm throughput, peak memory, fzip or one-shot wrappers. See [methodology](./README.md).

## Artifacts and reproducibility

Retained run: `.local-analysis/bench-20260921-83b26bb/` (local, Git-ignored, outside the build cache).

- `report.md`, `summary.json`, `comparisons.json`: all configurations, paired ratios, sizes and spread.
- `samples.jsonl`: all timed measurements.
- `metadata.json`, build logs, `source.diff` and `source/`: clean revision, versions, commands, source and binary hashes.
- `corpus.json`, `fixtures.json`, `corpus/` and `fixtures/`: exact frozen inputs and encoder outputs.

Audit hashes:

| File | SHA-256 |
| --- | --- |
| metadata.json | `c9886e8b21e5e7e28964d4bbb7f96a64f3088c923bd15cdd64ddf03cf4e49a6f` |
| samples.jsonl | `eccfe85998c26d635a10d6d8ed305a2d5ffad34ed5a0ab3d3226265c642fd5cd` |
| summary.json | `c3575dd8d8f6be252dd56d5fe2a3193fabe624a3a2f85dd16e5da07f21fe1619` |
| comparisons.json | `e68b06870195d652d8d2456209935882a860b8c652e3cf603b8c984c210743d2` |
| corpus.json | `9423ce18ff42edeb9aafd896c2fe3fdf273783c04e9477cbcaa66db4a2377e4a` |
| fixtures.json | `0a60a53e3476bea6b6c8c1b347724d0752ee45890e2539c80a60384d5e0d7e44` |

Frozen source/precompressed input hashes:

- source (262144 bytes): `c23c21e5265f823b7e96d358c70b3d9dccea13c0d4f17abf107e44fe780c8231`.
- precompressed (84345 bytes): `0b29e7820c98f55b4082b7857f965a3c7c19fcbc1295a2daf73b63d289894e73`.

The committed document contains selected tables; retain the ignored run directory to reproduce or audit every sample.
