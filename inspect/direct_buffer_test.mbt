///|
fn direct_bytes(buffer : FixedArray[Byte], length : Int) -> Bytes {
  Bytes::from_array(buffer[:length])
}

///|
fn direct_sources() -> Array[Bytes] {
  let varied = Array::make(40000, b'\x00')
  for i in 0..<varied.length() {
    varied[i] = (i * 73 + i / 19).to_byte()
  }
  [
    b"",
    b"caller-owned raw DEFLATE output",
    Bytes::from_array(Array::make(20000, b'R')),
    Bytes::from_array(varied),
  ]
}

///|
test "caller-buffer codecs match one-shot streams and reuse workspace" {
  for level in [0, 1, 6, 9] {
    let compressor = @flate.Compressor(level~)
    let decompressor = @flate.Decompressor()
    for source in direct_sources() {
      let compressed_buffer = FixedArray::make(
        @flate.deflate_bound(source.length()),
        b'\x00',
      )
      guard compressor.compress_into(source, compressed_buffer)
        is Some(compressed_len) else {
        @test.fail("deflate_bound did not fit its source")
      }
      let compressed = direct_bytes(compressed_buffer, compressed_len)
      @test.assert_eq(compressed, @flate.deflate_all(source, level~))

      let decoded_buffer = FixedArray::make(source.length(), b'\x00')
      let decoded_len = decompressor.decompress_into(compressed, decoded_buffer)
      @test.assert_eq(decoded_len, source.length())
      @test.assert_eq(direct_bytes(decoded_buffer, decoded_len), source)
    }
  }
}

///|
test "caller-buffer codecs report insufficient output capacity" {
  let source = b"a direct buffer needs enough space for its complete stream"
  let compressor = @flate.Compressor()
  let no_compressed_space = FixedArray::make(0, b'\x00')
  @test.assert_eq(compressor.compress_into(source, no_compressed_space), None)

  let compressed = @flate.deflate_all(source)
  let decompressor = @flate.Decompressor()
  let short_output = FixedArray::make(source.length() - 1, b'\x00')
  try ignore(decompressor.decompress_into(compressed, short_output)) catch {
    InflateError(kind, _) => @test.assert_eq(kind, OutputLimitExceeded)
  } noraise {
    _ => @test.fail("short direct output was accepted")
  }
}

///|
test "caller-buffer one-shot convenience functions round-trip" {
  let source = b"single-use caller-owned buffers"
  let compressed_buffer = FixedArray::make(
    @flate.deflate_bound(source.length()),
    b'\x00',
  )
  guard @flate.deflate_into(source, compressed_buffer) is Some(compressed_len) else {
    @test.fail("deflate_into did not fit deflate_bound")
  }
  let compressed = direct_bytes(compressed_buffer, compressed_len)
  let decoded_buffer = FixedArray::make(source.length(), b'\x00')
  let decoded_len = @flate.inflate_into(compressed, decoded_buffer)
  @test.assert_eq(direct_bytes(decoded_buffer, decoded_len), source)
}
