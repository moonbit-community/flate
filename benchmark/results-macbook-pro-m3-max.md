# MacBook Pro M3 Max Results

These are reference measurements for the MoonBit implementation in this
repository and the standalone `libdeflate` C runner. They were collected on
2026-09-06.

## Device and Toolchain

- Apple MacBook Pro, `Mac15,9`, Apple M3 Max
- 16 CPU cores (12 performance, 4 efficiency), 128 GB RAM
- macOS `26.6.2` (`25G83`), `arm64`
- Moon `0.1.20260901`, moonc `0.10.11+5876a226e-nightly`
- Apple clang `21.0.0` from Xcode (`-O3 -DNDEBUG` for the C runner)
- libdeflate `1.25` from Homebrew
- repository working tree at `5670747`

## Method

The parity corpus is exactly 262,144 bytes (256 KiB):

- `repetitive`: repeated `The quick brown fox...` phrase
- `random`: deterministic LCG bytes, seed `0x12345678`
- `mixed`: 128 KiB `repetitive` followed by 128 KiB `random`

MoonBit was run with native release code. Its benchmark reports mean time per
operation; the MiB/s values below are `0.25 / mean_seconds`. The public
one-shot API allocates its output inside the timed operation.

The C runner was compiled with `-O3 -DNDEBUG` and run with 1,000 iterations
(250 MiB processed per phase). It warms the codec, then reuses the
compressor/decompressor and output buffers inside the timed loops.

The C runner's decompression case uses the stream produced by libdeflate itself;
the MoonBit case uses the stream produced by `@flate`. Cross-decoder fixtures
are not part of this snapshot.

No CPU affinity or thermal-isolation setup was used; treat these as same-machine
reference numbers rather than a reproducible hardware limit.

## Raw DEFLATE

Throughput in MiB/s. `MoonBit` is derived from its reported mean milliseconds;
`libdeflate` is the C runner's measured throughput.

| Level | Corpus | MoonBit compress | libdeflate compress | MoonBit decompress | libdeflate decompress |
| ---: | --- | ---: | ---: | ---: | ---: |
| 1 | repetitive | 179.9 | 1527.1 | 3668.9 | 11062.4 |
| 1 | random | 34.9 | 178.3 | 16404.2 | 68436.9 |
| 1 | mixed | 60.4 | 381.1 | 5621.8 | 21027.8 |
| 6 | repetitive | 179.9 | 1155.1 | 3669.5 | 13961.8 |
| 6 | random | 34.4 | 136.8 | 13020.8 | 69560.4 |
| 6 | mixed | 59.1 | 269.4 | 5577.9 | 22208.4 |
| 9 | repetitive | 178.6 | 1164.8 | 3680.9 | 13474.9 |
| 9 | random | 28.5 | 130.9 | 13034.4 | 67990.2 |
| 9 | mixed | 49.4 | 258.8 | 5572.2 | 21792.2 |

For the C output sizes, raw DEFLATE produced 833/874 bytes for repetitive data
(L6/L9 versus L1), 262,169 bytes for random data, and 131,646/131,574 bytes
for mixed data (L6/L9 versus L1). These sizes describe the libdeflate output,
not the MoonBit output.

## zlib and gzip Wrappers

The benchmark executes L1/L6/L9. The table records L6, again in MiB/s, with
each cell formatted as `compress / decompress`.

| Corpus | MoonBit zlib | libdeflate zlib | MoonBit gzip | libdeflate gzip |
| --- | ---: | ---: | ---: | ---: |
| repetitive | 106.8 / 144.5 | 1052.1 / 11459.0 | 125.6 / 166.7 | 1144.1 / 11242.0 |
| random | 31.1 / 150.6 | 136.9 / 30592.3 | 32.3 / 174.8 | 137.1 / 32383.4 |
| mixed | 48.2 / 147.1 | 263.5 / 16179.1 | 52.6 / 170.1 | 261.1 / 16765.0 |

## Conclusions

- At L6 raw compression, libdeflate is about `6.4x` faster on repetitive data,
  `4.0x` on random data, and `4.6x` on mixed data.
- At L6 raw decompression, libdeflate is about `3.8x` faster on repetitive data,
  `5.3x` on random data, and `4.0x` on mixed data. The MoonBit raw decoder is
  substantially faster in this sample than in the September 4 measurement;
  only the current sample should be used for comparison.
- The gap is not a pure algorithm comparison: MoonBit's public one-shot API
  allocates its returned `Bytes` during the timed operation, while the C runner
  reuses buffers and codec objects. The C and MoonBit decoders also consume
  different encoder outputs in this snapshot.
- These numbers establish a useful native performance baseline and identify
  libdeflate as the speed reference. A stricter codec-only comparison would
  need exchanged compressed fixtures and a MoonBit benchmark that reuses output
  storage; an allocation-inclusive comparison would require an equivalent C
  mode that allocates per operation.

## Reproduction Commands

Use the common corpus generation and runner commands in the
[benchmark README](./README.md). The exact MoonBit commands used for this
report are the three parity cases at indexes `0`, `1`, and `2` in
`bench_flate.mbt`; the C measurements used `-n 1000`.
