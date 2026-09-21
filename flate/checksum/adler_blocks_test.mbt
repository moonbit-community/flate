///|
// Independent bytewise reference: every intermediate sum stays reduced.
fn adler_reference(data : BytesView) -> UInt {
  let mut a = 1
  let mut b = 0
  for byte in data {
    a = (a + byte.to_int()) % 65521
    b = (b + a) % 65521
  }
  (b.reinterpret_as_uint() << 16) | a.reinterpret_as_uint()
}

///|
test "Adler block reduction agrees with bytewise reference at boundaries" {
  for size in [0, 1, 3799, 3800, 3801, 7599, 7600, 7601, 65536, 1048576] {
    for byte in [b'\x00', b'\xFF'] {
      let input = Bytes::make(size, byte)
      @test.assert_eq(@checksum.adler32(input), adler_reference(input[:]))
    }
  }
}

///|
test "Adler mixed updates and finish preserve prefix state across blocks" {
  let input = Bytes::from_array(
    Array::makei(32000, i => (i * 73 + i / 19).to_byte()),
  )
  for chunk in [1, 3799, 3800, 3801, 7601] {
    let checksum = @checksum.Adler32()
    let mut position = 0
    while position < input.length() {
      let end = (position + chunk).min(input.length())
      checksum.update(input[position:end])
      checksum.update(b""[:])
      // finish is non-destructive, including before a subsequent update_byte.
      if chunk > 1 || end == input.length() {
        let expected = adler_reference(input[:end])
        @test.assert_eq(checksum.finish(), expected)
        @test.assert_eq(checksum.finish(), expected)
      }
      position = end
      if position < input.length() {
        checksum.update_byte(input[position])
        position = position + 1
      }
    }
    @test.assert_eq(checksum.finish(), adler_reference(input[:]))
  }
}
