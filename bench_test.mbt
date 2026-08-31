// Benchmarks for the compression hot paths. Run with `moon bench`. Inputs are
// generated deterministically (no RNG dependency) so numbers compare across
// runs. Three data shapes span the spectrum the block planner chooses between:
// repetitive (dynamic Huffman, deep matches), random (stored wins), and a
// 50/50 blend.

///|
/// Highly compressible: a phrase repeated to fill `size` bytes.
fn bench_repetitive(size : Int) -> Bytes {
  let unit = b"The quick brown fox jumps over the lazy dog. Pack my box. "
  let arr : Array[Byte] = []
  while arr.length() < size {
    for x in unit {
      arr.push(x)
    }
  }
  Bytes::from_array(arr)
}

///|
/// Effectively incompressible: bytes from a deterministic LCG.
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
/// A realistic blend: compressible text followed by incompressible bytes.
fn bench_mixed(size : Int) -> Bytes {
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
fn bench_inflate(c : Bytes) -> Bytes {
  @flate.inflate_all(c) catch {
    _ => b""
  }
}

///|
test "bench deflate_all" (b : @bench.T) {
  let n = 262144 // 256 KB — many blocks, so the per-block allocation shows
  let rep = bench_repetitive(n)
  let rnd = bench_random(n)
  let mix = bench_mixed(n)
  b.bench(name="deflate L1 256K repetitive", () => {
    b.keep(@flate.deflate_all(rep, level=1))
  })
  b.bench(name="deflate L6 256K repetitive", () => {
    b.keep(@flate.deflate_all(rep, level=6))
  })
  b.bench(name="deflate L9 256K repetitive", () => {
    b.keep(@flate.deflate_all(rep, level=9))
  })
  b.bench(name="deflate L6 256K random", () => {
    b.keep(@flate.deflate_all(rnd, level=6))
  })
  b.bench(name="deflate L1 256K random", () => {
    b.keep(@flate.deflate_all(rnd, level=1))
  })
  b.bench(name="deflate L6 256K mixed", () => {
    b.keep(@flate.deflate_all(mix, level=6))
  })
}

///|
test "bench inflate_all" (b : @bench.T) {
  let n = 262144
  let comp_rep = @flate.deflate_all(bench_repetitive(n), level=6)
  let comp_mix = @flate.deflate_all(bench_mixed(n), level=6)
  b.bench(name="inflate 256K repetitive", () => b.keep(bench_inflate(comp_rep)))
  b.bench(name="inflate 256K mixed", () => b.keep(bench_inflate(comp_mix)))
}

///|
/// Decode without raising out of the bench closure.
fn bench_inflate_exact(c : Bytes, preallocated : Bool) -> Bytes {
  @flate.inflate_exact(c, preallocated~) catch {
    _ => b""
  }
}

///|
/// Grow-path vs preallocated (two-pass, exact allocation) one-shot decode.
test "bench inflate_exact grow vs preallocated" (b : @bench.T) {
  let n = 262144
  let comp_rep = @flate.deflate_all(bench_repetitive(n), level=6)
  let comp_mix = @flate.deflate_all(bench_mixed(n), level=6)
  b.bench(name="inflate_exact 256K repetitive grow", () => {
    b.keep(bench_inflate_exact(comp_rep, false))
  })
  b.bench(name="inflate_exact 256K repetitive preallocated", () => {
    b.keep(bench_inflate_exact(comp_rep, true))
  })
  b.bench(name="inflate_exact 256K mixed grow", () => {
    b.keep(bench_inflate_exact(comp_mix, false))
  })
  b.bench(name="inflate_exact 256K mixed preallocated", () => {
    b.keep(bench_inflate_exact(comp_mix, true))
  })
}

///|
/// Zip-style payloads mix many small parts with a few large ones; show the
/// small-part overhead of dynamic-Huffman levels to pick a zip default.
test "bench deflate_all by size and level" (b : @bench.T) {
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
test "bench deflate_all_optimal" (b : @bench.T) {
  let small = bench_repetitive(16384) // zopfli is ~50-100x slower; keep it small
  b.bench(name="deflate_optimal 16K repetitive", () => {
    b.keep(@flate.deflate_all_optimal(small))
  })
}

///|
/// Realistic English prose so the adaptive-split speed is measured on the
/// regime where it wins ratio.
fn bench_prose(size : Int) -> Bytes {
  let unit = b"The history of data compression is a history of finding structure in information that does not want to be found. Early codes worked letter by letter; the leap to phrase-based matching came only when programmers realized that a file is rarely a stream of independent symbols but a tapestry of repeated fragments. Consider a text file: common words appear over and over, at distances that vary with the sentence structure around them, and an encoder that treats every occurrence as new is wasting its time. Matching is not the same as deciding: a match that is one byte longer but a thousand bytes farther away may cost more in offset bits than it saves in literals."
  let arr : Array[Byte] = []
  while arr.length() < size {
    for i in 0..<unit.length() {
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
test "bench deflate_all vs deflate_all_split" (b : @bench.T) {
  let n = 262144
  let prose = bench_prose(n)
  let rep = bench_repetitive(n)
  let rnd = bench_random(n)
  let mix = bench_mixed(n)
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
