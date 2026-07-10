///|
test "preset dictionaries retain exactly the final 32 KiB" {
  let dictionary_bytes = Array::make(40000, b'\x00')
  let message_bytes : Array[Byte] = []
  for i in 0..<512 {
    let byte = ((i * 73 + 19) % 251).to_byte()
    dictionary_bytes[40000 - 512 + i] = byte
    message_bytes.push(byte)
  }
  let dictionary = Bytes::from_array(dictionary_bytes)
  let message = Bytes::from_array(message_bytes)
  let deflater = @flate.Deflater::new(dictionary=dictionary[:])
  let compressed_buffer = FixedArray::make(4096, b'\x00')
  let deflate_status = deflater.step(
    message[:],
    compressed_buffer.mut_view(),
    action=Finish,
  )
  let consumed = deflater.last_consumed()
  let compressed_size = deflater.last_produced()
  assert_true(deflate_status is Done)
  assert_eq(consumed, message.length())
  // A correct final-32-KiB dictionary turns the 512-byte suffix into a match.
  assert_true(compressed_size < 100)
  let compressed : Array[Byte] = []
  for i in 0..<compressed_size {
    compressed.push(compressed_buffer[i])
  }
  let inflater = @flate.Inflater::new(dictionary=dictionary[:])
  let output = FixedArray::make(1024, b'\x00')
  let inflate_status = inflater.step(
    Bytes::from_array(compressed)[:],
    output.mut_view(),
  )
  let produced = inflater.last_produced()
  assert_true(inflate_status is Done)
  assert_eq(produced, message.length())
  for i in 0..<produced {
    assert_eq(output[i], message[i])
  }
  // `reset(dictionary=...)` is the allocation-reusing configuration path; it
  // must preload the same final 32 KiB as construction does.
  deflater.reset(dictionary=dictionary[:])
  let reset_status = deflater.step(
    message[:],
    compressed_buffer.mut_view(),
    action=Finish,
  )
  let reset_consumed = deflater.last_consumed()
  let reset_size = deflater.last_produced()
  assert_true(reset_status is Done)
  assert_eq(reset_consumed, message.length())
  assert_eq(reset_size, compressed_size)
}
