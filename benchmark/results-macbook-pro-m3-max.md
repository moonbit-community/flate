# MacBook Pro M3 Max Results

These are reference measurements for the MoonBit implementation in this
repository and the standalone `libdeflate` C runner. They were collected on
2026-09-03.

## Device and Toolchain

- Apple MacBook Pro, `Mac15,9`, Apple M3 Max
- 16 CPU cores (12 performance, 4 efficiency), 128 GB RAM
- macOS `26.6.2` (`25G83`), `arm64`
- Moon `0.1.20260901`, moonc `0.10.11+fa880aae3-nightly`
- Apple clang `21.0.0` (`-O3 -DNDEBUG` for the C runner)
- libdeflate `1.25` from Homebrew
- repository working tree at `1c5e055`

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
| 1 | repetitive | 179.9 | 1673.6 | 484.5 | 10939.5 |
| 1 | random | 34.2 | 172.5 | 504.5 | 67567.6 |
| 1 | mixed | 58.1 | 371.4 | 474.0 | 21818.8 |
| 6 | repetitive | 176.1 | 1132.1 | 478.4 | 13648.5 |
| 6 | random | 33.9 | 134.4 | 461.9 | 66880.7 |
| 6 | mixed | 57.5 | 262.0 | 474.5 | 21960.7 |
| 9 | repetitive | 174.8 | 1154.3 | 457.3 | 13467.7 |
| 9 | random | 27.7 | 129.1 | 445.7 | 67953.3 |
| 9 | mixed | 48.9 | 253.5 | 486.6 | 21139.9 |

For the C output sizes, raw DEFLATE produced 833/874 bytes for repetitive data
(L6/L9 versus L1), 262,169 bytes for random data, and 131,646/131,574 bytes
for mixed data (L6/L9 versus L1). These sizes describe the libdeflate output,
not the MoonBit output.

## zlib and gzip Wrappers

The benchmark executes L1/L6/L9. The table records L6, again in MiB/s, with
each cell formatted as `compress / decompress`.

| Corpus | MoonBit zlib | libdeflate zlib | MoonBit gzip | libdeflate gzip |
| --- | ---: | ---: | ---: | ---: |
| repetitive | 105.9 / 142.9 | 1114.0 / 11187.7 | 123.8 / 164.5 | 1132.1 / 11170.2 |
| random | 29.3 / 147.9 | 131.1 / 30883.3 | 30.3 / 172.4 | 133.8 / 31577.6 |
| mixed | 46.9 / 144.5 | 258.0 / 16224.3 | 50.1 / 167.8 | 259.6 / 16195.9 |

## Conclusions

- At L6 raw compression, libdeflate is about `6.4x` faster on repetitive data,
  `4.0x` on random data, and `4.6x` on mixed data.
- At L6 raw decompression, the measured gaps are about `28x`, `145x`, and
  `46x`, respectively. The very large random-data gap is dominated by the
  stored-block/copy path and should not be generalized to all DEFLATE streams.
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
