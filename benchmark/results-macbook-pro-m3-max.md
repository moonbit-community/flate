# MacBook Pro M3 Max Results

Latest paired native-release run: **2026-10-15 07:43 UTC** (**2026-10-15 15:43 Asia/Shanghai**), at **`f9a5e6d`**. `fast_store=false` (the default) throughout.

This snapshot replaces the September 24 tables with a fresh measurement of the current codec. The nine frozen inputs from the `d32b69f` run were copied and SHA-256 verified, including repository source and precompressed data. The compiler has changed since that run; no before/after speedup is inferred from the historical timings. The test cleanup in this PR does not change the codec implementation.

## Environment and method

- Apple M3 Max, 16 CPU cores; macOS 26.6.2 arm64.
- Moon `0.1.20261012`, moonc `0.10.15+943464bfa`; native release; Apple clang 21.0.0; libdeflate **1.25**.
- Python 3.14.6 with zlib 1.2.12 independently validates every exported fixture, including full output and stream termination.
- Measured revision: `f9a5e6d9299b9d0c5f01328213d34e7626bde554`; clean worktree at measurement start. Benchmark documentation is updated after measurement.
- Quick raw-direct profile: **7 rounds, >=200 ms per final batch**, **23 configurations**, **966 timed samples**, **138 implementation/workload summaries**; **46 exported fixtures**.
- Both decoders decode both producers' exact fixtures. Reused codecs and caller-owned output: compression capacity is the maximum of both declared bounds; both decoders receive exactly N output bytes.
- Caller-buffer allocation, construction and file I/O are outside timing. Per-stream reset and Huffman construction remain inside; the allocation boundary does not imply zero internal allocations.
- Workloads execute sequentially; implementation and operation order alternate by round. Total run duration: **574.9 seconds**.

Run the [benchmark harness](./run.mbtx) from the repository root:

```sh
moon run --target native benchmark/run.mbtx -- --profile quick --rounds 7 --milliseconds 200
```

That command generates inputs from the checkout. This measurement instead used:

```sh
C_INCLUDE_PATH=/opt/homebrew/Cellar/libdeflate/1.25/include \
LIBRARY_PATH=/opt/homebrew/Cellar/libdeflate/1.25/lib \
moon run --target native benchmark/run.mbtx -- \
  --profile quick --rounds 7 --milliseconds 200 \
  --corpus-manifest .local-analysis/bench-20260924-d32b69f/corpus.json \
  --output .local/bench/20261015-f9a5e6d-quick-7x200
```

The frozen inputs, raw samples, fixture hashes, build logs and generated report are retained locally in that output directory and are ignored by Git. The old corpus manifest is also local; it is required to reproduce these exact inputs. For other installations, configure the libdeflate header/library search paths as described in the [methodology](./README.md).

Rates are median **MiB/s**. A multiplier is the median of **paired per-round flate time / libdeflate time**; above 1 means libdeflate is faster. Paired minimum–maximum ranges are not confidence intervals and need not equal a quotient of the displayed median rates.

Equal numeric compression levels do not imply equal compressed size. Spread is `(max-min)/median` of seconds per operation. If either implementation exceeds 10% spread, the multiplier is suppressed; the measured rates remain visible.

## Raw direct — level 6 compression

| Corpus | flate MiB/s | libdeflate MiB/s | libdeflate / flate (paired range) | Compressed bytes flate / libdeflate | Spread flate / libdeflate |
| --- | ---: | ---: | ---: | ---: | ---: |
| repetitive-256k | 1393.3 | 1182.3 | 0.85× (0.83–0.86) | 872 / 833 | 3.8% / 2.1% |
| random-256k | 78.4 | 136.1 | NOISY — suppressed | 262166 / 262169 | 22.7% / 10.3% |
| mixed-256k | 187.1 | 236.9 | NOISY — suppressed | 131575 / 131646 | 27.3% / 64.5% |
| source | 106.8 | 122.6 | NOISY — suppressed | 62151 / 61920 | 4.0% / 12.9% |
| json-256k | 196.8 | 153.4 | NOISY — suppressed | 36977 / 37082 | 13.1% / 5.5% |
| precompressed | 79.5 | 154.9 | 1.96× (1.87–2.05) | 96872 / 96872 | 5.9% / 7.2% |
| source-4k | 151.6 | 194.2 | 1.27× (1.26–1.29) | 1446 / 1444 | 6.1% / 6.4% |
| repetitive-512 | 198.9 | 92.7 | NOISY — suppressed | 62 / 65 | 9.4% / 14.4% |
| repetitive-1m | 1470.5 | 1173.1 | 0.80× (0.76–0.84) | 3337 / 3178 | 6.4% / 4.8% |

## Raw direct — level 6 decompression, flate-produced fixtures

| Corpus | flate MiB/s | libdeflate MiB/s | libdeflate / flate (paired range) | Shared fixture bytes | Spread flate / libdeflate |
| --- | ---: | ---: | ---: | ---: | ---: |
| repetitive-256k | 11128.2 | 10936.2 | 0.97× (0.96–1.00) | 872 | 4.7% / 4.3% |
| random-256k | 64531.1 | 68376.6 | NOISY — suppressed | 262166 | 59.2% / 126.8% |
| mixed-256k | 16194.0 | 19630.4 | NOISY — suppressed | 131575 | 28.0% / 13.1% |
| source | 1587.0 | 1966.3 | NOISY — suppressed | 62151 | 12.8% / 5.2% |
| json-256k | 2247.6 | 2706.2 | 1.20× (1.16–1.23) | 36977 | 6.5% / 5.1% |
| precompressed | 87643.3 | 88080.1 | 1.00× (0.97–1.03) | 96872 | 4.9% / 3.2% |
| source-4k | 673.6 | 796.8 | 1.18× (1.15–1.21) | 1446 | 5.3% / 6.3% |
| repetitive-512 | 2432.6 | 1722.4 | 0.70× (0.67–0.73) | 62 | 6.0% / 5.4% |
| repetitive-1m | 11363.7 | 12426.2 | 1.09× (1.06–1.14) | 3337 | 3.8% / 5.7% |

## Raw direct — level 6 decompression, libdeflate-produced fixtures

| Corpus | flate MiB/s | libdeflate MiB/s | libdeflate / flate (paired range) | Shared fixture bytes | Spread flate / libdeflate |
| --- | ---: | ---: | ---: | ---: | ---: |
| repetitive-256k | 12966.2 | 13716.7 | 1.06× (1.04–1.08) | 833 | 4.4% / 3.7% |
| random-256k | 63261.3 | 69260.8 | NOISY — suppressed | 262169 | 12.6% / 33.4% |
| mixed-256k | 16192.0 | 19477.9 | NOISY — suppressed | 131646 | 31.0% / 31.4% |
| source | 1516.6 | 1901.6 | NOISY — suppressed | 61920 | 13.1% / 4.0% |
| json-256k | 2424.9 | 2964.2 | 1.22× (1.19–1.26) | 37082 | 4.5% / 2.4% |
| precompressed | 89503.1 | 88447.1 | 0.99× (0.94–1.04) | 96872 | 6.6% / 7.6% |
| source-4k | 688.1 | 793.7 | 1.16× (1.14–1.22) | 1444 | 5.1% / 6.2% |
| repetitive-512 | 349.2 | 294.5 | 0.84× (0.81–0.87) | 65 | 4.8% / 2.2% |
| repetitive-1m | 12956.2 | 15939.3 | 1.23× (1.16–1.28) | 3178 | 7.5% / 2.1% |

## Other measured levels

The quick profile also measures L1/L9 on the six main inputs and L0 on random-256k and source. Compression rates and sizes follow; L6 decoder tables above use identical compressed fixtures for both implementations.

| Corpus | Level | flate MiB/s | libdeflate MiB/s | Compressed bytes flate / libdeflate | Spread flate / libdeflate |
| --- | ---: | ---: | ---: | ---: | ---: |
| repetitive-256k | 1 | 1425.7 | 1726.5 | 873 / 874 | 5.9% / 5.4% |
| repetitive-256k | 9 | 1426.9 | 1177.4 | 873 / 833 | 5.8% / 6.0% |
| random-256k | 0 | 65469.4 | 66218.3 | 262169 / 262169 | 8.4% / 3.4% |
| random-256k | 1 | 79.7 | 188.9 | 262166 / 262169 | 2.5% / 7.2% |
| random-256k | 9 | 79.7 | 132.7 | 262166 / 262169 | 1.4% / 4.8% |
| mixed-256k | 1 | 138.8 | 367.2 | 131575 / 131577 | 13.2% / 422.3% |
| mixed-256k | 9 | 140.0 | 248.0 | 131575 / 131646 | 1.6% / 3.5% |
| source | 0 | 60143.9 | 65319.4 | 262169 / 262169 | 10.6% / 4.4% |
| source | 1 | 169.9 | 457.5 | 69439 / 70088 | 11.6% / 7.0% |
| source | 9 | 40.2 | 39.6 | 61511 / 61141 | 5.6% / 3.0% |
| json-256k | 1 | 299.9 | 718.9 | 48531 / 52148 | 10.2% / 1.5% |
| json-256k | 9 | 27.1 | 15.2 | 39277 / 33044 | 2.9% / 6.7% |
| precompressed | 1 | 79.7 | 237.1 | 96872 / 96872 | 6.2% / 5.8% |
| precompressed | 9 | 80.1 | 158.8 | 96872 / 96872 | 7.2% / 9.6% |

## Noise and limits

**34 of 138 summaries exceed 10% spread.** Noisy multipliers are suppressed; no rows were replaced with selectively repeated measurements.

| Corpus | Level | Operation | Producer | Implementation | Spread |
| --- | ---: | --- | --- | --- | ---: |
| random-256k | 6 | compress | none | flate | 22.7% |
| random-256k | 6 | compress | none | libdeflate | 10.3% |
| random-256k | 6 | decompress | flate | flate | 59.2% |
| random-256k | 6 | decompress | flate | libdeflate | 126.8% |
| random-256k | 6 | decompress | libdeflate | flate | 12.6% |
| random-256k | 6 | decompress | libdeflate | libdeflate | 33.4% |
| mixed-256k | 1 | compress | none | flate | 13.2% |
| mixed-256k | 1 | compress | none | libdeflate | 422.3% |
| mixed-256k | 1 | decompress | flate | flate | 213.1% |
| mixed-256k | 1 | decompress | flate | libdeflate | 316.0% |
| mixed-256k | 1 | decompress | libdeflate | flate | 79.7% |
| mixed-256k | 1 | decompress | libdeflate | libdeflate | 162.1% |
| mixed-256k | 6 | compress | none | flate | 27.3% |
| mixed-256k | 6 | compress | none | libdeflate | 64.5% |
| mixed-256k | 6 | decompress | flate | flate | 28.0% |
| mixed-256k | 6 | decompress | flate | libdeflate | 13.1% |
| mixed-256k | 6 | decompress | libdeflate | flate | 31.0% |
| mixed-256k | 6 | decompress | libdeflate | libdeflate | 31.4% |
| source | 0 | compress | none | flate | 10.6% |
| source | 0 | decompress | libdeflate | flate | 20.5% |
| source | 1 | compress | none | flate | 11.6% |
| source | 1 | decompress | flate | flate | 11.5% |
| source | 1 | decompress | libdeflate | flate | 11.9% |
| source | 6 | compress | none | libdeflate | 12.9% |
| source | 6 | decompress | flate | flate | 12.8% |
| source | 6 | decompress | libdeflate | flate | 13.1% |
| source | 9 | decompress | flate | flate | 12.9% |
| source | 9 | decompress | libdeflate | flate | 11.6% |
| json-256k | 1 | compress | none | flate | 10.2% |
| json-256k | 6 | compress | none | flate | 13.1% |
| json-256k | 9 | decompress | libdeflate | flate | 41.9% |
| json-256k | 9 | decompress | libdeflate | libdeflate | 46.4% |
| precompressed | 9 | decompress | libdeflate | flate | 38.9% |
| repetitive-512 | 6 | compress | none | libdeflate | 14.4% |

The first five inputs contain 262144 bytes each; precompressed is 96862 bytes. Source-4k, repetitive-512 and repetitive-1m contain 4096, 512 and 1048576 bytes. These inputs are the frozen September corpus, rather than regenerated source from the test cleanup.

These are warm-buffer measurements without CPU affinity or thermal control. Very high stored-data decode rates describe cache-resident copies. This snapshot does not measure complete ZIP I/O, streaming throughput, JS/Wasm throughput, peak memory, fzip or one-shot wrappers. Use the optional one-shot profile for allocation-inclusive raw/zlib/gzip application costs. See [methodology](./README.md).
