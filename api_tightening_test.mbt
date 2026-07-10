///|
fn append_bytes(left : Bytes, right : Bytes) -> Bytes {
  let joined : Array[Byte] = []
  for byte in left {
    joined.push(byte)
  }
  for byte in right {
    joined.push(byte)
  }
  Bytes::from_array(joined)
}

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
  let framed = append_bytes(compressed, b"NEXT")
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
      append_bytes(compressed, b"TRAILING"),
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
