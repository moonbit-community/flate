# MacBook Pro M3 Max Results

For newer native L6 raw-direct decode results, see the
[Huffman primary-load study](./decode-primary-load-20260911.md): eligible
libdeflate / flate ratios are 1.42–1.55× on JSON. Both source pairs are noisy
and suppressed; earlier source ratios are not current-code measurements.
The older full-suite tables below exclude these later changes.

Latest full-suite paired run: **2026-09-11 04:41 UTC** (12:41 Asia/Shanghai).
This schema-2 run includes both the complete-match optimization and the
[source/JSON decode changes](./decode-source-json-20260911.md): deferred Huffman
refill and the unrolled three-byte short-match prefix. All tables below are
new paired measurements, not extrapolations from the before/after study.

The subsequent [literal fast-path change](./decode-literals-20260911.md) is
**not included in these tables**. Its separate frozen-binary before/after run
measures another 4.1–4.7% source and 2.3–2.6% JSON decode improvement. A fresh
paired libdeflate run is needed to update the cross-library ratios.

A later [native batched-token study](./decode-batch-20260911.md) includes a new
focused L6 three-way comparison. JSON improves 65–71% over the literal-fast-path
version and the measured libdeflate gap narrows to 2.05–2.21×. Source multipliers
are suppressed due to spread. Neither later decoder change is included in
the full-suite tables below; use the linked study for the newer focused results.

## Environment and method

- Apple M3 Max, 16 CPU cores, macOS 26.6.2 arm64.
- flate `08e4010` plus uncommitted benchmark workflow changes, the two decoder
  changes and their regression tests; native release. Exact sources, diff,
  build commands and binary hashes are saved with the run.
- Moon `0.1.20260904`; moonc `0.10.12+1634b282e`.
- Homebrew libdeflate **1.25**, Apple Clang 21, `-O3 -DNDEBUG`.
  The separate local libdeflate 1.26 checkout was not measured.
- Quick raw-direct suite: **7 rounds, >=150 ms per final batch**.
  23 configurations, **966 samples**, 138 implementation/workload summaries;
  elapsed **417.0 seconds**.
- Frozen inputs replayed from the 04:03 UTC run, originally captured on
  2026-09-10. Both current encoders freshly generated the fixtures.
- Both implementations reuse codecs and initialized caller-owned output.
  Compression uses the same capacity: the maximum of both declared bounds.
  Decompression receives exactly N output bytes on both sides; neither grows output.
- Caller-buffer allocation, codec construction, file I/O and input conversion
  are outside timing. Per-stream reset and Huffman construction remain inside.
  This is not a verified zero-internal-allocation claim.
- Both decoders validated both producers' exact fixtures, and Python zlib
  independently validated full payloads and stream termination.
  Timed workloads were sequential, with alternating execution order.

```sh
python3 benchmark/run.py --corpus-manifest .local/bench/20260911T040357.563461Z/corpus.json
```

Rates are median **MiB/s**. Speed multipliers are the median of **paired per-round
flate time / libdeflate time**; ranges are minimum–maximum paired ratios, not
confidence intervals. They need not equal the quotient of separate medians.
A ratio above 1 means libdeflate is faster.

Compression levels are numerically equal, not equal quality; compare sizes too.
Spread is `(max-min)/median` of seconds/operation. If either implementation
exceeds 10% spread, the pair is marked `NOISY` and its multiplier suppressed.

## Raw direct — level 6 compression

The first five corpora are 262144 bytes; precompressed is 69223 bytes.
Source-4k, repetitive-512 and repetitive-1m are 4096, 512 and 1048576 bytes.

| Corpus | flate MiB/s | libdeflate MiB/s | libdeflate / flate (paired range) | Compressed bytes flate / libdeflate | Spread flate / libdeflate |
| --- | ---: | ---: | ---: | ---: | ---: |
| repetitive-256k | 833.7 | 1164.2 | 1.40× (1.37–1.45) | 1033 / 833 | 2.5% / 4.0% |
| random-256k | 58.9 | 145.7 | 2.47× (2.38–2.52) | 262224 / 262169 | 2.4% / 3.6% |
| mixed-256k | 110.5 | 277.7 | 2.52× (2.45–2.56) | 131739 / 131646 | 2.0% / 3.9% |
| source | 43.2 | 122.3 | 2.83× (2.78–2.89) | 65565 / 65435 | 1.2% / 2.8% |
| json-256k | 78.8 | 154.9 | 1.96× (1.86–1.99) | 41115 / 37082 | 4.6% / 2.7% |
| precompressed | 63.5 | 178.7 | 2.82× (2.77–2.88) | 69248 / 69233 | 2.9% / 6.4% |
| source-4k | 81.7 | 196.7 | 2.40× (2.38–2.43) | 1528 / 1503 | 3.6% / 2.9% |
| repetitive-512 | 55.0 | 99.3 | 1.81× (1.77–1.84) | 62 / 65 | 3.2% / 0.9% |
| repetitive-1m | 860.4 | 1185.1 | 1.38× (1.37–1.40) | 3980 / 3178 | 2.0% / 0.8% |

## Raw direct — level 6 decompression, flate-produced fixtures

Both implementations decode the same exact compressed bytes in each row.

| Corpus | flate MiB/s | libdeflate MiB/s | libdeflate / flate (paired range) | Spread flate / libdeflate |
| --- | ---: | ---: | ---: | ---: |
| repetitive-256k | 6621.5 | 6439.6 | 0.97× (0.95–1.00) | 4.6% / 1.7% |
| random-256k | 40186.5 | 72202.9 | 1.80× (1.77–1.81) | 1.3% / 2.3% |
| mixed-256k | 8685.8 | 11683.6 | 1.34× (1.34–1.35) | 1.6% / 0.9% |
| source | 405.7 | 1698.4 | 4.20× (4.15–4.43) | 6.5% / 0.7% |
| json-256k | 711.2 | 2445.4 | 3.46× (3.40–3.50) | 2.8% / 2.5% |
| precompressed | 49747.0 | 90249.3 | 1.81× (1.74–1.91) | 4.5% / 6.1% |
| source-4k | 321.8 | 793.0 | 2.46× (2.43–2.48) | 3.9% / 3.6% |
| repetitive-512 | 1428.4 | 1768.0 | 1.24× (1.22–1.34) | 9.9% / 0.6% |
| repetitive-1m | 6741.7 | 7013.7 | 1.04× (1.03–1.05) | 1.3% / 0.8% |

## Raw direct — level 6 decompression, libdeflate-produced fixtures

Both implementations decode the same exact compressed bytes in each row.

| Corpus | flate MiB/s | libdeflate MiB/s | libdeflate / flate (paired range) | Spread flate / libdeflate |
| --- | ---: | ---: | ---: | ---: |
| repetitive-256k | 11684.6 | 13884.1 | 1.20× (1.14–1.22) | 2.8% / 5.6% |
| random-256k | 39213.1 | 71242.5 | 1.81× (1.80–1.84) | 0.8% / 1.6% |
| mixed-256k | 13524.6 | 22477.2 | 1.66× (1.62–1.68) | 1.6% / 2.3% |
| source | 397.5 | 1819.8 | 4.58× (4.46–4.68) | 5.2% / 0.9% |
| json-256k | 781.9 | 2993.3 | 3.84× (3.64–3.94) | 2.9% / 5.2% |
| precompressed | 47014.0 | 92229.9 | 1.97× (1.90–2.02) | 8.2% / 2.8% |
| source-4k | 313.0 | 788.2 | 2.50× (2.47–2.58) | 4.1% / 3.6% |
| repetitive-512 | 289.8 | 291.0 | 1.00× (0.98–1.01) | 2.8% / 1.2% |
| repetitive-1m | 11872.4 | 15801.4 | 1.33× (1.31–1.35) | 1.4% / 3.8% |

## Interpretation

- Source L6 decode: flate **397.5–405.7 MiB/s**, libdeflate
  **1698.4–1819.8 MiB/s**. Depending on fixture producer, paired libdeflate/flate
  speed is **4.20–4.58×**.
- JSON L6 decode: flate **711.2–781.9 MiB/s**, libdeflate
  **2445.4–2993.3 MiB/s**, with paired speed **3.46–3.84×**.
- The previous 04:03 UTC run reported source **4.86–5.28×** and JSON
  **3.69–4.18×**. The gap is smaller in this new paired run. For isolated
  optimization gains, use the alternating frozen-baseline
  [before/after study](./decode-source-json-20260911.md), not cross-run quotients.
- Repetitive-256k decode is near parity on flate's stream (0.97×) and 1.20×
  in libdeflate's favor on libdeflate's stream. Producer-dependent results
  show why cross-decoding matters.
- On the six main L6 corpora, compression ratios of speed are 1.40–2.83×.
  The decoder-only change does not alter the compression algorithm or quality.
  Source compressed sizes are 65565 / 65435 bytes; JSON is 41115 / 37082 bytes.

## Noise and limits

**11 of 138 summaries exceed 10% spread** (127 below the threshold). All L6
summaries, including the focused source/JSON results, are below the threshold.
The following affected pairs have no published multiplier:

| Corpus | Level | Operation | Fixture producer | Noisy implementation | Spread |
| --- | ---: | --- | --- | --- | ---: |
| random-256k | 0 | compress | none | flate | 15.6% |
| mixed-256k | 1 | compress | none | flate | 12.9% |
| source | 1 | compress | none | libdeflate | 20.0% |
| source | 1 | decompress | libdeflate | flate | 19.3% |
| source | 0 | compress | none | flate | 16.2% |
| precompressed | 1 | compress | none | libdeflate | 15.9% |
| precompressed | 1 | decompress | flate | libdeflate | 45.1% |
| precompressed | 1 | decompress | libdeflate | libdeflate | 46.4% |
| precompressed | 9 | compress | none | libdeflate | 12.7% |
| precompressed | 9 | decompress | flate | libdeflate | 59.3% |
| precompressed | 9 | decompress | libdeflate | libdeflate | 14.6% |

No noisy samples were discarded or selectively replaced. These are warm-buffer
measurements without CPU affinity or thermal control. Very high stored-data
decode rates describe repeated cache-resident copies, not disk or sustained
large-working-set throughput. This run does not measure one-shot wrappers,
streaming, JS/Wasm, peak memory or fzip. See [methodology](./README.md).

## Artifacts and reproducibility

Current run: `.local/bench/20260911T044132.227495Z/` (local, Git-ignored).
The earlier 04:03 UTC run remains at `.local/bench/20260911T040357.563461Z/`.

- `report.md`: all L0/L1/L6/L9 configurations, including noisy rows.
- `summary.json`, `comparisons.json`, `samples.jsonl`: throughput, paired
  ratios and every raw sample.
- `metadata.json`, build logs, `source.diff`, source snapshots and binary
  hashes: measured versions and exact workflow.
- `corpus.json`, `fixtures.json`, and exact input/compressed files:
  reproducible data and hashes.

Source corpus SHA-256:
`cf1e62e2fae8f95cc7b94018abb0648a130f83e7f307fc7b8f03ac64e64cffec`.

Precompressed corpus SHA-256 (69223 bytes):
`e2aa3ce54481208808b746ce0cca45445a9ad696894c5dac812da83b111b5fda`.

These match the frozen prior corpus. Retain the local artifacts when sharing
or reproducing results; the committed document contains selected tables.
