// Benchmarks for the compression hot paths. Run with:
//   moon bench --package moonbit-community/flate/benchmark --release --target native --no-parallelize --file bench_flate.mbt --index 0
//
// The parity groups use the same 256 KiB corpus shapes and L1/L6/L9 levels as
// benchmark/bench_libdeflate.c. The C runner reads a file, while these tests
// build bytes in memory; the generators are deterministic. MoonBit reports
// mean time per operation; divide 256 KiB by that time in seconds to obtain
// the C runner's MiB/s unit.
// The public MoonBit one-shot APIs allocate their result inside the timed
// operation, while the C runner reuses codec buffers. Interpret the numbers as
// API-level throughput unless the C runner is extended with allocation mode.

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
/// Decode without raising out of the bench closure.
#coverage.skip
fn bench_inflate(c : Bytes) -> Bytes {
  @flate.inflate_all(c) catch {
    _ => b""
  }
}

///|
/// Raw DEFLATE compression parity cases for `bench_libdeflate.c -f raw`.
#coverage.skip
test "bench parity raw deflate compression" (b : @bench.T) {
  for level in [1, 6, 9] {
    for t in bench_corpora(BENCH_INPUT_SIZE) {
      let (name, data) = t
      b.bench(name="raw compress L\{level} 256KiB \{name}", () => {
        b.keep(@flate.deflate_all(data, level~))
      })
    }
  }
}

///|
/// Raw DEFLATE decompression parity cases. Compression is performed once
/// before timing, matching the C runner's reuse of its compressed buffer.
#coverage.skip
test "bench parity raw deflate decompression" (b : @bench.T) {
  for level in [1, 6, 9] {
    for t in bench_corpora(BENCH_INPUT_SIZE) {
      let (name, data) = t
      let compressed = @flate.deflate_all(data, level~)
      b.bench(name="raw decompress L\{level} 256KiB \{name}", () => {
        b.keep(bench_inflate(compressed))
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
