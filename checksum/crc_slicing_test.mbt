///|
// Bitwise reference does not share lookup tables with either production path.
fn crc_bitwise_reference(data : BytesView) -> UInt {
  let mut crc = 0xFFFFFFFFU
  for byte in data {
    crc = crc ^ byte.to_uint()
    for _ in 0..<8 {
      crc = if (crc & 1) == 0 { crc >> 1 } else { (crc >> 1) ^ 0xEDB88320U }
    }
  }
  crc ^ 0xFFFFFFFFU
}

///|
test "CRC slicing matches bitwise reference for unaligned views and tails" {
  let data = Bytes::from_array(
    Array::makei(16400, i => (i * 73 + i / 19).to_byte()),
  )
  for offset in 0..<8 {
    for
      size in [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 15, 16, 17, 255, 256, 257, 4095, 4096, 4097,
        16384,
      ] {
      let view = data[offset:offset + size]
      let expected = crc_bitwise_reference(view)
      @test.assert_eq(@checksum.crc32(view), expected)
      @test.assert_eq(@checksum.crc32_cancellable(view), Some(expected))
    }
  }
  for byte in [b'\x00', b'\xFF'] {
    let input = Bytes::make(65537, byte)
    @test.assert_eq(@checksum.crc32(input), crc_bitwise_reference(input[:]))
  }
}

///|
test "CRC slicing preserves mixed incremental updates and non-destructive finish" {
  let input = Bytes::from_array(
    Array::makei(8200, i => (i * 37 + i / 11).to_byte()),
  )
  for chunk in [1, 7, 8, 9, 15, 16, 17, 4095, 4096, 4097] {
    let crc = @checksum.Crc32()
    let mut position = 0
    while position < input.length() {
      let end = (position + chunk).min(input.length())
      crc.update(input[position:end])
      crc.update(b""[:])
      if end % 97 == 0 || end == input.length() {
        let expected = crc_bitwise_reference(input[:end])
        @test.assert_eq(crc.finish(), expected)
        @test.assert_eq(crc.finish(), expected)
      }
      position = end
      if position < input.length() {
        crc.update_byte(input[position])
        position = position + 1
      }
    }
    @test.assert_eq(crc.finish(), crc_bitwise_reference(input[:]))
  }
}
