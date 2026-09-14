# Benchmarks

Paired native-release benchmarks for flate and libdeflate. The default suite
compares raw DEFLATE with reused codecs and preallocated output on both sides.
fzip is not included: its public compression API does not provide equivalent
caller-owned output and reusable workspace.

Latest retained decode change (2026-09-12): fetch the next literal/length
primary entry before output copying and carry it into the next iteration.
Only complete nine-bit prefixes are reused; secondary lookup and invalid-code
handling remain after refill. No additional allocation or output-size assumption.
The latest three-way rerun (3 serial rounds, >=200 ms, 162 validated samples,
95.7 seconds) reproduces JSON gains of +13.0% / +14.0% for
flate/libdeflate-produced fixtures. Libdeflate 1.25 is 1.095× / 1.173× faster
there. Source-4k improves 8.3% / 7.7%, with libdeflate 1.226× / 1.249× faster.
There is no universal libdeflate multiplier: on other eligible fixtures it is
1.058–1.302× faster when it wins, while flate wins some repetitive fixtures.
The flate-produced large-source fixture spreads 17.1%, so its improvement and
libdeflate ratio are suppressed; the libdeflate-produced source fixture has a
stable 1.234× libdeflate advantage. Precompressed libdeflate samples are also
suppressed for 25.9–38.9% spread. Noisy cases are not no-regression evidence.
Native debug/release 295 tests and JS/Wasm/Wasm GC 283 each pass, including
consecutive 48-bit tokens and invalid lookahead after a committed match.
Source/JSON `moon run --profile` and assembly inspection confirm the changed
lookup placement; profile symbol shares alone do not measure lookup latency.
Public APIs are unchanged. Raw samples/hashes:
`.local/decode-next-primary-20260912/final-three-way-all-3r-200ms-diagnostic.json`
(SHA-256 `152f2423039ce690b432254babb0a0cd73b4e151abb54ca35dabe484ad54e55b).

## Run

From the repository root; requires Python 3.10+, MoonBit, a C compiler,
`pkg-config`, and the libdeflate development package.

```sh
python3 benchmark/run.py                                      # raw direct: 7 rounds, >=150 ms
python3 benchmark/run.py --profile smoke --validate-only       # no timing, warmup or calibration
python3 benchmark/run.py --profile full                       # broader corpus and levels
python3 benchmark/run.py --include-oneshot                     # separate application-cost tables
python3 benchmark/run.py --corpus /path/to/application-data.bin
python3 benchmark/run.py --corpus-manifest /path/to/old-run/corpus.json
```

Each run builds fresh runners and saves results to a new output directory. Use
`--output DIR` to choose its location. Timed workloads run sequentially; a run
takes several minutes.

`--validate-only` builds the actual release runners, exports both producers'
fixtures, and validates compression and cross-decoding without timing loops.
It writes `validation.jsonl` and a final `validation.json`, never a throughput
report. Add `--include-oneshot` to validate the optional wrappers too.
The `smoke` profile alone still times short batches; use `--validate-only` when
no performance measurement is wanted.

## What is measured

- **Raw direct:** reused codecs and caller-owned output buffers on both sides.
  Both decoders receive an output buffer of exactly the uncompressed length N;
  neither grows output. Both compressors receive the same capacity, the maximum
  of their declared bounds. Bounds, allocations, buffer initialization, input
  conversion and codec construction happen before timing. Per-stream reset and
  Huffman construction remain inside the codec operation; decoded tables are
  not cached across streams. This excludes caller-buffer allocation, not a
  verified guarantee of zero internal allocations.
- **Optional one-shot raw/zlib/gzip:** per-operation allocation and release are
  included. The harness allocates exact-size C decode output; flate's convenience
  API grows its output. These are different application policies, so no speed
  multiplier is published. libdeflate itself can accept an output capacity and
  return the actual decoded size; knowing exact length is not an API requirement.
- Both decoders decode **both producers' exact fixtures**. Python zlib also
  validates full output and stream termination.
- Rates are median MiB/s. Warmup, calibration, compilation and file I/O are
  outside the measured batch. Implementation/operation order alternates by round.
  Each operation consumes its output length and final byte. Full byte comparisons
  happen outside timing. Direct speed ratios pair seconds/operation by round,
  corpus hash, output capacity and (for decoding) exact fixture hash, then take
  the median ratio. The displayed min..max range is not a confidence interval.

Quick covers repeated text, deterministic SHAKE random bytes, mixed data,
repository source, synthetic JSON and precompressed source at L1/L6/L9;
it adds small/large inputs and L0 baselines. L6 one-shot cases are opt-in.
Full expands corpus and level coverage. Repository-derived inputs change with
the code. Use `--corpus-manifest` to copy and hash-verify frozen inputs from a
previous run, without regenerating repository source. The manifest determines
inputs; `--profile` still determines configurations. It cannot be combined with
`--corpus`. Fixtures are regenerated by each current encoder, so compare fixture
hashes too before attributing a decode change to the decoder alone.

## Read the results

Same numeric compression levels do **not** imply equal compression quality:
compare compressed sizes alongside throughput. Direct and one-shot results have
different allocation boundaries and should not be mixed.

Spread is `(max - min) / median` of seconds per operation, not a confidence
interval. Rows above 10% are marked `NOISY` and their multipliers suppressed.
Smoke runs and runs with fewer than three rounds also suppress multipliers.
Buffers are warm; CPU affinity and thermal state are uncontrolled. Results do
not cover JS/Wasm throughput, peak memory or streaming chunk-size effects.

Each completed run contains:

- `report.md` and `summary.json`: throughput, sizes and spread.
- `comparisons.json`: raw direct paired ratios and ranges, including noisy or
  short-run estimates for auditing; use report eligibility rules before citing.
- `samples.jsonl`: raw measurements.
- `metadata.json`, build logs and source snapshot: versions, commands and hashes.
- Corpus/fixture manifests and exact input/compressed files.

An incomplete run has no final report. Local artifacts are ignored by Git;
the linked device report records the key results.

Harness checks:

```sh
python3 -m unittest discover -s benchmark -p '*_test.py'
```

Runner protocol: `bound|export|compress|decompress MODE FORMAT LEVEL INPUT
FIXTURE MILLISECONDS OUTPUT_CAPACITY` (C additionally takes `--sample`). `bound`
queries the raw compression bound without measuring. Direct export/compression
requires the shared bound; direct decode requires N. A zero duration validates
without timing. Prefer `run.py` over calling runners with manually chosen bounds.
