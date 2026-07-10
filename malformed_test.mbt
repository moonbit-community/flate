///|
fn expect_inflate_error(data : Bytes) -> Unit raise {
  try ignore(@flate.inflate_all(data)) catch {
    InflateError(_) => ()
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
  let output = FixedArray::make(1, b'\x00')
  try ignore(inflater.step(([0x07] : Bytes)[:], output.mut_view())) catch {
    InflateError(message) => assert_eq(message, "corrupt: reserved block type")
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
      InflateError(message) => assert_eq(message, "unexpected end of input")
    } noraise {
      _ => fail("streaming raw DEFLATE accepted a truncated final input")
    }
  }
  inflater.reset()
  let source = b"reset clears the terminal error"
  let compressed = @flate.deflate_all(source)
  let (status, consumed, produced) = inflater.step(
    compressed[:],
    output.mut_view(),
    end=true,
  )
  assert_true(status is Done)
  assert_eq(consumed, compressed.length())
  assert_eq(produced, source.length())
}
