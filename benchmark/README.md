# Benchmarks

## Paired Suite (Recommended)

Run from the repository root. Requires Python 3.10+, the MoonBit toolchain,
a C compiler, `pkg-config`, and an installed libdeflate development package.
No Python packages or corpus downloads are needed.

```sh
python3 benchmark/run.py                    # quick: 3 rounds, >=40 ms per sample
python3 benchmark/run.py --profile smoke    # validation only, 1 round, >=2 ms
python3 benchmark/run.py --profile full     # 7 rounds, >=150 ms, broader coverage
python3 benchmark/run.py --corpus /path/to/application-data.bin
python3 benchmark/run.py --rounds 5 --milliseconds 100
```

Each run builds fresh native release executables into a unique
`.local/bench/<UTC timestamp>/` directory and prints progress. `--output DIR`
selects a different **new** directory; existing results are never overwritten.
Quick is intended for approximately one to a few minutes on a development
laptop, including compilation. Full can take several minutes or longer.
Large external files and slow codecs can exceed the nominal per-sample budget.

The suite runs no timed workloads concurrently. Each configuration contains
compression plus decoding **both producers' exact fixtures**, by both decoders.
Implementation and operation order alternate across rounds. Input loading,
fixture generation, validation, process startup and compilation are outside
the timed batch. Three warmup calls precede geometric batch calibration;
only the final batch at or above the requested duration becomes a sample.
There is no per-operation timer. Codec-internal allocation remains measured.

### Measurement Boundaries

| Group | flate | libdeflate | Interpretation |
| --- | --- | --- | --- |
| raw direct | Reused `Compressor` / `Decompressor`, caller-owned output | Reused codecs, caller-owned output | Primary implementation comparison |
| one-shot raw/zlib/gzip compression | Public convenience API; result created/released per operation | Codec and result buffer allocated/freed per operation | Application cost; includes allocation |
| one-shot raw/zlib/gzip decompression | Public grow-output API; allocation and release per operation | Codec and exact-size result allocated/freed per operation | C requires known output size; application comparison, not equal information |

Only raw direct has a multiplier column populated. Compression still compares
the same **numeric level**, not equal quality: read compressed byte counts
alongside speed and compare neighboring levels. There is no aggregate multiplier.
Smoke or runs with fewer than three rounds suppress multipliers entirely.
Wrapper fixtures have one member, no dictionary and no trailing bytes; both
implementations verify checksums. This does not compare every streaming or
multi-member API feature. Direct raw and convenience raw fixtures are generated
separately, so a future difference between the encoder paths stays visible.

All fixtures are validated against the full source bytes by Python zlib,
including end-of-stream and absence of trailing data. Each decoder runner also
validates before and after timing. Direct buffers are checked after the timed
loop; one-shot results are released inside it, with an additional untimed
validation. Decode errors terminate the run instead of becoming empty results.
An incomplete run has raw samples but no final report; do not treat it as complete.

### Coverage

Quick includes 256 KiB repeated text, deterministic SHAKE-generated random
bytes, half-text/half-random, actual repository source (up to 256 KiB), synthetic
JSON, and precompressed source. Their direct compression levels are 1, 6 and 9.
It adds L6 cases at 512 bytes, 4 KiB and 1 MiB, and L0 stored baselines for random
and source. One-shot raw/zlib/gzip L6 runs cover repeated text, random and source.
Source and precompressed sizes are recorded exactly, not padded with repetitions.
JSON is a byte prefix of structured records, intended to model byte distribution;
it is not guaranteed to end at a complete JSON document boundary.

Full adds random data at 4 KiB and 1 MiB, source at 64 KiB, distance-one data,
L0 for all direct cases, and one-shot formats for all corpora. Smoke covers empty,
single-byte, 4 KiB source and 256 KiB mixed data with L0/L6 direct and L6 one-shot.
`--corpus` can be repeated; external inputs are copied into the result directory
and use the profile's level policy. Synthetic inputs are diagnostic cases, not a
claim to represent every application's data.

### Results and Limitations

- `report.md`: median throughput, compressed sizes, fixture producer and spread.
- `samples.jsonl`: every measured batch, seconds, iterations, round and identity.
- `summary.json`: median/min/max seconds per operation, throughput and spread.
- `metadata.json`: versions, platform, build commands, binary/library/source hashes.
- `build-*.log`: compilation logs and Moon's actual planned compiler commands.
- `source/`, `source.diff`: source snapshot (including new runner files) and tracked diff.
- `corpus.json`, `fixtures.json`, `corpus/`, `fixtures/`: exact bytes and SHA-256 hashes.

Spread is `(max - min) / median` of per-operation times, not a confidence
interval. Above 10% the report marks `NOISY`; rerun with longer samples before
using those rows to prioritize work. A single round cannot establish stability.
The CPU is not pinned, thermal state is not controlled, and buffers are warm;
these are development comparisons, not cold-cache or DRAM bandwidth limits.
The Moon native compiler's defaults and the installed libdeflate build can
differ; recorded build commands make this visible rather than claiming identical
compiler optimization settings. On macOS, machine metadata uses `sysctl` and
`otool`, which require permission in some sandboxes.

The suite tests no JS/Wasm throughput, peak memory, standalone checksums,
streaming chunk-size sensitivity, split/optimal parser curves, or multi-member
gzip. Those need dedicated experiments. In particular, do not attribute the
wrapper difference entirely to checksums or the same-level compression
difference entirely to implementation overhead.

Harness checks:

```sh
python3 -m unittest discover -s benchmark -p '*_test.py'
python3 benchmark/run.py --profile smoke
```

## Historical and Individual Benchmarks

The measurements and commands below predate the paired suite. Keep their stated
boundaries when interpreting them; do not combine their ratios with a new run.

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
