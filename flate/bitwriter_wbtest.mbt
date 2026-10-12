// Byte-aligned payloads of the bit writer.

///|
test "byte payloads append to the array sink from any view and offset" {
  let backing = Bytes::makei(70000, i => (i * 29 + i / 251).to_byte())
  for view_start in [0, 5] {
    let view = backing[view_start:]
    for offset in [0, 1, 300] {
      for length in [0, 1, 255, 65535, 65536] {
        let writer = BitWriter()
        writer.write_byte(b'\x7E')
        writer.write_bytes(view, offset, length)
        writer.write_byte(b'\x7F')
        @test.assert_eq(writer.out.length(), length + 2)
        @test.assert_eq(writer.out[0], b'\x7E')
        @test.assert_eq(writer.out[length + 1], b'\x7F')
        for i in 0..<length {
          guard writer.out[1 + i] == backing[view_start + offset + i] else {
            @test.fail("payload byte \{i} differs")
          }
        }
      }
    }
  }
}
