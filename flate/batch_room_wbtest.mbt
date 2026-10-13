// The native batch needs 258 bytes of output room. `reserve_token` gives a
// growing output that room; a caller's storage is never replaced.

///|
#cfg(target="native")
test "reserve_token grows a growing output and nothing else" {
  // With room for a token the storage stays as it is; a byte short of that
  // it doubles, or grows to what the token needs, and keeps what was decoded.
  for capacity in [1, 100, 257, 258, 600, 5000] {
    for length in [0, 1, capacity / 2, capacity - 258, capacity - 257, capacity] {
      guard length >= 0 else { continue }
      let out = DecodeOutput(capacity)
      for i in 0..<length {
        out.storage[i] = (i * 7 + 1).to_byte()
      }
      out.length = length
      let before = out.storage
      out.reserve_token()
      @test.assert_eq(out.length, length)
      if capacity - length >= 258 {
        assert_true(physical_equal(out.storage, before))
      } else {
        @test.assert_eq(out.storage.length(), (capacity * 2).max(length + 258))
      }
      for i in 0..<length {
        @test.assert_eq(out.storage[i], (i * 7 + 1).to_byte())
      }
    }
  }
  // The caller's storage is the caller's, however little of it is left.
  let storage = FixedArray::make(300, b'\xA5')
  let fixed = DecodeOutput::into(storage)
  fixed.length = 299
  fixed.reserve_token()
  assert_true(physical_equal(fixed.storage, storage))
}

///|
/// Without allocating at the limit: room is made while the storage can still
/// double, and never beyond, where growth is by the byte.
#cfg(target="native")
test "reserves_token stops where growth is no longer geometric" {
  @test.assert_eq(reserves_token(600, 342), false)
  @test.assert_eq(reserves_token(600, 343), true)
  let half = MAX_DECODE_OUTPUT_SIZE / 2
  @test.assert_eq(reserves_token(half, half), true)
  @test.assert_eq(grown_decode_output_capacity(half, half + 258), half * 2)
  @test.assert_eq(reserves_token(half + 1, half + 1), false)
  @test.assert_eq(reserves_token(half + 1, half - 255), false)
  @test.assert_eq(
    reserves_token(MAX_DECODE_OUTPUT_SIZE, MAX_DECODE_OUTPUT_SIZE),
    false,
  )
}

///|
/// Outputs around every capacity the first allocation and its doublings can
/// have: the batch, the checked tail and the growth between them give the
/// source back, with and without a callback, whose cadence does not move.
test "inflate_all decodes outputs of every small size" {
  let text = inflate_differential_pattern(
    b"a growing output, token by token. ", 9000,
  )
  let source = Bytes::makei(9000, i => {
    if i % 5 == 0 {
      (i / 5 * 31).to_byte()
    } else {
      text[i]
    }
  })
  for size in 0..<9000 {
    guard size < 1100 || size % 97 == 0 || (size & (size - 1)) < 4 else {
      continue
    }
    let plain = source[:size].to_owned()
    let compressed = deflate_all(plain)
    guard inflate_all(compressed) == plain else {
      fail("inflate_all differs at \{size} bytes")
    }
    let mut polls = 0
    let polled = inflate_all(compressed, cancelled=() => {
      polls += 1
      false
    })
    guard polled == plain && polls == 1 + size / 4096 else {
      fail("inflate_all with a callback: \{polls} polls at \{size} bytes")
    }
  }
}
