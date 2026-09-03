# Benchmarks

This directory contains the MoonBit benchmark and the standalone C runner used
to compare the implementation with `libdeflate`:

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
```

The MoonBit benchmark reports mean time per operation. For the 256 KiB parity
cases, convert a mean in seconds to MiB/s with `0.25 / mean_seconds`.

## Run libdeflate

Build the C runner with the installed `libdeflate` package:

```sh
cc -O3 -DNDEBUG benchmark/bench_libdeflate.c \
  $(pkg-config --cflags --libs libdeflate) \
  -o /tmp/bench_libdeflate
/tmp/bench_libdeflate -f raw -l 6 -n 1000 corpus.bin
```

The runner warms the codec, then reuses codec objects and output buffers during
the timed loops. `-f` accepts `raw`, `zlib`, or `gzip`; `-l` accepts levels
`0..12`; and `-n` sets the timed iteration count.

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
