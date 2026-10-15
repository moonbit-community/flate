///|
/// Outputs around every capacity the first allocation and its doublings can
/// have: the batch, the checked tail and the growth between them give the
/// source back, with and without a callback, whose cadence does not move.
test "inflate_all preserves output across growth and cancellation boundaries" {
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
  for
    size in [
      0, 1, 2, 3, 7, 8, 9, 15, 16, 17, 255, 256, 257, 258, 259, 511, 512, 513, 1023,
      1024, 1025, 2047, 2048, 2049, 4095, 4096, 4097, 8191, 8192, 8193,
    ] {
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
