# MacBook Pro M3 Max Results

These are reference measurements for the MoonBit implementation in this
repository and the standalone `libdeflate` C runner. The retained C baseline
was collected on 2026-09-06; direct-buffer MoonBit and exchanged-fixture runs
were collected on 2026-09-07.

## Device and Toolchain

- Apple MacBook Pro, `Mac15,9`, Apple M3 Max
- 16 CPU cores (12 performance, 4 efficiency), 128 GB RAM
- macOS `26.6.2` (`25G83`), `arm64`
- Moon `0.1.20260901`, moonc `0.10.11+5876a226e-nightly`
- Apple clang `21.0.0` from Xcode (`-O3 -DNDEBUG` for the C runner)
- libdeflate `1.25` from Homebrew
- MoonBit source at `5522fd1` plus the uncommitted direct-buffer API/benchmark patch
- retained libdeflate measurements from working tree `5670747`

## Method

The parity corpus is exactly 262,144 bytes (256 KiB):

- `repetitive`: repeated `The quick brown fox...` phrase
- `random`: deterministic LCG bytes, seed `0x12345678`
- `mixed`: 128 KiB `repetitive` followed by 128 KiB `random`

MoonBit raw DEFLATE was rerun with native release code on 2026-09-07. Each raw
sample reuses a whole-buffer `Compressor` or `Decompressor` plus a fixed
caller-owned output buffer allocated before timing. The benchmark reports mean
time per operation; the MiB/s values below are `0.25 / mean_seconds`.

The libdeflate C runner values were retained from the 2026-09-06 run, compiled
with `-O3 -DNDEBUG` and run with 1,000 iterations (250 MiB processed per
phase). It warms the codec, then reuses the compressor/decompressor and output
buffers inside the timed loops.

The direct raw APIs now have the same shape: both accept a complete input buffer
and write into a caller-owned output buffer. Their parsers and block policies
still differ. The baseline decompression columns each use the implementation's
own L1/L6/L9 fixture; exchanged L6 fixtures are reported separately below.

No CPU affinity or thermal-isolation setup was used; treat these as same-machine
reference numbers rather than a reproducible hardware limit.

## Raw DEFLATE

Throughput in MiB/s. `MoonBit` is derived from its reported mean milliseconds;
`libdeflate` is the C runner's measured throughput.

| Level | Corpus | MoonBit direct compress | libdeflate compress | MoonBit direct decompress | libdeflate decompress |
| ---: | --- | ---: | ---: | ---: | ---: |
| 1 | repetitive | 499.4 | 1527.1 | 4371.4 | 11062.4 |
| 1 | random | 46.1 | 178.3 | 40257.6 | 68436.9 |
| 1 | mixed | 84.2 | 381.1 | 6324.8 | 21027.8 |
| 6 | repetitive | 496.8 | 1155.1 | 4369.9 | 13961.8 |
| 6 | random | 44.2 | 136.8 | 40322.6 | 69560.4 |
| 6 | mixed | 79.4 | 269.4 | 6340.9 | 22208.4 |
| 9 | repetitive | 482.8 | 1164.8 | 4359.2 | 13474.9 |
| 9 | random | 22.9 | 130.9 | 40453.1 | 67990.2 |
| 9 | mixed | 43.9 | 258.8 | 6313.1 | 21792.2 |

## Exchanged L6 Fixtures

All values are MiB/s. Fixture I/O and byte-for-byte output validation occur
before timing. `own` means the decoder consumes the stream produced by the same
implementation; the two cross columns consume the other implementation's
stream. The shown fixture sizes are L6 raw DEFLATE bytes.

| Corpus | C fixture | MoonBit fixture | MoonBit decode own | MoonBit decode C | C decode own | C decode MoonBit |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| repetitive | 833 | 1033 | 4369.9 | 6546.2 | 13961.8 | 6659.2 |
| random | 262169 | 262224 | 40322.6 | 39370.1 | 69560.4 | 72590.0 |
| mixed | 131646 | 131740 | 6340.9 | 9117.4 | 22208.4 | 11987.5 |

## zlib and gzip Wrappers

The benchmark executes L1/L6/L9. The table records L6, again in MiB/s, with
each cell formatted as `compress / decompress`.

These remain allocation-inclusive MoonBit one-shot API measurements, whereas
the C runner still reuses its objects and buffers. They are therefore useful
application-level reference values, not parity measurements.

| Corpus | MoonBit zlib | libdeflate zlib | MoonBit gzip | libdeflate gzip |
| --- | ---: | ---: | ---: | ---: |
| repetitive | 163.4 / 177.3 | 1052.1 / 11459.0 | 211.9 / 213.7 | 1144.1 / 11242.0 |
| random | 33.2 / 186.6 | 136.9 / 30592.3 | 34.9 / 227.3 | 137.1 / 32383.4 |
| mixed | 54.8 / 179.9 | 263.5 / 16179.1 | 59.7 / 215.5 | 261.1 / 16765.0 |

## Conclusions

- Against the retained L6 C reference, libdeflate is about `2.3x` faster at raw
  compression on repetitive data, `3.1x` on random data, and `3.4x` on mixed
  data.
- Against the retained L6 C reference, libdeflate is about `3.2x` faster at raw
  decompression on repetitive data, `1.7x` on random data, and `3.5x` on
  mixed data.
- The direct APIs remove MoonBit result-buffer allocation and streaming state
  machine overhead from raw comparison. They do not change the allocation-
  inclusive `deflate_all` / `inflate_all` or wrapper measurements above.
- Fixture choice matters substantially for compressible and mixed data: C's
  repetitive decode rate drops from `13961.8` to `6659.2 MiB/s` on MoonBit's
  stream, while MoonBit rises from `4369.9` to `6546.2 MiB/s` on C's stream.
  Random data is nearly fixture-neutral. Do not attribute a same-encoder
  decompression gap solely to either implementation's decoder.
- These remain same-machine reference numbers rather than controlled hardware
  limits: most C baseline values were retained from the preceding day, and
  CPU affinity or thermal isolation was not used.

## Reproduction Commands

Use the common corpus generation and runner commands in the
[benchmark README](./README.md). The MoonBit commands used for this report are
the raw direct cases at indexes `0` and `1`, plus cross-fixture index `3`; the
retained C baseline and exchanged-fixture runs used `-n 1000`.
