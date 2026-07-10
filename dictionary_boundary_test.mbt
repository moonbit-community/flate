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
  let deflater = @flate.Deflater::new()
  deflater.set_dictionary(dictionary[:])
  let compressed_buffer = FixedArray::make(4096, b'\x00')
  let (deflate_status, consumed, compressed_size) = deflater.step(
    message[:],
    compressed_buffer.mut_view(),
    end=true,
  )
  assert_true(deflate_status is Done)
  assert_eq(consumed, message.length())
  // A correct final-32-KiB dictionary turns the 512-byte suffix into a match.
  assert_true(compressed_size < 100)
  let compressed : Array[Byte] = []
  for i in 0..<compressed_size {
    compressed.push(compressed_buffer[i])
  }
  let inflater = @flate.Inflater::new()
  inflater.set_dictionary(dictionary[:])
  let output = FixedArray::make(1024, b'\x00')
  let (inflate_status, _, produced) = inflater.step(
    Bytes::from_array(compressed)[:],
    output.mut_view(),
  )
  assert_true(inflate_status is Done)
  assert_eq(produced, message.length())
  for i in 0..<produced {
    assert_eq(output[i], message[i])
  }
}
