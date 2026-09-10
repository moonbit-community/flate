# Benchmarks

Paired native-release benchmarks for flate and libdeflate.
Latest results: [MacBook Pro M3 Max](./results-macbook-pro-m3-max.md).

## Run

From the repository root; requires Python 3.10+, MoonBit, a C compiler,
`pkg-config`, and the libdeflate development package.

```sh
python3 benchmark/run.py                                      # quick: 3 rounds, >=40 ms
python3 benchmark/run.py --profile quick --rounds 5 --milliseconds 100
python3 benchmark/run.py --profile smoke                      # validation: 1 round, >=2 ms
python3 benchmark/run.py --profile full                       # broader: 7 rounds, >=150 ms
python3 benchmark/run.py --corpus /path/to/application-data.bin
```

Each run builds fresh runners and saves results to a new
`.local/bench/<UTC timestamp>/` directory. Use `--output DIR` to choose another
new directory. Timed workloads run sequentially; a run takes several minutes.

## What is measured

- **Raw direct:** reused codecs and caller-owned output buffers on both sides.
- **One-shot raw/zlib/gzip:** per-operation allocation and release are included.
  For decompression, libdeflate knows the output size; flate grows its output.
- Both decoders decode **both producers' exact fixtures**. Python zlib also
  validates full output and stream termination.
- Rates are median MiB/s. Warmup, calibration, compilation and file I/O are
  outside the measured batch. Implementation/operation order alternates by round.

Quick covers repeated text, deterministic SHAKE random bytes, mixed data,
repository source, synthetic JSON and precompressed source at L1/L6/L9;
it adds small/large inputs, L0 baselines and L6 one-shot cases.
Full expands corpus and format coverage. Repository-derived inputs change with
the code; compare saved hashes before claiming a before/after improvement.

## Read the results

Same numeric compression levels do **not** imply equal compression quality:
compare compressed sizes alongside throughput. Direct and one-shot results have
different allocation boundaries and should not be mixed.

Spread is `(max - min) / median` of seconds per operation, not a confidence
interval. Rows above 10% are marked `NOISY`; rerun before drawing conclusions.
Buffers are warm; CPU affinity and thermal state are uncontrolled. Results do
not cover JS/Wasm throughput, peak memory or streaming chunk-size effects.

Each completed run contains:

- `report.md` and `summary.json`: throughput, sizes and spread.
- `samples.jsonl`: raw measurements.
- `metadata.json`, build logs and source snapshot: versions, commands and hashes.
- Corpus/fixture manifests and exact input/compressed files.

An incomplete run has no final report. Local artifacts are ignored by Git;
the linked device report records the key results.

Harness checks:

```sh
python3 -m unittest discover -s benchmark -p '*_test.py'
```
