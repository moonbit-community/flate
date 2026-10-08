///|
/// Successful completion must retain only the cached transport suffix, not the
/// consumed zlib stream.
test "zlib completion releases consumed input and caches read-ahead" {
  let stream = compress(b"release the completed zlib stream")
  let suffix = b"NEXT-FRAME"
  let combined : Array[Byte] = []
  for byte in stream {
    combined.push(byte)
  }
  for byte in suffix {
    combined.push(byte)
  }
  let decoder = Decoder()
  let output = FixedArray::make(128, b'\x00')
  let status = decoder.step(Bytes::from_array(combined), output.mut_view())
  let consumed = decoder.last_consumed()
  assert_true(status is Done)
  @test.assert_eq(consumed, stream.length() + suffix.length())
  @test.assert_eq(decoder.pending.length(), 0)
  @test.assert_eq(decoder.pending_pos, 0)
  @test.assert_eq(decoder.unused, suffix)
  @test.assert_eq(decoder.unused_input(), suffix)
  @test.assert_eq(decoder.unused_input(), suffix)
}

///|
/// The failure latch is checked before buffering input or advancing either the
/// wrapper cursor.
test "zlib failed state freezes decoder cursors" {
  let malformed : Bytes = [0x78, 0x01, 0x07, 0x00, 0x00, 0x00, 0x01]
  let decoder = Decoder()
  let output = FixedArray::make(1, b'\x00')
  let ZlibError(first_kind, first_error) = @test.expect_error(() => {
    decoder.step(malformed, output.mut_view(), end=true)
  })
  let pending_pos = decoder.pending_pos
  let pending_length = decoder.pending.length()
  let ZlibError(repeated_kind, repeated_error) = @test.expect_error(() => {
    decoder.step(b"must not be accepted", output.mut_view())
  })
  assert_true(first_kind == InvalidDeflate)
  assert_true(repeated_kind == first_kind)
  @test.assert_eq(repeated_error, first_error)
  @test.assert_eq(decoder.pending_pos, pending_pos)
  @test.assert_eq(decoder.pending.length(), pending_length)
}
