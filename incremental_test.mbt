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
    let (_st, c, p) = def.step(data[i:i + 1], ob.mut_view())
    if p == 1 {
      comp.write_byte(ob[0])
    }
    i = i + c
  }
  for ;; {
    let (st, _c, p) = def.step(data[n:n], ob.mut_view(), end=true)
    if p == 1 {
      comp.write_byte(ob[0])
    }
    if st is @flate.Done {
      break
    }
  }
  comp.to_bytes()
}

///|
/// Decompress with a one-byte output and a GROWING input window: the visible
/// input grows one byte at a time only when the engine asks for more
/// (`NeedMoreInput`). A fixed one-byte *sliding* window would deadlock, because
/// a unit (e.g. a stored-block header) may need several bytes visible at once
/// and the engine rewinds, consuming nothing, until they are — exactly the
/// "feed 1 byte, grow by 1 if not enough" contract.
fn inflate_1b(comp : Bytes) -> Bytes raise {
  let inf = @flate.Inflater::new()
  let out = Buffer()
  let ob = FixedArray::make(1, b'\x00')
  let n = comp.length()
  let mut consumed = 0 // bytes the engine has permanently taken
  let mut avail = 0 // bytes released to the engine so far (window end)
  for ;; {
    let (st, c, p) = inf.step(comp[consumed:avail], ob.mut_view())
    consumed = consumed + c
    if p == 1 {
      out.write_byte(ob[0])
    }
    if st is @flate.Done {
      break
    }
    if st is @flate.NeedMoreInput {
      if avail < n {
        avail = avail + 1 // release one more byte and retry the unit
      } else {
        break // all input visible but stream not done => truncated
      }
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
