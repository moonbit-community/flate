# MacBook Pro M3 Max Results

The checksum rerun below records the latest zlib/gzip changes. The subsequent
full-suite baseline is retained with its original source and toolchain metadata.

## Checksum Optimization Rerun (2026-09-08)

This section is the latest measurement of the changed zlib/gzip paths.
The raw tables below remain the earlier baseline and were not rerun here.

- Source: `823123b` plus uncommitted Adler-32 block reduction and CRC-32
  slice-by-8 changes. The before executable predates both checksum changes.
- Both MoonBit executables use Moon `0.1.20260908 (b898b74)`,
  moonc `0.10.12+cb3c45ca7-nightly`, native release defaults.
  The before executable was retained at `.local/adler-before/`;
  the after executable was freshly built at `.local/checksum-final/`.
  The retained libdeflate 1.25 runner was executed again in this session.
- Run: `checksum-20260908T172046`. Metadata, executable hashes, corpus/fixture
  hashes and all 216 batch samples are in
  `.local/bench/checksum-20260908T172046/`.
- L6 one-shot, three rounds, at least 100 ms per final batch. Implementation
  order rotates between rounds; runs are sequential. The existing runner
  handles warmup, calibration and full-payload checks outside timing.
- Fixed inputs are from `20260908T035831.029182Z/corpus/`, including the
  unchanged source snapshot. Both MoonBit versions produce byte-identical
  zlib/gzip fixtures; Python zlib also validated all generated fixtures.
- Each decode row uses one shared fixture for all three implementations.
  `flate` means the optimized MoonBit fixture (identical to before);
  `C` means the libdeflate fixture.
- Rates below are median MiB/s. Gain is **after / before MoonBit**, not a
  libdeflate parity multiplier. C still knows the output size while MoonBit
  grows output; all one-shot implementations include allocation/release.
- Spread is (max-min)/median of seconds per operation. The three spread values
  are before / after / C. Above 10% is marked NOISY. These warm-buffer
  measurements have no CPU pinning or thermal isolation.
- Do not compare these rates directly with the older toolchain's tables.
  Streaming wrappers that use `update_byte` do not gain the new bulk checksum
  algorithms automatically; streaming and cold-start costs were not measured.

### Compression

| Corpus / format | Before | After | Gain | C reference | Compressed bytes flate / C | Spread before / after / C |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| source / zlib | 23.7 | 25.5 | 1.07x | 120.9 | 65030 / 64801 | 2.9% / 0.7% / 3.7% |
| source / gzip | 25.1 | 26.4 | 1.05x | 124.4 | 65042 / 64813 | 1.1% / 1.0% / 0.9% |
| json-256k / zlib | 42.6 | 49.6 | 1.16x | 158.1 | 41121 / 37088 | 0.4% / 1.2% / 0.5% |
| json-256k / gzip | 45.0 | 49.4 | 1.10x | 158.3 | 41133 / 37100 | 1.0% / 0.7% / 0.9% |
| repetitive-256k / zlib | 176.4 | 421.0 | 2.39x | 1167.1 | 1039 / 839 | 0.9% / 0.4% / 1.1% |
| repetitive-256k / gzip | 231.5 | 411.7 | 1.78x | 1168.1 | 1051 / 851 | 0.4% / 0.5% / 0.6% |
| random-256k / zlib | 38.1 | 41.8 | 1.10x | 142.5 | 262230 / 262175 | 1.1% / 5.3% / 1.6% |
| random-256k / gzip | 38.9 | 41.7 | 1.07x | 142.0 | 262242 / 262187 | 3.5% / 5.7% / 2.7% |

### Decompression

| Corpus / format | Shared fixture | Before | After | Gain | C reference | Spread before / after / C |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| source / zlib | flate | 100.5 | 154.4 | 1.54x | 1632.0 | 3.8% / 2.9% / 3.8% |
| source / zlib | C | 104.3 | 158.7 | 1.52x | 1818.8 | 0.5% / 1.7% / 0.8% |
| source / gzip | flate | 113.6 | 145.0 | 1.28x | 1676.8 | 4.3% / 0.9% / 1.3% |
| source / gzip | C | 114.8 | 146.5 | 1.28x | 1844.0 | 3.1% / 0.7% / 1.1% |
| json-256k / zlib | flate | 135.8 | 246.3 | 1.81x | 2390.0 | 0.3% / 0.6% / 0.5% |
| json-256k / zlib | C | 137.2 | 255.1 | 1.86x | 2930.9 | 1.0% / 3.0% / 1.7% |
| json-256k / gzip | flate | 153.3 | 216.2 | 1.41x | 2404.3 | 0.8% / 1.0% / 0.3% |
| json-256k / gzip | C | 156.1 | 223.9 | 1.43x | 2946.5 | 0.5% / 2.3% / 1.1% |
| repetitive-256k / zlib | flate | 192.1 | 529.9 | 2.76x | 5909.9 | 0.4% / 0.6% / 0.7% |
| repetitive-256k / zlib | C | 195.3 | 552.7 | 2.83x | 11444.9 | 0.3% / 1.1% / 0.9% |
| repetitive-256k / gzip | flate | 231.1 | 409.7 | 1.77x | 6017.0 | 0.7% / 0.7% / 1.0% |
| repetitive-256k / gzip | C | 235.1 | 422.1 | 1.80x | 11558.5 | 0.9% / 0.2% / 0.6% |
| random-256k / zlib | flate | 202.7 | 610.4 | 3.01x | 30408.1 | 0.8% / 0.2% / 1.0% |
| random-256k / zlib | C | 201.8 | 610.1 | 3.02x | 30428.2 | 0.6% / 0.5% / 0.9% |
| random-256k / gzip | flate | 244.7 | 456.8 | 1.87x | 29146.0 | 0.3% / 0.4% / 1.6% |
| random-256k / gzip | C | 246.2 | 457.9 | 1.86x | 28930.2 | 0.6% / 0.6% / 1.0% |

On flate fixtures, source/JSON zlib decompression improves 1.54x/1.81x and
gzip improves 1.28x/1.41x. Random zlib/gzip decompression improves 3.01x/1.87x.
These are end-to-end convenience API gains with unchanged compressed bytes,
not standalone checksum speedups. Remaining decoder and output-copy work limits
the application gain even when checksum work is greatly reduced.

To repeat an individual after sample with the retained fixture (repeat in
alternating before/after/C order for comparisons):

```sh
moon run --release --target native benchmark/runner \
  decompress oneshot zlib 6 \
  .local/bench/20260908T035831.029182Z/corpus/source.bin \
  .local/bench/checksum-20260908T172046/source-zlib-after.bin 100
```

## Earlier Full-Suite Baseline

The following sections describe the earlier pre-checksum run only.

These baseline measurements were collected on 2026-09-08 using the paired native
benchmark suite. Both implementations were measured in the same run.
They supersede the 2026-09-06/07 tables previously in this file; the old
LCG-based corpus and allocation boundaries are not directly comparable.

## Device, Toolchain and Source

- Apple MacBook Pro M3 Max, 16 CPU cores, arm64; macOS 26.6.2.
- Moon 0.1.20260907 (7aabba5); moonc 0.10.12+8a549c039-nightly.
- Apple clang 21.0.0 (clang-2100.1.1.101).
- Moon native release uses its default C compilation settings (`-O2`);
  the standalone C runner uses `-O3 -DNDEBUG -Wall -Wextra -Werror`.
  The installed libdeflate library has its own build settings.
- Homebrew libdeflate 1.25. The local v1.26 source checkout was not benchmarked.
- Source: `9c1735f` (lazy-parser hash-chain fix), plus the stored-output
  bulk-copy optimization and paired benchmark files committed with this report.
- Run ID: `20260908T035831.029182Z`; elapsed wall time including builds: 82.9 s.
- libdeflate dylib SHA-256:
  `3a81ef936db42d0f176688c55f0996e33bb6d457359436ac37f02ea523efeff9`.

Local raw samples, source snapshots, build commands and fixture manifests are
retained under `.local/bench/20260908T035831.029182Z/` (ignored by Git).
The tables below retain all measured configurations, including noisy rows.

## Method and Interpretation

The run used quick mode: three rounds, three warmup calls per sample, followed
by geometric batch calibration. Only the final batch lasting at least 40 ms
contributes a sample. Compilation, process startup, input I/O, fixture creation
and byte-for-byte validation are outside timing. Operation and implementation
order alternate between rounds; timed workloads never run concurrently.
There are 630 measured samples across 35 configurations.

Rates are MiB/s computed from median seconds per operation. Spread is
`(max - min) / median`, not a confidence interval; rows above 10% are marked
`NOISY` and should be rerun before drawing conclusions. Buffers are warm;
CPU affinity and thermal isolation were not controlled.

Raw direct reuses codec objects and caller-owned output buffers on both sides.
Internal allocations remain timed. Compression compares numeric levels, not
equal compressed size or search effort. Read speed and output size together.
Every decompression comparison uses the same exact producer fixture for both
decoders; there are no mixed-fixture decoder multipliers.

One-shot allocates/releases codecs and output per operation on the C side and
uses the public allocation-inclusive convenience APIs on the MoonBit side.
C decompression knows the exact output size; MoonBit grows its output.
These are application comparisons, so no parity multiplier is shown.
Wrapper fixtures contain one member, no dictionary and no trailing bytes;
both sides verify checksums. Python zlib independently validates every fixture,
including complete stream termination, before timing.

## Corpus

Random bytes now use deterministic SHAKE-256, not the old LCG.
Source is actual repository MoonBit code; JSON is a prefix of synthetic records;
precompressed is zlib-compressed repository source. The external source is the
exact original source corpus from the pre-fix run, preserved to compare changes
without accidentally changing the input when editing code.

| Corpus | Input bytes | SHA-256 |
| --- | ---: | --- |
| repetitive-256k | 262144 | `3d47a7a317de771c121ccd77c4f0e29cdcc4d8e83b50bf73af3b15d450e780c8` |
| random-256k | 262144 | `60818f09e6e977ee0b091f7e947c053e6d407a328cc8ed8954d80acbc349e023` |
| mixed-256k | 262144 | `be5326d39d83af2294d4dca5634e8e5a4e502eeb7a2bc8b04044c361b7add1e9` |
| source | 262144 | `c8613d12f7d2485b8fae7123f59aa82223ed0712f68f7998fd686dad441b8c9e` |
| json-256k | 262144 | `7994f48775f29cda7e9bbf01e95986f58f6f183c2103081e8472d8068cd7a398` |
| precompressed | 64691 | `474cf94f7e97b580e40460578237b804b3f4767365b62990f554ea3ddcf82489` |
| source-4k | 4096 | `53f24d015f1c4706245c10e0d3ae9cc309cf20306ca0b71d296422dc09cdf111` |
| repetitive-512 | 512 | `524a8ec3d3376e2455239d4ae21d6a383b7562270c4e35aa19ce21711a5e14ec` |
| repetitive-1m | 1048576 | `408aa6e8986f6fdb9832d8bdea3c3101822d5fbc07c9a3c2aee4f9bec10471b6` |
| external-0-source | 258564 | `9f843e26f5957a513847fb22afcfa7216a6d6d88b7cf21a19b35b704fd1387da` |

## Changes Observed on Identical Inputs

The original paired run was `20260908T032421.339781Z`, fix-only was
`20260908T035454.718327Z`, and the final run is identified above.
Source rows use the same preserved original input SHA-256 in all three runs.
All values below are flate direct compression MiB/s.

| Input / level | Before fix | Hash-chain fix only | Fix + stored optimization | Output bytes before / after fix |
| --- | ---: | ---: | ---: | ---: |
| Original source L6 | 14.57 | 26.73 | 25.65 | 68367 / 64201 |
| Original source L9 | 0.51 | 14.53 | 13.83 | 68207 / 63868 |
| JSON L9 | 0.81 | 11.38 | 11.43 | 45018 / 39208 |
| Random L0 | 1059.17 | 1062.46 | 58100.97 | 262169 / 262169 |
| Random L6 | 44.48 | 42.90 | 44.67 | 262224 / 262224 |

The hash-chain fix improves both speed and compressed size on source and JSON.
The subsequent stored optimization raises random L0 throughput about 54.7x
relative to fix-only; in the final run C is 1.16x faster on that case.
This does not imply a similar improvement at L6, where parsing and coding
work remains. Small differences between separate runs are not isolated causal
measurements; the final same-run C comparisons and spread are provided below.

## Raw Direct

| Format / corpus | L | Operation / fixture | flate MiB/s | C MiB/s | C / flate speed | Compressed bytes (flate / C, or shared fixture) | Spread flate / C |
| --- | ---: | --- | ---: | ---: | ---: | ---: | --- |
| raw / repetitive-256k | 1 | compress / none | 488.0 | 1752.5 | 3.59x | 1033 / 874 | 2.2% / 1.7% |
| raw / repetitive-256k | 1 | decompress / flate | 3985.1 | 6319.7 | 1.59x | 1033 | 1.7% / 2.1% |
| raw / repetitive-256k | 1 | decompress / libdeflate | 5453.4 | 11170.3 | 2.05x | 874 | 7.1% / 1.1% |
| raw / repetitive-256k | 6 | compress / none | 480.6 | 1150.5 | 2.39x | 1033 / 833 | 1.7% / 3.4% |
| raw / repetitive-256k | 6 | decompress / flate | 3973.8 | 6358.7 | 1.60x | 1033 | 1.7% / 3.5% |
| raw / repetitive-256k | 6 | decompress / libdeflate | 5878.5 | 14021.3 | 2.39x | 833 | 3.4% / 3.6% |
| raw / repetitive-256k | 9 | compress / none | 483.1 | 1188.7 | 2.46x | 1033 / 833 | 1.5% / 4.0% |
| raw / repetitive-256k | 9 | decompress / flate | 4056.2 | 6374.7 | 1.57x | 1033 | 4.0% / 0.5% |
| raw / repetitive-256k | 9 | decompress / libdeflate | 6128.3 | 13757.9 | 2.24x | 833 | 8.8% / 3.0% |
| raw / random-256k | 1 | compress / none | 45.6 | 175.7 | 3.86x | 262224 / 262169 | 4.3% / 4.3% |
| raw / random-256k | 1 | decompress / flate | 39127.2 | 70162.2 | 1.79x | 262224 | 5.1% / 6.3% |
| raw / random-256k | 1 | decompress / libdeflate | 38085.1 | 67319.7 | 1.77x | 262169 | 3.5% / 5.8% |
| raw / random-256k | 6 | compress / none | 44.7 | 137.5 | 3.08x | 262224 / 262169 | 5.7% / 7.8% |
| raw / random-256k | 6 | decompress / flate | 38689.2 | 69751.2 | 1.80x | 262224 | 2.4% / 3.6% |
| raw / random-256k | 6 | decompress / libdeflate | 37203.8 | 66966.4 | 1.80x | 262169 | 2.2% / 4.4% |
| raw / random-256k | 9 | compress / none | 45.1 | 130.4 | 2.89x | 262224 / 262169 | 3.2% / 3.9% |
| raw / random-256k | 9 | decompress / flate | 38161.8 | 67392.8 | 1.77x | 262224 | 5.0% / 6.0% |
| raw / random-256k | 9 | decompress / libdeflate | 38505.6 | 68589.0 | 1.78x | 262169 | 1.9% / 5.8% |
| raw / random-256k | 0 | compress / none | 58101.0 | 67489.4 | 1.16x | 262169 / 262169 | 1.2% / 0.9% |
| raw / random-256k | 0 | decompress / flate | 38944.7 | 70115.4 | 1.80x | 262169 | 2.3% / 3.2% |
| raw / random-256k | 0 | decompress / libdeflate | 38940.7 | 70030.3 | 1.80x | 262169 | 0.8% / 3.9% |
| raw / mixed-256k | 1 | compress / none | 81.0 | 391.4 | 4.83x | 131739 / 131577 | 5.2% / 3.6% |
| raw / mixed-256k | 1 | decompress / flate | 6105.6 | 11427.3 | 1.87x | 131739 | 1.4% / 1.9% |
| raw / mixed-256k | 1 | decompress / libdeflate | 9408.1 | 21171.9 | 2.25x | 131577 | 1.9% / 1.8% |
| raw / mixed-256k | 6 | compress / none | 80.5 | 248.9 | 3.09x | 131739 / 131646 | 2.8% / 4.6% |
| raw / mixed-256k | 6 | decompress / flate | 5896.3 | 11490.6 | 1.95x | 131739 | 5.0% / 2.6% |
| raw / mixed-256k | 6 | decompress / libdeflate | 8602.7 | 21683.9 | 2.52x | 131646 | 3.0% / 4.2% |
| raw / mixed-256k | 9 | compress / none | 81.4 | 254.6 | 3.13x | 131739 / 131646 | 3.2% / 3.0% |
| raw / mixed-256k | 9 | decompress / flate | 6092.7 | 11484.7 | 1.89x | 131739 | 3.8% / 4.7% |
| raw / mixed-256k | 9 | decompress / libdeflate | 8763.1 | 22233.8 | 2.54x | 131646 | 8.0% / 1.6% |
| raw / source | 1 | compress / none | 69.4 | 434.5 | 6.26x | 76160 / 73426 | 8.8% / 5.4% |
| raw / source | 1 | decompress / flate | 207.0 | 1332.6 | 6.44x | 76160 | 5.2% / 3.4% |
| raw / source | 1 | decompress / libdeflate | 221.4 | 1555.2 | 7.03x | 73426 | 3.9% / 3.9% |
| raw / source | 6 | compress / none | 24.3 | 115.4 | 4.74x | 65024 / 64795 | 2.2% / 5.5% |
| raw / source | 6 | decompress / flate | 249.5 | 1664.3 | 6.67x | 65024 | 5.5% / 2.8% |
| raw / source | 6 | decompress / libdeflate | 257.9 | 1804.2 | 7.00x | 64795 | 2.2% / 3.6% |
| raw / source | 9 | compress / none | 13.6 | 40.5 | 2.98x | 64694 / 63853 | 1.9% / 3.0% |
| raw / source | 9 | decompress / flate | 266.2 | 1690.7 | 6.35x | 64694 | 5.9% / 0.7% |
| raw / source | 9 | decompress / libdeflate | 276.1 | 1915.3 | 6.94x | 63853 | 0.2% / 1.8% |
| raw / source | 0 | compress / none | 60538.7 | 65302.0 | 1.08x | 262169 / 262169 | 10.4% / 1.1% NOISY |
| raw / source | 0 | decompress / flate | 38372.4 | 68097.6 | 1.77x | 262169 | 1.5% / 2.7% |
| raw / source | 0 | decompress / libdeflate | 37442.3 | 67545.1 | 1.80x | 262169 | 4.2% / 1.8% |
| raw / json-256k | 1 | compress / none | 134.7 | 715.2 | 5.31x | 49003 / 52148 | 4.8% / 4.5% |
| raw / json-256k | 1 | decompress / flate | 405.6 | 1926.8 | 4.75x | 49003 | 2.5% / 0.3% |
| raw / json-256k | 1 | decompress / libdeflate | 393.4 | 1964.5 | 4.99x | 52148 | 2.2% / 2.3% |
| raw / json-256k | 6 | compress / none | 49.2 | 156.5 | 3.18x | 41115 / 37082 | 4.7% / 7.7% |
| raw / json-256k | 6 | decompress / flate | 532.3 | 2415.8 | 4.54x | 41115 | 4.9% / 1.8% |
| raw / json-256k | 6 | decompress / libdeflate | 578.5 | 2990.7 | 5.17x | 37082 | 4.1% / 4.7% |
| raw / json-256k | 9 | compress / none | 11.4 | 15.8 | 1.38x | 39208 / 33044 | 7.2% / 2.9% |
| raw / json-256k | 9 | decompress / flate | 549.7 | 2483.4 | 4.52x | 39208 | 2.5% / 5.1% |
| raw / json-256k | 9 | decompress / libdeflate | 626.5 | 3022.2 | 4.82x | 33044 | 3.2% / 3.7% |
| raw / precompressed | 1 | compress / none | 50.7 | 276.5 | 5.46x | 64711 / 64696 | 9.5% / 7.6% |
| raw / precompressed | 1 | decompress / flate | 54194.2 | 79301.5 | 1.46x | 64711 | 3.9% / 8.3% |
| raw / precompressed | 1 | decompress / libdeflate | 55023.2 | 81665.7 | 1.48x | 64696 | 7.7% / 15.3% NOISY |
| raw / precompressed | 6 | compress / none | 52.3 | 180.6 | 3.45x | 64711 / 64696 | 13.0% / 5.2% NOISY |
| raw / precompressed | 6 | decompress / flate | 54215.0 | 77005.8 | 1.42x | 64711 | 5.3% / 3.8% |
| raw / precompressed | 6 | decompress / libdeflate | 54720.0 | 84695.4 | 1.55x | 64696 | 1.5% / 14.3% NOISY |
| raw / precompressed | 9 | compress / none | 51.2 | 180.2 | 3.52x | 64711 / 64696 | 6.6% / 5.6% |
| raw / precompressed | 9 | decompress / flate | 54514.2 | 74581.0 | 1.37x | 64711 | 4.5% / 4.8% |
| raw / precompressed | 9 | decompress / libdeflate | 53681.0 | 86238.1 | 1.61x | 64696 | 3.9% / 8.0% |
| raw / source-4k | 6 | compress / none | 54.9 | 194.8 | 3.55x | 1528 / 1503 | 3.1% / 5.1% |
| raw / source-4k | 6 | decompress / flate | 259.4 | 767.7 | 2.96x | 1528 | 2.8% / 3.1% |
| raw / source-4k | 6 | decompress / libdeflate | 259.4 | 772.5 | 2.98x | 1503 | 3.8% / 2.8% |
| raw / repetitive-512 | 6 | compress / none | 38.0 | 96.9 | 2.55x | 62 / 65 | 3.2% / 4.0% |
| raw / repetitive-512 | 6 | decompress / flate | 1055.8 | 1731.6 | 1.64x | 62 | 1.2% / 1.8% |
| raw / repetitive-512 | 6 | decompress / libdeflate | 263.3 | 281.6 | 1.07x | 65 | 4.5% / 2.1% |
| raw / repetitive-1m | 6 | compress / none | 497.6 | 1158.6 | 2.33x | 3980 / 3178 | 1.2% / 3.3% |
| raw / repetitive-1m | 6 | decompress / flate | 3999.2 | 6876.8 | 1.72x | 3980 | 6.4% / 3.1% |
| raw / repetitive-1m | 6 | decompress / libdeflate | 6018.7 | 15722.4 | 2.61x | 3178 | 6.8% / 1.2% |
| raw / external-0-source | 1 | compress / none | 68.1 | 432.3 | 6.35x | 75152 / 72473 | 3.7% / 9.3% |
| raw / external-0-source | 1 | decompress / flate | 202.2 | 1331.1 | 6.58x | 75152 | 4.1% / 1.9% |
| raw / external-0-source | 1 | decompress / libdeflate | 218.7 | 1553.9 | 7.10x | 72473 | 3.8% / 2.8% |
| raw / external-0-source | 6 | compress / none | 25.6 | 117.1 | 4.56x | 64201 / 63905 | 1.3% / 9.5% |
| raw / external-0-source | 6 | decompress / flate | 251.8 | 1661.6 | 6.60x | 64201 | 8.1% / 0.9% |
| raw / external-0-source | 6 | decompress / libdeflate | 250.3 | 1841.2 | 7.36x | 63905 | 5.1% / 4.7% |
| raw / external-0-source | 9 | compress / none | 13.8 | 40.4 | 2.92x | 63868 / 63119 | 2.7% / 4.1% |
| raw / external-0-source | 9 | decompress / flate | 249.6 | 1663.8 | 6.67x | 63868 | 8.0% / 3.8% |
| raw / external-0-source | 9 | decompress / libdeflate | 259.4 | 1850.4 | 7.13x | 63119 | 6.3% / 1.9% |

## oneshot

| Format / corpus | L | Operation / fixture | flate MiB/s | C MiB/s | C / flate speed | Compressed bytes (flate / C, or shared fixture) | Spread flate / C |
| --- | ---: | --- | ---: | ---: | ---: | ---: | --- |
| raw / repetitive-256k | 6 | compress / none | 479.0 | 1170.4 | n/a | 1033 / 833 | 2.1% / 3.5% |
| raw / repetitive-256k | 6 | decompress / flate | 3443.3 | 6358.8 | n/a | 1033 | 5.8% / 1.1% |
| raw / repetitive-256k | 6 | decompress / libdeflate | 4536.1 | 12909.1 | n/a | 833 | 2.7% / 6.9% |
| zlib / repetitive-256k | 6 | compress / none | 170.9 | 1128.3 | n/a | 1039 / 839 | 2.1% / 2.1% |
| zlib / repetitive-256k | 6 | decompress / flate | 189.5 | 5813.2 | n/a | 1039 | 3.5% / 7.8% |
| zlib / repetitive-256k | 6 | decompress / libdeflate | 187.3 | 11027.6 | n/a | 839 | 2.5% / 2.3% |
| gzip / repetitive-256k | 6 | compress / none | 221.0 | 1112.5 | n/a | 1051 / 851 | 2.9% / 2.3% |
| gzip / repetitive-256k | 6 | decompress / flate | 223.6 | 5779.3 | n/a | 1051 | 1.9% / 1.6% |
| gzip / repetitive-256k | 6 | decompress / libdeflate | 224.4 | 10854.4 | n/a | 851 | 0.7% / 2.3% |
| raw / random-256k | 6 | compress / none | 43.3 | 138.1 | n/a | 262224 / 262169 | 2.7% / 7.2% |
| raw / random-256k | 6 | decompress / flate | 12121.0 | 61915.2 | n/a | 262224 | 3.1% / 5.4% |
| raw / random-256k | 6 | decompress / libdeflate | 12080.9 | 62086.9 | n/a | 262169 | 7.2% / 2.8% |
| zlib / random-256k | 6 | compress / none | 37.6 | 139.7 | n/a | 262230 / 262175 | 4.4% / 7.2% |
| zlib / random-256k | 6 | decompress / flate | 198.7 | 30337.6 | n/a | 262230 | 5.0% / 3.6% |
| zlib / random-256k | 6 | decompress / libdeflate | 197.1 | 29959.0 | n/a | 262175 | 2.9% / 1.4% |
| gzip / random-256k | 6 | compress / none | 36.8 | 131.0 | n/a | 262242 / 262187 | 5.9% / 8.3% |
| gzip / random-256k | 6 | decompress / flate | 238.9 | 28812.6 | n/a | 262242 | 1.1% / 2.0% |
| gzip / random-256k | 6 | decompress / libdeflate | 239.1 | 29097.1 | n/a | 262187 | 1.9% / 3.2% |
| raw / source | 6 | compress / none | 25.4 | 117.2 | n/a | 65024 / 64795 | 6.0% / 5.9% |
| raw / source | 6 | decompress / flate | 250.0 | 1626.5 | n/a | 65024 | 0.9% / 1.2% |
| raw / source | 6 | decompress / libdeflate | 250.5 | 1823.6 | n/a | 64795 | 5.7% / 2.2% |
| zlib / source | 6 | compress / none | 23.5 | 117.6 | n/a | 65030 / 64801 | 2.0% / 6.6% |
| zlib / source | 6 | decompress / flate | 100.0 | 1596.7 | n/a | 65030 | 4.8% / 3.3% |
| zlib / source | 6 | decompress / libdeflate | 102.2 | 1780.8 | n/a | 64801 | 2.7% / 2.3% |
| gzip / source | 6 | compress / none | 24.2 | 117.5 | n/a | 65042 / 64813 | 4.0% / 1.8% |
| gzip / source | 6 | decompress / flate | 110.7 | 1637.5 | n/a | 65042 | 2.5% / 2.0% |
| gzip / source | 6 | decompress / libdeflate | 111.9 | 1783.8 | n/a | 64813 | 2.4% / 2.2% |

Empty-input throughput is zero; use summary.json median_seconds for latency.

Full-stream validation uses Python zlib in addition to both benchmark decoders.
Synthetic SHAKE bytes are deterministic; source is a snapshot of this repository,
JSON is synthetic structured data, and precompressed is zlib-compressed source.
Use --corpus FILE to add actual application data. Inspect time and size together
across levels; the tables do not assert equal quality or a universal aggregate speedup.


## Reproduction

From the repository root:

```sh
python3 benchmark/run.py --profile quick
# Exact extra input used for the original-source comparison, if retained locally:
python3 benchmark/run.py --profile quick \
  --corpus .local/bench/20260908T032421.339781Z/corpus/source.bin
```

The ordinary quick command reproduces the suite structure without the extra
historical source. Repository-derived corpus bytes can change as sources change;
compare recorded hashes before claiming a before/after speedup.
Use `--rounds 5 --milliseconds 100` for longer sampling, or `--profile full`
for broader coverage. See the [benchmark README](./README.md) for boundaries,
artifact descriptions and limitations.
