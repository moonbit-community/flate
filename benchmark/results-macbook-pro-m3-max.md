# MacBook Pro M3 Max Results

Latest paired native-release run: **2026-09-23 16:52 UTC** (**2026-09-24 00:52 Asia/Shanghai**), at **`d32b69f`**. `fast_store=false` (the default) throughout.

This update includes a fresh same-input comparison of **`83b26bb` → `d32b69f`**, covering the LZ77 and workspace/hash-table optimizations merged in #4 and #5. The baseline was rebuilt and measured immediately before the current revision. The flate/libdeflate tables below use the current revision only.

## Environment and method

- Apple M3 Max, 16 CPU cores; macOS 26.6.2 arm64.
- Moon `0.1.20260920`, moonc `0.10.14+7d59c7ec9`; native release; libdeflate **1.25**.
- Measured codec and benchmark revisions: baseline `83b26bb`, current `d32b69f`. ZIP CLI code is outside the measured runner.
- Identical benchmark harness and runner sources, compiler versions and libdeflate version for both revisions.
- Each quick raw-direct run: **3 rounds, >=200 ms per final batch**, **23 configurations**, **414 timed samples**, **138 implementation/workload summaries**. Total: **828 timed samples** across both revisions.
- Nine frozen inputs generated once from the current checkout, then hash-verified and replayed for both runs. L1/L6/L9 plus selected L0 and size controls.
- Reused codecs and caller-owned output. Compression capacity is the maximum of both declared bounds; both decoders receive exactly N output bytes.
- Caller-buffer allocation, construction and file I/O are outside timing. Per-stream reset and Huffman construction remain inside; this is not a zero-internal-allocation claim.
- Every fixture is independently validated by Python zlib, including full stream termination; both benchmark decoders validate its contents. Timed workloads execute sequentially and alternate implementation/operation order.

Run the repository's [benchmark harness](./run.py) from the repository root:

```sh
python3 benchmark/run.py --profile quick --rounds 3 --milliseconds 200
```

This command generates inputs from the checkout. Raw samples and frozen inputs
for the reported run are not included in Git; the tables below summarize the
measurements. For a new comparison between revisions, use the same generated
inputs for both runs as described in the [methodology](./README.md).

Rates are median **MiB/s**. In current flate/libdeflate tables, multipliers are the median of **paired per-round flate time / libdeflate time**; a value above 1 means libdeflate is faster. Paired minimum–maximum ranges are not confidence intervals and need not equal a quotient of displayed medians.

Equal numeric compression levels do not imply equal compressed size. Spread is `(max-min)/median` of seconds per operation. If either implementation exceeds 10% spread, the speed multiplier is suppressed.

## Change from `83b26bb` to `d32b69f`

Both revisions were rebuilt and measured in this session on the same frozen inputs. These are ratios of medians from separate sequential runs, not paired before/after samples or confidence intervals. A positive change means higher throughput. Changes are suppressed if either flate run exceeds 10% spread. Compressed sizes must be considered alongside speed.

| Corpus (L6 compression) | Old MiB/s | Current MiB/s | Throughput change | Compressed bytes old / current | Spread old / current |
| --- | ---: | ---: | ---: | ---: | ---: |
| repetitive-256k | 1403.4 | 1418.4 | +1.1% | 872 / 872 | 0.1% / 0.5% |
| random-256k | 67.3 | 96.3 | +43.1% | 262166 / 262166 | 0.4% / 1.3% |
| mixed-256k | 160.8 | 235.3 | +46.4% | 131575 / 131575 | 0.7% / 3.8% |
| source | 90.9 | 104.2 | +14.6% | 61890 / 62151 | 1.5% / 7.9% |
| json-256k | 133.3 | 202.0 | +51.5% | 37021 / 36977 | 0.3% / 4.0% |
| precompressed | 72.7 | 100.0 | +37.5% | 96872 / 96872 | 2.0% / 0.5% |
| source-4k | 130.2 | 135.1 | +3.8% | 1445 / 1446 | 0.2% / 0.4% |
| repetitive-512 | 177.3 | 200.0 | +12.8% | 62 / 62 | 1.5% / 0.8% |
| repetitive-1m | 1486.4 | 1461.4 | -1.7% | 3337 / 3337 | 0.0% / 0.5% |

## Interpretation

- **L6 compression is materially faster on random, mixed, JSON and precompressed data:** observed throughput gains are **43.1%, 46.4%, 51.5% and 37.5%**, respectively. Their unchanged libdeflate reference improved by **7.1%, 3.4%, 3.1% and 3.3%** across runs, so the flate gains are much larger than the reference drift, although the exact percentages are not isolated causal estimates.
- JSON L6 now reaches **202.0 MiB/s**, versus libdeflate's **161.3 MiB/s**, with **36977 / 37082 bytes**. The paired libdeflate/flate multiplier is **0.80× (0.78–0.83)**: flate is about **1.25×** as fast in this case.
- Source L6 improves from **90.9 to 104.2 MiB/s (+14.6%)**, with a size tradeoff: **61890 → 62151 bytes (+0.42%)**. Current flate timing spread is **7.9%**, so this result is less stable than the large gains above. Source-4k improves **3.8%**, with **1445 → 1446 bytes**.
- The gains are not universal: repetitive-256k L6 is nearly flat (**+1.1%**), repetitive-1m is slightly slower (**−1.7%**), and repetitive-512 improves **12.8%**. All three retain the same compressed sizes.
- Other levels show the same main pattern: random/mixed compression improves **47.2% / 33.1% at L1** and **46.4% / 33.8% at L9**, with smaller outputs. L1 precompressed improves **38.8%**; L9 precompressed is **NOISY** and no speedup is claimed. L9 source improves **8.3%** while shrinking **61883 → 61511 bytes**. Small gains close to the reference drift are not strong optimization evidence; for example, L1 source rises **11.4%** while its libdeflate reference rises **15.7%**.
- L9 JSON remains a tradeoff: observed throughput rises **5.3%**, but output grows **39205 → 39277 bytes (+0.18%)** and the libdeflate reference rises **3.6%**. This is not a compelling isolated speedup.
- **Do not infer a decoder-only speedup.** These changes primarily optimize encoding, and altered compressed bytes also change decoding work. The current decoder tables compare both implementations on the same compressed input, not attribution to decoder changes.

The first five inputs are 262144 bytes; precompressed is **96862 bytes**. Source-4k, repetitive-512 and repetitive-1m are 4096, 512 and 1048576 bytes.

## Raw direct — level 6 compression

| Corpus | flate MiB/s | libdeflate MiB/s | libdeflate / flate (paired range) | Compressed bytes flate / libdeflate | Spread flate / libdeflate |
| --- | ---: | ---: | ---: | ---: | ---: |
| repetitive-256k | 1418.4 | 1222.0 | 0.86× (0.86–0.87) | 872 / 833 | 0.5% / 0.2% |
| random-256k | 96.3 | 148.0 | 1.54× (1.52–1.55) | 262166 / 262169 | 1.3% / 1.2% |
| mixed-256k | 235.3 | 280.1 | 1.19× (1.17–1.23) | 131575 / 131646 | 3.8% / 1.5% |
| source | 104.2 | 129.0 | 1.24× (1.21–1.26) | 62151 / 61920 | 7.9% / 3.9% |
| json-256k | 202.0 | 161.3 | 0.80× (0.78–0.83) | 36977 / 37082 | 4.0% / 1.9% |
| precompressed | 100.0 | 168.6 | 1.69× (1.67–1.71) | 96872 / 96872 | 0.5% / 1.9% |
| source-4k | 135.1 | 197.8 | 1.46× (1.46–1.48) | 1446 / 1444 | 0.4% / 1.7% |
| repetitive-512 | 200.0 | 88.5 | 0.44× (0.43–0.47) | 62 / 65 | 0.8% / 8.7% |
| repetitive-1m | 1461.4 | 1209.8 | 0.83× (0.82–0.83) | 3337 / 3178 | 0.5% / 0.2% |

## Raw direct — level 6 decompression, flate-produced fixtures

Both decoders receive the same compressed fixture in each row.

| Corpus | flate MiB/s | libdeflate MiB/s | libdeflate / flate (paired range) | Shared fixture bytes | Spread flate / libdeflate |
| --- | ---: | ---: | ---: | ---: | ---: |
| repetitive-256k | 11767.5 | 11432.8 | 0.97× (0.97–0.98) | 872 | 1.3% / 0.3% |
| random-256k | 68672.8 | 71374.7 | 1.04× (1.02–1.05) | 262166 | 1.1% / 2.1% |
| mixed-256k | 18805.4 | 21662.2 | 1.16× (1.15–1.16) | 131575 | 0.9% / 1.0% |
| source | 1688.3 | 2046.9 | 1.22× (1.19–1.25) | 62151 | 8.1% / 2.7% |
| json-256k | 2459.2 | 2819.6 | 1.15× (1.13–1.18) | 36977 | 2.9% / 1.1% |
| precompressed | 95926.4 | 80542.2 | NOISY — suppressed | 96872 | 1.1% / 10.2% |
| source-4k | 716.0 | 831.9 | 1.16× (1.16–1.18) | 1446 | 2.0% / 0.6% |
| repetitive-512 | 1474.6 | 1803.3 | 1.22× (1.22–1.23) | 62 | 0.8% / 0.2% |
| repetitive-1m | 11683.3 | 12853.3 | 1.09× (1.09–1.11) | 3337 | 1.4% / 1.6% |

## Raw direct — level 6 decompression, libdeflate-produced fixtures

Both decoders receive the same compressed fixture in each row.

| Corpus | flate MiB/s | libdeflate MiB/s | libdeflate / flate (paired range) | Shared fixture bytes | Spread flate / libdeflate |
| --- | ---: | ---: | ---: | ---: | ---: |
| repetitive-256k | 13539.9 | 14435.0 | 1.07× (1.06–1.07) | 833 | 0.2% / 0.6% |
| random-256k | 66512.9 | 71303.3 | 1.07× (1.04–1.08) | 262169 | 0.3% / 3.0% |
| mixed-256k | 17524.3 | 22747.8 | 1.30× (1.28–1.31) | 131646 | 1.0% / 1.2% |
| source | 1602.4 | 1945.2 | 1.21× (1.16–1.22) | 61920 | 7.5% / 2.5% |
| json-256k | 2625.5 | 3112.6 | 1.18× (1.17–1.19) | 37082 | 1.5% / 0.3% |
| precompressed | 95572.7 | 74542.0 | 0.78× (0.73–0.79) | 96872 | 0.5% / 6.9% |
| source-4k | 725.4 | 840.5 | 1.16× (1.16–1.18) | 1444 | 2.1% / 0.0% |
| repetitive-512 | 352.4 | 298.5 | 0.85× (0.83–0.88) | 65 | 1.9% / 3.9% |
| repetitive-1m | 13466.0 | 16080.2 | 1.19× (1.18–1.20) | 3178 | 1.2% / 0.2% |

## Noise and limits

**Baseline: 1 of 138 summaries exceed 10% spread; current: 6 of 138.** Noisy multipliers and before/after changes are suppressed, not selectively replaced.

| Run | Corpus | Level | Operation | Producer | Implementation | Spread |
| --- | --- | ---: | --- | --- | --- | ---: |
| baseline | source | 6 | decompress | libdeflate | flate | 12.3% |
| current | source | 9 | decompress | libdeflate | flate | 10.1% |
| current | source | 0 | compress | none | flate | 12.1% |
| current | precompressed | 1 | decompress | flate | libdeflate | 13.4% |
| current | precompressed | 6 | decompress | flate | libdeflate | 10.2% |
| current | precompressed | 9 | compress | none | flate | 10.8% |
| current | precompressed | 9 | decompress | libdeflate | libdeflate | 11.2% |

These are warm-buffer measurements without CPU affinity or thermal control. The two revisions ran sequentially rather than interleaved; small cross-run changes should not be treated as isolated optimization effects. The unchanged libdeflate implementation provides a reference for cross-run drift, but no normalization can eliminate all timing noise.

Very high stored-data decode rates describe cache-resident copies. This suite does not measure complete ZIP I/O, streaming throughput, JS/Wasm throughput, peak memory, fzip or one-shot wrappers. The ZIP CLI fixes are not performance claims from this benchmark. See [methodology](./README.md).
