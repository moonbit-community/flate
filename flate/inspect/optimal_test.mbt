///|
/// Compare round-trip output and encoded size on repeated text containing
/// the lazy-matching pattern "abcde abcdef".
test "deflate_all_optimal round-trips and beats greedy" {
  let unit = b"optimal parsing pays where greedy grabs too early: abcde abcdef. "
  let arr : Array[Byte] = []
  for _r in 0..<120 {
    for b in unit {
      arr.push(b)
    }
  }
  let src = Bytes::from_array(arr)
  let opt = @flate.deflate_all_optimal(src, iterations=8)
  @test.assert_eq(@flate.inflate_all(opt), src)
  assert_true(opt.length() <= @flate.deflate_all(src).length())
}

///|
/// On this mixed text and pseudo-random input, compare the optimal output
/// with level 9, allowing 16 bytes of additional output.
test "deflate_all_optimal splits heterogeneous data" {
  let arr : Array[Byte] = []
  let text = b"a stretch of plain compressible text, over and over again. "
  for _r in 0..<80 {
    for b in text {
      arr.push(b)
    }
  }
  let mut x = 0xDEADBEEFU
  for _i in 0..<4800 {
    x = x ^ (x << 13)
    x = x ^ (x >> 17)
    x = x ^ (x << 5)
    arr.push((x & 0xFF).reinterpret_as_int().to_byte())
  }
  let src = Bytes::from_array(arr)
  let opt = @flate.deflate_all_optimal(src, iterations=5)
  @test.assert_eq(@flate.inflate_all(opt), src)
  assert_true(opt.length() <= @flate.deflate_all(src, level=9).length() + 16)
}

///|
test "deflate_all_optimal: empty and tiny inputs" {
  @test.assert_eq(@flate.inflate_all(@flate.deflate_all_optimal(b"")), b"")
  @test.assert_eq(@flate.inflate_all(@flate.deflate_all_optimal(b"x")), b"x")
  @test.assert_eq(
    @flate.inflate_all(@flate.deflate_all_optimal(b"aaaaaaaa")),
    b"aaaaaaaa",
  )
}
