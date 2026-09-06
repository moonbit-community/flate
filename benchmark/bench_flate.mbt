// Benchmarks for the compression hot paths. Run with:
//   moon bench --package moonbit-community/flate/benchmark --release --target native --no-parallelize --file bench_flate.mbt --index 0
//
// The parity groups use the same 256 KiB corpus shapes and L1/L6/L9 levels as
// benchmark/bench_libdeflate.c. The C runner reads a file, while these tests
// build bytes in memory; the generators are deterministic. MoonBit reports
// mean time per operation; divide 256 KiB by that time in seconds to obtain
// the C runner's MiB/s unit.
// Raw parity tests reuse a streaming codec and fixed output buffer, matching
// the C runner's allocation boundary. One-shot and wrapper tests below retain
// their allocation-inclusive API throughput as separate measurements.

///|
const BENCH_INPUT_SIZE : Int = 262144

///|
// Enough room for a 256 KiB raw stream even when stored blocks win, plus space
// for the streaming decoder to consume the final EOB after its payload fills.
const BENCH_CORE_OUTPUT_SLACK : Int = 1024

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
/// Drive a resettable streaming compressor into a caller-owned output buffer.
/// Both the reset and the state-machine work are part of each codec operation;
/// allocating the compressor and buffer is deliberately left to benchmark setup.
#coverage.skip
fn bench_deflate_core(
  deflater : @flate.Deflater,
  input : Bytes,
  output : FixedArray[Byte],
) -> Int {
  deflater.reset()
  let mut input_pos = 0
  let mut output_pos = 0
  for ;; {
    let status = deflater.step(
      input[input_pos:],
      output.mut_view(start=output_pos),
      action=Finish,
    )
    input_pos = input_pos + deflater.last_consumed()
    output_pos = output_pos + deflater.last_produced()
    if status is Done {
      return output_pos
    }
  }
}

///|
/// Drive a resettable streaming decompressor into a caller-owned output buffer.
/// Valid benchmark fixtures must finish; an error aborts instead of turning an
/// invalid zero-length result into an apparently valid sample.
#coverage.skip
fn bench_inflate_core(
  inflater : @flate.Inflater,
  input : Bytes,
  output : FixedArray[Byte],
) -> Int {
  inflater.reset()
  let mut input_pos = 0
  let mut output_pos = 0
  for ;; {
    let status = inflater.step(
      input[input_pos:],
      output.mut_view(start=output_pos),
      end=true,
    ) catch {
      _ => abort("benchmark fixture failed to inflate")
    }
    input_pos = input_pos + inflater.last_consumed()
    output_pos = output_pos + inflater.last_produced()
    if status is Done {
      return output_pos
    }
  }
}

///|
/// Raw DEFLATE allocation-reuse parity cases for `bench_libdeflate.c -f raw`.
/// Codec objects and output buffers are created once per case outside the timed
/// closure, then reset and reused for each sample.
#coverage.skip
test "bench parity raw deflate reusable compression" (b : @bench.T) {
  for level in [1, 6, 9] {
    for t in bench_corpora(BENCH_INPUT_SIZE) {
      let (name, data) = t
      let deflater = @flate.Deflater(level~)
      let output = FixedArray::make(
        data.length() + BENCH_CORE_OUTPUT_SLACK,
        b'\x00',
      )
      b.bench(name="raw reusable compress L\{level} 256KiB \{name}", () => {
        b.keep(bench_deflate_core(deflater, data, output))
      })
    }
  }
}

///|
/// Raw DEFLATE allocation-reuse decompression parity cases. Fixture compression,
/// decoder allocation, and output-buffer allocation all occur before timing.
#coverage.skip
test "bench parity raw deflate reusable decompression" (b : @bench.T) {
  for level in [1, 6, 9] {
    for t in bench_corpora(BENCH_INPUT_SIZE) {
      let (name, data) = t
      let compressed = @flate.deflate_all(data, level~)
      let inflater = @flate.Inflater()
      let output = FixedArray::make(
        data.length() + BENCH_CORE_OUTPUT_SLACK,
        b'\x00',
      )
      b.bench(name="raw reusable decompress L\{level} 256KiB \{name}", () => {
        b.keep(bench_inflate_core(inflater, compressed, output))
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
