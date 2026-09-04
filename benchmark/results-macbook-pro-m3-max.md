# MacBook Pro M3 Max Results

These are reference measurements for the MoonBit implementation in this
repository and the standalone `libdeflate` C runner. They were collected on
2026-09-04.

## Device and Toolchain

- Apple MacBook Pro, `Mac15,9`, Apple M3 Max
- 16 CPU cores (12 performance, 4 efficiency), 128 GB RAM
- macOS `26.6.2` (`25G83`), `arm64`
- Moon `0.1.20260901`, moonc `0.10.11+5876a226e-nightly`
- Apple clang `21.0.0` from Xcode (`-O3 -DNDEBUG` for the C runner)
- libdeflate `1.25` from Homebrew
- repository working tree at `0183fac`

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
| 1 | repetitive | 186.6 | 1716.0 | 385.9 | 11315.3 |
| 1 | random | 37.0 | 177.7 | 13616.6 | 69367.4 |
| 1 | mixed | 64.4 | 409.4 | 730.7 | 21985.8 |
| 6 | repetitive | 186.6 | 1184.5 | 382.4 | 13159.3 |
| 6 | random | 37.4 | 142.2 | 13041.2 | 70561.7 |
| 6 | mixed | 62.8 | 280.3 | 733.6 | 22986.4 |
| 9 | repetitive | 174.8 | 1152.6 | 387.2 | 13509.9 |
| 9 | random | 27.9 | 135.4 | 13276.7 | 70382.9 |
| 9 | mixed | 49.6 | 269.8 | 736.7 | 22845.7 |

For the C output sizes, raw DEFLATE produced 833/874 bytes for repetitive data
(L6/L9 versus L1), 262,169 bytes for random data, and 131,646/131,574 bytes
for mixed data (L6/L9 versus L1). These sizes describe the libdeflate output,
not the MoonBit output.

## zlib and gzip Wrappers

The benchmark executes L1/L6/L9. The table records L6, again in MiB/s, with
each cell formatted as `compress / decompress`.

| Corpus | MoonBit zlib | libdeflate zlib | MoonBit gzip | libdeflate gzip |
| --- | ---: | ---: | ---: | ---: |
| repetitive | 109.2 / 146.2 | 1142.5 / 11496.4 | 126.3 / 167.8 | 1153.8 / 11006.9 |
| random | 31.6 / 154.3 | 135.2 / 31613.6 | 33.5 / 179.9 | 142.4 / 32907.7 |
| mixed | 49.8 / 151.5 | 275.7 / 16568.4 | 53.0 / 176.1 | 271.7 / 16848.6 |

## Conclusions

- At L6 raw compression, libdeflate is about `6.4x` faster on repetitive data,
  `3.8x` on random data, and `4.5x` on mixed data.
- At L6 raw decompression, libdeflate is about `34x` faster on repetitive data,
  `5.4x` on random data, and `31x` on mixed data. The random-data gap is much
  smaller in this run because the current MoonBit native backend handles the
  stored/copy path substantially faster than the previous toolchain.
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
