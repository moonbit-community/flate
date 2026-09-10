///|
test "match copies preserve overlap and exact output boundaries" {
  for
    distance in [
      1, 2, 3, 4, 7, 8, 15, 16, 17, 31, 32, 255, 256, 257, 258, 32768,
    ] {
    let history = Bytes::makei(distance, i => (i * 73 + i / 19).to_byte())
    // Include the 1- and 2-byte fragments created at cancellation boundaries.
    for length in 1..<=258 {
      for extra in [0, 7] {
        let storage = FixedArray::make(distance + length + extra, b'\xA5')
        storage.blit_from_bytes(0, history, 0, distance)
        let out = DecodeOutput::into(storage)
        out.length = distance
        out.append_repeated_suffix(distance, length)
        @test.assert_eq(out.length, distance + length)
        for i in 0..<length {
          @test.assert_eq(storage[distance + i], history[i % distance])
        }
        for i in (distance + length)..<storage.length() {
          @test.assert_eq(storage[i], b'\xA5')
        }
      }
    }
  }
}

///|
test "optimized matches stop exactly at cancellation boundaries" {
  for pattern in [b"R", b"abc", b"a longer repeated pattern"] {
    let source = Bytes::makei(9000, i => pattern[i % pattern.length()])
    let mut calls = 0
    let decoder = MemDecoder(deflate_all(source), () => {
      calls += 1
      calls == 2
    })
    let err = @test.expect_error(() => decoder.run())
    guard err is InflateError(kind, _)
    @test.assert_eq(kind, Cancelled)
    @test.assert_eq(calls, 2)
    @test.assert_eq(decoder.out.length, 4096)
    @test.assert_eq(decoder.out.to_bytes(), source[:4096].to_owned())
  }
}
