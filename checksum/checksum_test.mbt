// Proof of correctness for @checksum.crc32 / @checksum.adler32: the expected values
// below come from python's zlib (zlib.crc32 / zlib.adler32, the canonical
// reference implementation). The "gmlewis golden" vector is also gmlewis/crc32's
// own published test vector (0x7d0a377f), so this triple-checks our output
// against both python's zlib and gmlewis/crc32.

///|
test "crc32 matches the zlib reference (and gmlewis golden vector)" {
  inspect(@checksum.crc32(b""), content="0") // 0x00000000
  inspect(@checksum.crc32(b"hello"), content="907060870") // 0x3610A686
  // gmlewis/crc32's own golden vector:
  inspect(
    @checksum.crc32(b"C is as portable as Stonehedge!!"),
    content="2097821567",
  ) // 0x7D0A377F
  inspect(
    @checksum.crc32(b"The quick brown fox jumps over the lazy dog"),
    content="1095738169",
  ) // 0x414FA339
  let all256 = Array::make(256, b'\x00')
  for i in 0..<256 {
    all256[i] = i.to_byte()
  }
  inspect(@checksum.crc32(Bytes::from_array(all256)), content="688229491") // 0x29058C73
}

///|
test "adler32 matches the zlib reference" {
  inspect(@checksum.adler32(b""), content="1") // 0x00000001
  inspect(@checksum.adler32(b"hello"), content="103547413") // 0x062C0215
  inspect(
    @checksum.adler32(b"C is as portable as Stonehedge!!"),
    content="3042642697",
  ) // 0xB55B0B09
  inspect(
    @checksum.adler32(b"The quick brown fox jumps over the lazy dog"),
    content="1541148634",
  ) // 0x5BDC0FDA
  let all256 = Array::make(256, b'\x00')
  for i in 0..<256 {
    all256[i] = i.to_byte()
  }
  inspect(@checksum.adler32(Bytes::from_array(all256)), content="2918612865") // 0xADF67F81
}

///|
/// The incremental accumulators must agree with the one-shot functions
/// regardless of how the input is split across `update` calls.
test "incremental Crc32/Adler32 match the one-shot result across chunk splits" {
  let data = b"The quick brown fox jumps over the lazy dog"
  let crc = @checksum.Crc32::new()
  let adler = @checksum.Adler32::new()
  // Feed one byte at a time — the worst-case chunking.
  for i in 0..<data.length() {
    crc.update(data[i:i + 1])
    adler.update(data[i:i + 1])
  }
  assert_eq(crc.finish(), @checksum.crc32(data))
  assert_eq(adler.finish(), @checksum.adler32(data))
  // And an uneven multi-chunk split.
  let crc2 = @checksum.Crc32::new()
  let adler2 = @checksum.Adler32::new()
  crc2.update(data[0:10])
  crc2.update(data[10:11])
  crc2.update(data[11:data.length()])
  adler2.update(data[0:10])
  adler2.update(data[10:11])
  adler2.update(data[11:data.length()])
  assert_eq(crc2.finish(), @checksum.crc32(data))
  assert_eq(adler2.finish(), @checksum.adler32(data))
  // An empty stream equals the empty-input one-shot value.
  assert_eq(@checksum.Crc32::new().finish(), @checksum.crc32(b""))
  assert_eq(@checksum.Adler32::new().finish(), @checksum.adler32(b""))
}
