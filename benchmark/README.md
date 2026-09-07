# Benchmarks

This directory contains the MoonBit benchmark and the standalone C runner used
to compare raw DEFLATE throughput with `libdeflate`:

- [`bench_flate.mbt`](./bench_flate.mbt): native MoonBit raw DEFLATE, zlib, and
  gzip measurements.
- [`bench_libdeflate.c`](./bench_libdeflate.c): file-backed `libdeflate` runner
  for raw DEFLATE, zlib, and gzip.

## Results

Device-specific measurements are kept in separate files so results from other
machines can be added without rewriting this overview:

- [MacBook Pro M3 Max](./results-macbook-pro-m3-max.md)

Use the same corpus, format, level, and iteration count when comparing reports.
The result files record each device's toolchain and measurement caveats.

## Run MoonBit

Build and run the benchmark package in native release mode:

```sh
moon bench --package moonbit-community/flate/benchmark \
  --release --target native --no-parallelize \
  --file bench_flate.mbt --index 0  # raw compression
moon bench --package moonbit-community/flate/benchmark \
  --release --target native --no-parallelize \
  --file bench_flate.mbt --index 1  # raw decompression
moon bench --package moonbit-community/flate/benchmark \
  --release --target native --no-parallelize \
  --file bench_flate.mbt --index 2  # zlib/gzip wrappers
FLATE_C_FIXTURE=/tmp/flate-libdeflate-l6.deflate \
  FLATE_C_FIXTURE_SOURCE=/tmp/flate-repetitive-256k \
  moon bench --package moonbit-community/flate/benchmark \
  --release --target native --no-parallelize \
  --file bench_flate.mbt --index 3  # MoonBit decodes a C fixture
```

The first two MoonBit benchmark groups are raw DEFLATE direct-buffer tests.
They create a whole-buffer `Compressor` or `Decompressor` plus its fixed output
buffer before timing, then reuse both in every iteration. For the 256 KiB
parity cases, convert a mean in seconds to MiB/s with `0.25 / mean_seconds`.

This aligns allocation lifetime and API shape with the C runner: each side
receives a complete input buffer and writes directly to a caller-owned output
buffer. The LZ77 parser, block policy, and decompression fixture still differ;
use exchanged fixtures for decoder comparisons.

The zlib/gzip and other one-shot groups are allocation-inclusive public API
measurements. Do not compare those numbers directly with the C runner unless it
is run in an equivalent per-operation allocation mode.

## Run libdeflate

Build the C runner with the installed `libdeflate` package:

```sh
cc -O3 -DNDEBUG benchmark/bench_libdeflate.c \
  $(pkg-config --cflags --libs libdeflate) \
  -o /tmp/bench_libdeflate
/tmp/bench_libdeflate -f raw -l 6 -n 1000 corpus.bin
```

The runner warms the codec, then reuses codec objects and output buffers during
the timed loops. This matches MoonBit's raw direct-buffer boundary. `-f`
accepts `raw`, `zlib`, or `gzip`; `-l` accepts levels `0..12`; and `-n` sets
the timed iteration count.

## Exchanged Fixtures

The raw direct-buffer benchmarks accept the same complete input/output shape as
the C runner. Decode both implementations' streams to isolate decoder behavior
from the encoder that produced the fixture.

```sh
# MoonBit writes a raw DEFLATE fixture; C then benchmarks decoding it.
moon run --release --target native benchmark/fixture_export \
  /tmp/flate-repetitive-256k /tmp/flate-moonbit-l6.deflate 6
/tmp/bench_libdeflate -f raw -l 6 -n 1000 \
  --decompress-fixture /tmp/flate-moonbit-l6.deflate \
  /tmp/flate-repetitive-256k

# C writes its raw DEFLATE fixture; MoonBit's index 3 benchmarks decoding it.
/tmp/bench_libdeflate -f raw -l 6 -n 1000 \
  --write-compressed /tmp/flate-libdeflate-l6.deflate \
  /tmp/flate-repetitive-256k
FLATE_C_FIXTURE=/tmp/flate-libdeflate-l6.deflate \
  FLATE_C_FIXTURE_SOURCE=/tmp/flate-repetitive-256k \
  moon bench --package moonbit-community/flate/benchmark \
  --release --target native --no-parallelize \
  --file bench_flate.mbt --index 3
```

Use the matching corpus file for both commands. The C runner verifies that a
provided decompression fixture reproduces that file before timing; MoonBit's
cross-fixture benchmark verifies the full decoded payload before timing.

## Corpus

The parity corpus is exactly 262,144 bytes (256 KiB):

- `repetitive`: repeated `The quick brown fox...` phrase
- `random`: deterministic LCG bytes, seed `0x12345678`
- `mixed`: 128 KiB `repetitive` followed by 128 KiB `random`

These commands create matching files for the C runner:

```sh
perl -e 'my $n=262144; my $u="The quick brown fox jumps over the lazy dog. Pack my box. "; print substr($u x int(($n+length($u)-1)/length($u)),0,$n)' \
  > /tmp/flate-repetitive-256k

perl -e 'my $n=262144; my $s=0x12345678; for (1..$n) { $s=($s*1103515245+12345) & 0xffffffff; print pack("C",($s>>16)&0xff) }' \
  > /tmp/flate-random-256k

head -c 131072 /tmp/flate-repetitive-256k > /tmp/flate-mixed-256k
cat /tmp/flate-random-256k | head -c 131072 >> /tmp/flate-mixed-256k
```
