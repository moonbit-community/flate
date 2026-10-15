// Independent golden values from Python zlib; the Stonehedge CRC vector
// is also published by gmlewis/crc32.

///|
test "crc32 matches the zlib reference (and gmlewis golden vector)" {
  for
    (input, expected) in [
      (b"", 0x00000000U),
      (b"hello", 0x3610A686U),
      (b"C is as portable as Stonehedge!!", 0x7D0A377FU),
      (b"The quick brown fox jumps over the lazy dog", 0x414FA339U),
      (Bytes::makei(256, i => i.to_byte()), 0x29058C73U),
    ] {
    @test.assert_eq(@checksum.crc32(input), expected)
  }
}

///|
test "adler32 matches the zlib reference" {
  for
    (input, expected) in [
      (b"", 0x00000001U),
      (b"hello", 0x062C0215U),
      (b"C is as portable as Stonehedge!!", 0xB55B0B09U),
      (b"The quick brown fox jumps over the lazy dog", 0x5BDC0FDAU),
      (Bytes::makei(256, i => i.to_byte()), 0xADF67F81U),
    ] {
    @test.assert_eq(@checksum.adler32(input), expected)
  }
}
