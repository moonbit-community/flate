// Property-based tests for the CRC-32 and Adler-32 checksums.

///|
/// The one-shot, incremental, and byte-at-a-time CRC-32 forms agree.
test "property: crc32 forms agree" {
  @quickcheck.check(
    (data : Bytes) => {
      let expected = @checksum.crc32(data)
      let chunks = @checksum.Crc32()
      chunks.update(data)
      guard chunks.finish() == expected else { return false }
      let bytes = @checksum.Crc32()
      for byte in data {
        bytes.update_byte(byte)
      }
      bytes.finish() == expected
    },
    count=60,
    max_size=2000,
    seed=0xC0C11E,
  )
}

///|
/// Property: CRC-32 folds across concatenation boundaries.
test "property: crc32 is additive across concatenation" {
  @quickcheck.check(
    (pair : (Bytes, Bytes)) => {
      let (x, y) = pair
      let full = @checksum.crc32(x + y)
      let c = @checksum.Crc32()
      c.update(x)
      c.update(y)
      c.finish() == full
    },
    count=60,
    max_size=1000,
    seed=0xC0C12F,
  )
}

///|
/// Property: the one-shot and incremental (chunked and byte-at-a-time) Adler-32
/// forms all agree.
test "property: adler32 forms agree" {
  @quickcheck.check(
    (data : Bytes) => {
      let one = @checksum.adler32(data)
      let a = @checksum.Adler32()
      a.update(data)
      if a.finish() != one {
        return false
      }
      let b = @checksum.Adler32()
      for byte in data {
        b.update_byte(byte)
      }
      b.finish() == one
    },
    count=60,
    max_size=2000,
    seed=0xA021CE,
  )
}

///|
/// Property: Adler-32 folds across concatenation boundaries.
test "property: adler32 is additive across concatenation" {
  @quickcheck.check(
    (pair : (Bytes, Bytes)) => {
      let (x, y) = pair
      let full = @checksum.adler32(x + y)
      let a = @checksum.Adler32()
      a.update(x)
      a.update(y)
      a.finish() == full
    },
    count=60,
    max_size=1000,
    seed=0xA021CF,
  )
}
