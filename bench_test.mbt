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
test "bench deflate_all_optimal" (b : @bench.T) {
  let small = bench_repetitive(16384) // zopfli is ~50-100x slower; keep it small
  b.bench(name="deflate_optimal 16K repetitive", () => {
    b.keep(@flate.deflate_all_optimal(small))
  })
}
