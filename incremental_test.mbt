// Byte-at-a-time stress (suggested by review): drive both directions with the
// minimal viable buffers — input fed one byte per `step`, output capped at a
// single byte — so every suspension boundary (NeedMoreInput / NeedMoreOutput,
// mid-match copy, block boundaries) is hit. Since the engine guarantees
// progress with one output byte, these configurations must still round-trip.
// Sizes/levels are kept small: the goal is suspension coverage, not throughput.

///|
fn lcg(state : UInt) -> UInt {
  state * 1664525 + 1013904223
}

///|
fn make_bytes(seed : UInt, len : Int, alpha : Int) -> Bytes {
  let a = Array::make(len, b'\x00')
  let mut s = seed
  for i in 0..<len {
    s = lcg(s)
    a[i] = (((s >> 16).reinterpret_as_int() % alpha + alpha) % alpha).to_byte()
  }
  Bytes::from_array(a)
}

///|
/// Compress `data` feeding one input byte per `step` into a one-byte output.
fn deflate_1b(data : Bytes, level : Int) -> Bytes {
  let def = @flate.Deflater::new(level~)
  let comp = Buffer()
  let ob = FixedArray::make(1, b'\x00')
  let n = data.length()
  let mut i = 0
  while i < n {
    ignore(def.step(data[i:i + 1], ob.mut_view()))
    let c = def.last_consumed()
    let p = def.last_produced()
    if p == 1 {
      comp.write_byte(ob[0])
    }
    i = i + c
  }
  for ;; {
    let st = def.step(data[n:n], ob.mut_view(), action=Finish)
    let p = def.last_produced()
    if p == 1 {
      comp.write_byte(ob[0])
    }
    if st is Done {
      break
    }
  }
  comp.to_bytes()
}

///|
/// Decompress with non-overlapping one-byte input and output chunks. Incomplete
/// atomic units are retained inside Inflater, so every consumed byte is fed
/// exactly once; no growing replay window is required.
fn inflate_1b(comp : Bytes) -> Bytes raise {
  let inf = @flate.Inflater::new()
  let out = Buffer()
  let ob = FixedArray::make(1, b'\x00')
  let n = comp.length()
  let mut consumed = 0
  for ;; {
    let endi = if consumed < n { consumed + 1 } else { consumed }
    let st = inf.step(comp[consumed:endi], ob.mut_view(), end=endi == n)
    let c = inf.last_consumed()
    let p = inf.last_produced()
    consumed = consumed + c
    if p == 1 {
      out.write_byte(ob[0])
    }
    if st is Done {
      break
    }
    if st is NeedMoreInput {
      assert_true(consumed < n)
    }
    // NeedMoreOutput: drained one byte; loop to drain the next.
  }
  out.to_bytes()
}

///|
test "byte-at-a-time deflate+inflate round-trips (1B in, 1B out)" {
  // Small sizes, cheap levels — exercises match-copy / input / output
  // suspension and the length-258/259 and dist=1 boundaries without the
  // expensive level-9 chain search.
  let cases = [
    (1, 0),
    (1, 1),
    (1, 2),
    (2, 7),
    (2, 258),
    (2, 259),
    (4, 600),
    (256, 500),
  ]
  let mut seed = 0x9E3779B9U
  for ci in 0..<cases.length() {
    let (alpha, len) = cases[ci]
    seed = lcg(seed)
    let data = make_bytes(seed, len, alpha)
    for level in [0, 1, 6] {
      let comp = deflate_1b(data, level)
      assert_eq(@flate.inflate_all(comp), data)
      assert_eq(inflate_1b(comp), data)
    }
  }
  // A long single-byte run: overlapping dist=1 copies, drained one byte/step.
  let run = Bytes::from_array(Array::make(700, b'\x5A'))
  assert_eq(inflate_1b(deflate_1b(run, 6)), run)
}

///|
test "byte-at-a-time inflate of one-shot output (1B in, 1B out)" {
  let mut seed = 0x1234567U
  for alpha in [1, 2, 16] {
    seed = lcg(seed)
    let data = make_bytes(seed, 800, alpha)
    assert_eq(inflate_1b(@flate.deflate_all(data, level=6)), data)
  }
  // One small optimal-parsed stream, decoded byte-at-a-time.
  let d = make_bytes(42U, 300, 4)
  assert_eq(inflate_1b(@flate.deflate_all_optimal(d, iterations=2)), d)
}
