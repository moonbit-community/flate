///|
fn expect_inflate_error(data : Bytes) -> Unit raise {
  @test.assert_raise(() => @flate.inflate_all(data))
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
  let inflater = @flate.Inflater()
  @test.assert_eq(inflater.last_consumed(), 0)
  @test.assert_eq(inflater.last_produced(), 0)
  let output = FixedArray::make(1, b'\x00')
  // A complete non-final stored block leaves the decoder waiting for another
  // block and gives the counters non-zero values to clear on the next call.
  let prefix : Bytes = [0x00, 0x01, 0x00, 0xFE, 0xFF, 0x41]
  let prefix_status = inflater.step(prefix, output.mut_view())
  assert_true(prefix_status is NeedMoreInput)
  @test.assert_eq(inflater.last_consumed(), prefix.length())
  @test.assert_eq(inflater.last_produced(), 1)
  let InflateError(kind, _) = @test.expect_error(() => {
    inflater.step(([0x07] : Bytes), output.mut_view())
  })
  @test.assert_eq(kind, Corrupt)
  @test.assert_eq(inflater.last_consumed(), 0)
  @test.assert_eq(inflater.last_produced(), 0)
}

///|
test "streaming Inflater turns EOF into a stable truncation error" {
  let inflater = @flate.Inflater()
  let output = FixedArray::make(64, b'\x00')
  for input in [([0x01] : Bytes), ([0x07] : Bytes)] {
    let InflateError(kind, _) = @test.expect_error(() => {
      inflater.step(input, output.mut_view(), end=true)
    })
    @test.assert_eq(kind, Truncated)
  }
  inflater.reset()
  @test.assert_eq(inflater.last_consumed(), 0)
  @test.assert_eq(inflater.last_produced(), 0)
  let source = b"reset clears the terminal error"
  let compressed = @flate.deflate_all(source)
  let status = inflater.step(compressed, output.mut_view(), end=true)
  let consumed = inflater.last_consumed()
  let produced = inflater.last_produced()
  assert_true(status is Done)
  @test.assert_eq(consumed, compressed.length())
  @test.assert_eq(produced, source.length())
}
