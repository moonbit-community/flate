///|
fn expect_inflate_error(data : Bytes) -> Unit raise {
  try ignore(@flate.inflate_all(data)) catch {
    InflateError(_, _) => ()
  } noraise {
    _ => fail("malformed raw DEFLATE was accepted")
  }
}

///|
test "inflate_all rejects malformed block structure" {
  expect_inflate_error(b"")
  expect_inflate_error([0x07]) // BFINAL=1, reserved BTYPE=3
  expect_inflate_error([0x01, 0x01, 0x00, 0x00, 0x00]) // bad NLEN
  expect_inflate_error([0x01, 0x02, 0x00, 0xFD, 0xFF, 0xAA]) // short stored payload
  // Dynamic block whose code-length alphabet contains no symbols.
  expect_inflate_error([0x05, 0x00, 0x00, 0x00, 0x00])
}

///|
test "streaming Inflater rejects a reserved block immediately" {
  let inflater = @flate.Inflater::new()
  assert_eq(inflater.last_consumed(), 0)
  assert_eq(inflater.last_produced(), 0)
  let output = FixedArray::make(1, b'\x00')
  // A complete non-final stored block leaves the decoder waiting for another
  // block and gives the counters non-zero values to clear on the next call.
  let prefix : Bytes = [0x00, 0x01, 0x00, 0xFE, 0xFF, 0x41]
  let prefix_status = inflater.step(prefix[:], output.mut_view())
  assert_true(prefix_status is NeedMoreInput)
  assert_eq(inflater.last_consumed(), prefix.length())
  assert_eq(inflater.last_produced(), 1)
  try ignore(inflater.step(([0x07] : Bytes)[:], output.mut_view())) catch {
    InflateError(kind, message) => {
      assert_true(kind == Corrupt)
      assert_eq(message, "corrupt: reserved block type")
      assert_eq(inflater.last_consumed(), 0)
      assert_eq(inflater.last_produced(), 0)
    }
  } noraise {
    _ => fail("streaming raw DEFLATE accepted reserved BTYPE=3")
  }
}

///|
test "streaming Inflater turns EOF into a stable truncation error" {
  let inflater = @flate.Inflater::new()
  let output = FixedArray::make(64, b'\x00')
  for input in [([0x01] : Bytes), ([0x07] : Bytes)] {
    try ignore(inflater.step(input[:], output.mut_view(), end=true)) catch {
      InflateError(kind, message) => {
        assert_true(kind == Truncated)
        assert_eq(message, "unexpected end of input")
      }
    } noraise {
      _ => fail("streaming raw DEFLATE accepted a truncated final input")
    }
  }
  inflater.reset()
  assert_eq(inflater.last_consumed(), 0)
  assert_eq(inflater.last_produced(), 0)
  let source = b"reset clears the terminal error"
  let compressed = @flate.deflate_all(source)
  let status = inflater.step(compressed[:], output.mut_view(), end=true)
  let consumed = inflater.last_consumed()
  let produced = inflater.last_produced()
  assert_true(status is Done)
  assert_eq(consumed, compressed.length())
  assert_eq(produced, source.length())
}
