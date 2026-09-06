# MacBook Pro M3 Max Results

These are reference measurements for the MoonBit implementation in this
repository and the standalone `libdeflate` C runner. They were collected on
2026-09-06 (libdeflate) and 2026-09-07 (MoonBit).

## Device and Toolchain

- Apple MacBook Pro, `Mac15,9`, Apple M3 Max
- 16 CPU cores (12 performance, 4 efficiency), 128 GB RAM
- macOS `26.6.2` (`25G83`), `arm64`
- Moon `0.1.20260901`, moonc `0.10.11+5876a226e-nightly`
- Apple clang `21.0.0` from Xcode (`-O3 -DNDEBUG` for the C runner)
- libdeflate `1.25` from Homebrew
- MoonBit source at `5522fd1`, with the allocation-reuse benchmark update
- retained libdeflate measurements from working tree `5670747`

## Method

The parity corpus is exactly 262,144 bytes (256 KiB):

- `repetitive`: repeated `The quick brown fox...` phrase
- `random`: deterministic LCG bytes, seed `0x12345678`
- `mixed`: 128 KiB `repetitive` followed by 128 KiB `random`

MoonBit raw DEFLATE was rerun with native release code on 2026-09-07. Each raw
sample resets and reuses a streaming `Deflater` or `Inflater` plus a fixed
caller-owned output buffer allocated before timing. The benchmark reports mean
time per operation; the MiB/s values below are `0.25 / mean_seconds`.

The libdeflate C runner values were retained from the 2026-09-06 run, compiled
with `-O3 -DNDEBUG` and run with 1,000 iterations (250 MiB processed per
phase). It warms the codec, then reuses the compressor/decompressor and output
buffers inside the timed loops.

The C runner's decompression case uses the stream produced by libdeflate itself;
the MoonBit case uses the stream produced by `@flate` before timing.
Cross-decoder fixtures are not part of this snapshot. Allocation lifetime is
now aligned for raw DEFLATE, but the implementation paths are still different:
MoonBit drives a suspendable streaming state machine, while libdeflate receives
a direct input/output buffer call.

No CPU affinity or thermal-isolation setup was used; treat these as same-machine
reference numbers rather than a reproducible hardware limit.

## Raw DEFLATE

Throughput in MiB/s. `MoonBit` is derived from its reported mean milliseconds;
`libdeflate` is the C runner's measured throughput.

| Level | Corpus | MoonBit reusable compress | libdeflate compress | MoonBit reusable decompress | libdeflate decompress |
| ---: | --- | ---: | ---: | ---: | ---: |
| 1 | repetitive | 350.4 | 1527.1 | 1144.0 | 11062.4 |
| 1 | random | 39.0 | 178.3 | 1625.5 | 68436.9 |
| 1 | mixed | 69.8 | 381.1 | 1232.3 | 21027.8 |
| 6 | repetitive | 351.2 | 1155.1 | 1126.2 | 13961.8 |
| 6 | random | 38.0 | 136.8 | 1606.7 | 69560.4 |
| 6 | mixed | 66.5 | 269.4 | 1255.1 | 22208.4 |
| 9 | repetitive | 351.6 | 1164.8 | 1144.5 | 13474.9 |
| 9 | random | 21.3 | 130.9 | 1618.8 | 67990.2 |
| 9 | mixed | 42.0 | 258.8 | 1234.9 | 21792.2 |

For the C output sizes, raw DEFLATE produced 833/874 bytes for repetitive data
(L6/L9 versus L1), 262,169 bytes for random data, and 131,646/131,574 bytes
for mixed data (L6/L9 versus L1). These sizes describe the libdeflate output,
not the MoonBit output.

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

- Against the retained L6 C reference, libdeflate is about `3.3x` faster at raw
  compression on repetitive data, `3.6x` on random data, and `4.1x` on mixed
  data.
- Against the retained L6 C reference, libdeflate is about `12.4x` faster at
  raw decompression on repetitive data, `43.3x` on random data, and `17.7x` on
  mixed data.
- The raw measurements no longer include MoonBit codec/result-buffer allocation,
  but they exercise the streaming `Deflater`/`Inflater`, not the separate
  one-shot `deflate_all`/`inflate_all` code paths. Do not read the difference
  from the earlier one-shot figures as a regression in those APIs.
- Cross-column comparisons remain same-machine reference numbers rather than
  controlled hardware limits: the decoder fixtures differ by encoder and the
  C results were retained from the preceding day. A stricter comparison needs
  exchanged compressed fixtures and a direct MoonBit caller-buffer one-shot API.

## Reproduction Commands

Use the common corpus generation and runner commands in the
[benchmark README](./README.md). The MoonBit commands used for this report are
the three parity cases at indexes `0`, `1`, and `2` in `bench_flate.mbt`; the
retained C measurements used `-n 1000`.
