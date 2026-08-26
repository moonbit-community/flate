///|
test "raw inflate errors expose stable categories" {
  try ignore(@flate.inflate_all(b"")) catch {
    InflateError(kind, message) => {
      assert_true(kind == Truncated)
      assert_eq(message, "unexpected end of input")
    }
  } noraise {
    _ => fail("empty raw DEFLATE input was accepted")
  }
  try ignore(@flate.inflate_all(([0x07] : Bytes))) catch {
    InflateError(kind, message) => {
      assert_true(kind == Corrupt)
      assert_eq(message, "corrupt: reserved block type")
    }
  } noraise {
    _ => fail("reserved raw DEFLATE block was accepted")
  }
}

///|
test "inflate_exact rejects bytes after the raw stream" {
  let source = b"exact framing keeps the next protocol frame visible"
  let compressed = @flate.deflate_all(source)
  assert_eq(@flate.inflate_exact(compressed), source)
  let framed = compressed + b"NEXT"
  try ignore(@flate.inflate_exact(framed)) catch {
    InflateError(kind, message) => {
      assert_true(kind == TrailingData)
      assert_eq(message, "trailing data after DEFLATE stream")
    }
  } noraise {
    _ => fail("inflate_exact accepted trailing data")
  }
  try ignore(@flate.inflate_exact(b"")) catch {
    InflateError(kind, _) => assert_true(kind == Truncated)
  } noraise {
    _ => fail("inflate_exact accepted truncated input")
  }
}

///|
test "inflate_all_limited enforces its decoded-size boundary" {
  let source = b"bounded one-shot inflate"
  let compressed = @flate.deflate_all(source)
  assert_eq(
    @flate.inflate_all_limited(compressed, max_output=source.length()),
    source,
  )
  // The limited convenience API deliberately retains inflate_all's prefix
  // semantics; exact framing is the separate inflate_exact contract.
  assert_eq(
    @flate.inflate_all_limited(
      compressed + b"TRAILING",
      max_output=source.length(),
    ),
    source,
  )
  try
    ignore(
      @flate.inflate_all_limited(compressed, max_output=source.length() - 1),
    )
  catch {
    InflateError(kind, _) => assert_true(kind == OutputLimitExceeded)
  } noraise {
    _ => fail("inflate_all_limited exceeded its output limit")
  }
  try ignore(@flate.inflate_all_limited(compressed, max_output=-1)) catch {
    InflateError(kind, _) => assert_true(kind == OutputLimitExceeded)
  } noraise {
    _ => fail("inflate_all_limited accepted a negative limit")
  }
  let empty = @flate.deflate_all(b"")
  assert_eq(@flate.inflate_all_limited(empty, max_output=0), b"")
  // More than one scratch buffer forces the convenience driver through
  // NeedMoreOutput without weakening the decoded-size limit.
  let large = Bytes::from_array(Array::make(20000, b'X'))
  let large_compressed = @flate.deflate_all(large)
  assert_eq(
    @flate.inflate_all_limited(large_compressed, max_output=large.length()),
    large,
  )
}

///|
fn inflate_exact_sources() -> Array[Bytes] {
  let patterned = Array::make(30000, b'\x00')
  for i in 0..<30000 {
    patterned[i] = (i * 31 + i / 7).to_byte()
  }
  [
    b"",
    b"hello",
    Bytes::from_array(Array::make(8191, b'a')),
    Bytes::from_array(Array::make(8192, b'b')),
    Bytes::from_array(Array::make(8193, b'c')),
    Bytes::from_array(Array::make(30000, b'z')),
    Bytes::from_array(patterned),
  ]
}

///|
test "inflate_exact preallocated and grow paths agree" {
  for source in inflate_exact_sources() {
    for level in [0, 1, 6] {
      let compressed = @flate.deflate_all(source, level~)
      assert_eq(@flate.inflate_exact(compressed, preallocated=true), source)
      assert_eq(
        @flate.inflate_exact(compressed),
        @flate.inflate_exact(compressed, preallocated=true),
      )
    }
  }
}

///|
test "inflate_exact enforces max_output on both paths" {
  let source = Bytes::from_array(Array::make(20000, b'X'))
  let compressed = @flate.deflate_all(source)
  assert_eq(@flate.inflate_exact(compressed, max_output=Some(20000)), source)
  assert_eq(
    @flate.inflate_exact(compressed, max_output=Some(20000), preallocated=true),
    source,
  )
  for preallocated in [false, true] {
    try
      ignore(
        @flate.inflate_exact(compressed, max_output=Some(19999), preallocated~),
      )
    catch {
      InflateError(kind, _) => assert_true(kind == OutputLimitExceeded)
    } noraise {
      _ => fail("inflate_exact exceeded its output limit")
    }
  }
  try ignore(@flate.inflate_exact(compressed, max_output=Some(-1))) catch {
    InflateError(kind, _) => assert_true(kind == OutputLimitExceeded)
  } noraise {
    _ => fail("inflate_exact accepted a negative limit")
  }
}

///|
test "preallocated inflate_exact still rejects trailing bytes" {
  let source = b"exact framing stays exact under preallocation"
  let compressed = @flate.deflate_all(source)
  let framed = compressed + b"NEXT"
  try ignore(@flate.inflate_exact(framed, preallocated=true)) catch {
    InflateError(kind, _) => assert_true(kind == TrailingData)
  } noraise {
    _ => fail("preallocated inflate_exact accepted trailing data")
  }
}

///|
test "inflate_exact entry cancellation raises Cancelled" {
  try ignore(@flate.inflate_exact(b"\x03\x00", cancelled=() => true)) catch {
    InflateError(kind, _) => assert_true(kind == Cancelled)
  } noraise {
    _ => fail("entry cancellation was not honored")
  }
}

///|
test "preallocated inflate_exact entry cancellation raises Cancelled" {
  let source = Bytes::from_array(Array::make(30000, b'A'))
  let compressed = @flate.deflate_all(source)
  try
    ignore(
      @flate.inflate_exact(compressed, preallocated=true, cancelled=() => true),
    )
  catch {
    InflateError(kind, _) => assert_true(kind == Cancelled)
  } noraise {
    _ => fail("preallocated entry cancellation was not honored")
  }
}

///|
test "preallocated inflate_exact honors cancellation in both passes" {
  let source = Bytes::from_array(Array::make(30000, b'A'))
  let compressed = @flate.deflate_all(source)
  // Pass 1 (counting) covers 30000 bytes in four 8192-byte steps and polls
  // four times; pass 2 replays the same four steps and polls four more.
  // Poll 3 lands in pass 1, poll 6 in pass 2.
  for cancel_at in [3, 6] {
    let mut calls = 0
    try
      ignore(
        @flate.inflate_exact(
          compressed,
          cancelled=() => {
            calls = calls + 1
            calls >= cancel_at
          },
          preallocated=true,
        ),
      )
    catch {
      InflateError(kind, _) => assert_true(kind == Cancelled)
    } noraise {
      _ => fail("preallocated inflate_exact ignored cancellation")
    }
  }
}

///|
test "inflate_all polls the cancel callback" {
  let source = Bytes::from_array(Array::make(20000, b'X'))
  let compressed = @flate.deflate_all(source)
  let mut calls = 0
  try
    ignore(
      @flate.inflate_all(compressed, cancelled=() => {
        calls = calls + 1
        calls >= 5
      }),
    )
  catch {
    InflateError(kind, _) => assert_true(kind == Cancelled)
  } noraise {
    _ => fail("inflate_all ignored cancellation")
  }
  // Entry poll fires even for input that would decode instantly.
  let mut early = 0
  try
    ignore(
      @flate.inflate_all(compressed, cancelled=() => {
        early = early + 1
        early >= 1
      }),
    )
  catch {
    InflateError(kind, _) => assert_true(kind == Cancelled)
  } noraise {
    _ => fail("inflate_all ignored entry cancellation")
  }
}

///|
test "inflate_all_limited polls the cancel callback" {
  let source = Bytes::from_array(Array::make(20000, b'X'))
  let compressed = @flate.deflate_all(source)
  let mut calls = 0
  try
    ignore(
      @flate.inflate_all_limited(compressed, max_output=100000, cancelled=() => {
        calls = calls + 1
        calls >= 3
      }),
    )
  catch {
    InflateError(kind, _) => assert_true(kind == Cancelled)
  } noraise {
    _ => fail("inflate_all_limited ignored cancellation")
  }
}

///|
test "cancel is polled before the limit check within a step" {
  let source = Bytes::from_array(Array::make(20000, b'Z'))
  let compressed = @flate.deflate_all(source)
  let mut calls = 0
  try
    ignore(
      @flate.inflate_exact(
        compressed,
        max_output=Some(1000),
        cancelled=() => {
          calls = calls + 1
          calls >= 3
        },
        preallocated=true,
      ),
    )
  catch {
    // The first step already produces 8192 bytes, so the limit trips before
    // the third poll; cancellation must not shadow the limit error.
    InflateError(kind, _) => assert_true(kind == OutputLimitExceeded)
  } noraise {
    _ => fail("limit check did not take precedence within a step")
  }
}
