// Benchmarks for the compression hot paths. Run with:
//   moon bench --package moonbit-community/flate/benchmark --release --target native --no-parallelize --file bench_flate.mbt --index 0
//
// The parity groups use the same 256 KiB corpus shapes and L1/L6/L9 levels as
// benchmark/bench_libdeflate.c. The C runner reads a file, while these tests
// build bytes in memory; the generators are deterministic. MoonBit reports
// mean time per operation; divide 256 KiB by that time in seconds to obtain
// the C runner's MiB/s unit.
// Raw parity tests reuse whole-buffer codecs and fixed output buffers, matching
// the C runner's direct input/output shape and allocation boundary. One-shot
// and wrapper tests below retain their allocation-inclusive API throughput as
// separate measurements.

///|
const BENCH_INPUT_SIZE : Int = 262144

///|
/// Highly compressible: a phrase repeated to fill `size` bytes.
#coverage.skip
pub fn bench_repetitive(size : Int) -> Bytes {
  let unit = b"The quick brown fox jumps over the lazy dog. Pack my box. "
  let arr : Array[Byte] = []
  while arr.length() < size {
    let remaining = size - arr.length()
    let take = remaining.min(unit.length())
    for i in 0..<take {
      arr.push(unit[i])
    }
  }
  Bytes::from_array(arr)
}

///|
/// Effectively incompressible: bytes from a deterministic LCG.
#coverage.skip
fn bench_random(size : Int) -> Bytes {
  let arr : Array[Byte] = []
  let mut s = 0x12345678U
  for _i in 0..<size {
    s = s * 1103515245U + 12345U
    arr.push(((s >> 16) & 0xFF).reinterpret_as_int().to_byte())
  }
  Bytes::from_array(arr)
}

///|
/// The corpus set corresponding to the C parity runner's inputs.
#coverage.skip
fn bench_corpora(size : Int) -> FixedArray[(String, Bytes)] {
  [
    ("repetitive", bench_repetitive(size)),
    ("random", bench_random(size)),
    ("mixed", bench_mixed(size)),
  ]
}

///|
/// A realistic blend: compressible text followed by incompressible bytes.
#coverage.skip
pub fn bench_mixed(size : Int) -> Bytes {
  let arr : Array[Byte] = []
  for x in bench_repetitive(size / 2) {
    arr.push(x)
  }
  for x in bench_random(size - size / 2) {
    arr.push(x)
  }
  Bytes::from_array(arr)
}

///|
/// Run a reusable whole-buffer compressor into a caller-owned output buffer.
/// Workspace and output allocation are deliberately left to benchmark setup.
#coverage.skip
fn bench_deflate_direct(
  compressor : @flate.Compressor,
  input : Bytes,
  output : FixedArray[Byte],
) -> Int {
  guard compressor.compress_into(input, output) is Some(written) else {
    abort("benchmark output buffer was too small")
  }
  written
}

///|
/// Run a reusable whole-buffer decompressor into a caller-owned output buffer.
/// Valid benchmark fixtures must finish; an error aborts instead of turning an
/// invalid zero-length result into an apparently valid sample.
#coverage.skip
fn bench_inflate_direct(
  decompressor : @flate.Decompressor,
  input : Bytes,
  output : FixedArray[Byte],
) -> Int {
  decompressor.decompress_into(input, output) catch {
    _ => abort("benchmark fixture failed to inflate")
  }
}

///|
/// Read a cross-decoder fixture before timing. The raw benchmark intentionally
/// keeps fixture I/O outside its closure.
#coverage.skip
fn read_fixture(path : String) -> Bytes {
  @fs.read_file_to_bytes(path) catch {
    _ => abort("could not read DEFLATE fixture: \{path}")
  }
}

///|
/// Raw DEFLATE direct-buffer parity cases for `bench_libdeflate.c -f raw`.
/// Codec objects and output buffers are created once per case outside the timed
/// closure, then reused for each sample.
#coverage.skip
test "bench parity raw deflate direct compression" (b : @bench.T) {
  for level in [1, 6, 9] {
    for t in bench_corpora(BENCH_INPUT_SIZE) {
      let (name, data) = t
      let compressor = @flate.Compressor(level~)
      let output = FixedArray::make(
        @flate.deflate_bound(data.length()),
        b'\x00',
      )
      b.bench(name="raw direct compress L\{level} 256KiB \{name}", () => {
        b.keep(bench_deflate_direct(compressor, data, output))
      })
    }
  }
}

///|
/// Raw DEFLATE direct-buffer decompression parity cases. Fixture compression,
/// decoder allocation, and output-buffer allocation all occur before timing.
#coverage.skip
test "bench parity raw deflate direct decompression" (b : @bench.T) {
  for level in [1, 6, 9] {
    for t in bench_corpora(BENCH_INPUT_SIZE) {
      let (name, data) = t
      let fixture_compressor = @flate.Compressor(level~)
      let fixture_buffer = FixedArray::make(
        @flate.deflate_bound(data.length()),
        b'\x00',
      )
      let fixture_len = bench_deflate_direct(
        fixture_compressor, data, fixture_buffer,
      )
      let compressed = Bytes::from_array(fixture_buffer[:fixture_len])
      let decompressor = @flate.Decompressor()
      let output = FixedArray::make(data.length(), b'\x00')
      b.bench(name="raw direct decompress L\{level} 256KiB \{name}", () => {
        b.keep(bench_inflate_direct(decompressor, compressed, output))
      })
    }
  }
}

///|
/// Wrapper cases for `bench_libdeflate.c -f zlib` and `-f gzip`.
#coverage.skip
test "bench parity zlib and gzip wrappers" (b : @bench.T) {
  for level in [1, 6, 9] {
    for t in bench_corpora(BENCH_INPUT_SIZE) {
      let (name, data) = t
      b.bench(name="zlib compress L\{level} 256KiB \{name}", () => {
        b.keep(@zlib.zlib_compress(data, level~))
      })
      b.bench(name="gzip compress L\{level} 256KiB \{name}", () => {
        b.keep(@gzip.gzip_compress(data, level~))
      })

      let zlib_compressed = @zlib.zlib_compress(data, level~)
      b.bench(name="zlib decompress L\{level} 256KiB \{name}", () => {
        b.keep(@zlib.zlib_decompress(zlib_compressed) catch { _ => b"" })
      })
      let gzip_compressed = @gzip.gzip_compress(data, level~)
      b.bench(name="gzip decompress L\{level} 256KiB \{name}", () => {
        b.keep(@gzip.gunzip(gzip_compressed) catch { _ => b"" })
      })
    }
  }
}

///|
/// Cross-decoder case: set `FLATE_C_FIXTURE` to a libdeflate stream and
/// `FLATE_C_FIXTURE_SOURCE` to its original 256 KiB corpus. The fixture is
/// decoded and checked byte-for-byte before timing, then repeatedly through
/// the direct caller-buffer API. Omit both variables to leave this optional
/// benchmark empty.
#coverage.skip
test "bench cross raw C fixture decompression" (b : @bench.T) {
  if @env.get_env_var("FLATE_C_FIXTURE") is Some(path) {
    guard @env.get_env_var("FLATE_C_FIXTURE_SOURCE") is Some(source_path) else {
      abort("FLATE_C_FIXTURE_SOURCE is required with FLATE_C_FIXTURE")
    }
    let fixture = read_fixture(path)
    let expected = read_fixture(source_path)
    let decompressor = @flate.Decompressor()
    let output = FixedArray::make(expected.length(), b'\x00')
    let decoded_len = bench_inflate_direct(decompressor, fixture, output)
    guard decoded_len == expected.length() else {
      abort("C DEFLATE fixture decoded to an unexpected length")
    }
    for i in 0..<decoded_len {
      guard output[i] == expected[i] else {
        abort("C DEFLATE fixture decoded to unexpected bytes")
      }
    }
    b.bench(name="raw direct decompress C fixture \{decoded_len}B", () => {
      b.keep(bench_inflate_direct(decompressor, fixture, output))
    })
  }
}

///|
/// Decode without raising out of the bench closure.
#coverage.skip
fn bench_inflate_exact(c : Bytes, preallocated : Bool) -> Bytes {
  @flate.inflate_exact(c, preallocated~) catch {
    _ => b""
  }
}

///|
/// Grow-path vs preallocated (two-pass, exact allocation) one-shot decode.
/// This is a MoonBit API comparison and has no direct libdeflate equivalent.
#coverage.skip
test "bench inflate_exact grow vs preallocated" (b : @bench.T) {
  let comp_rep = @flate.deflate_all(bench_repetitive(BENCH_INPUT_SIZE), level=6)
  let comp_mix = @flate.deflate_all(bench_mixed(BENCH_INPUT_SIZE), level=6)
  b.bench(name="MoonBit-only inflate_exact 256KiB repetitive grow", () => {
    b.keep(bench_inflate_exact(comp_rep, false))
  })
  b.bench(name="MoonBit-only inflate_exact 256KiB repetitive preallocated", () => {
    b.keep(bench_inflate_exact(comp_rep, true))
  })
  b.bench(name="MoonBit-only inflate_exact 256KiB mixed grow", () => {
    b.keep(bench_inflate_exact(comp_mix, false))
  })
  b.bench(name="MoonBit-only inflate_exact 256KiB mixed preallocated", () => {
    b.keep(bench_inflate_exact(comp_mix, true))
  })
}

///|
/// Zip-style payloads mix many small parts with a few large ones. These are
/// supplemental cases; reproduce them in C with smaller input files.
#coverage.skip
test "bench MoonBit-only deflate by size and level" (b : @bench.T) {
  for size in [512, 4096, 65536] {
    let rep = bench_repetitive(size)
    let mix = bench_mixed(size)
    for level in [0, 1, 6] {
      b.bench(name="deflate L\{level} \{size}B repetitive", () => {
        b.keep(@flate.deflate_all(rep, level~))
      })
      b.bench(name="deflate L\{level} \{size}B mixed", () => {
        b.keep(@flate.deflate_all(mix, level~))
      })
    }
  }
}

///|
#coverage.skip
test "bench deflate_all_optimal" (b : @bench.T) {
  let small = bench_repetitive(16384) // zopfli is ~50-100x slower; keep it small
  b.bench(name="deflate_optimal 16K repetitive", () => {
    b.keep(@flate.deflate_all_optimal(small))
  })
}

///|
/// Realistic English prose so the adaptive-split speed is measured on the
/// regime where it wins ratio.
#coverage.skip
fn bench_prose(size : Int) -> Bytes {
  let unit = b"The history of data compression is a history of finding structure in information that does not want to be found. Early codes worked letter by letter; the leap to phrase-based matching came only when programmers realized that a file is rarely a stream of independent symbols but a tapestry of repeated fragments. Consider a text file: common words appear over and over, at distances that vary with the sentence structure around them, and an encoder that treats every occurrence as new is wasting its time. Matching is not the same as deciding: a match that is one byte longer but a thousand bytes farther away may cost more in offset bits than it saves in literals."
  let arr : Array[Byte] = []
  while arr.length() < size {
    let remaining = size - arr.length()
    let take = remaining.min(unit.length())
    for i in 0..<take {
      arr.push(unit[i])
    }
  }
  Bytes::from_array(arr)
}

///|
/// Speed comparison of the fixed 16 KB cadence (`deflate_all`) against the
/// adaptive observation-divergence splitter (`deflate_all_split`) at the same
/// level, on the same inputs. Pairs are emitted adjacently so the runner
/// interleaves them fairly.
#coverage.skip
test "bench MoonBit-only deflate_all vs deflate_all_split" (b : @bench.T) {
  let prose = bench_prose(BENCH_INPUT_SIZE)
  let rep = bench_repetitive(BENCH_INPUT_SIZE)
  let rnd = bench_random(BENCH_INPUT_SIZE)
  let mix = bench_mixed(BENCH_INPUT_SIZE)
  for level in [1, 6, 9] {
    for t in [("prose", prose), ("rep", rep), ("rnd", rnd), ("mix", mix)] {
      let (name, data) = t
      b.bench(name="deflate L\{level} \{name} fixed", () => {
        b.keep(@flate.deflate_all(data, level~))
      })
      b.bench(name="deflate L\{level} \{name} split", () => {
        b.keep(@flate.deflate_all_split(data, level~))
      })
    }
  }
}
