///|
test "Adler group bound never forms an index past the end" {
  let max = 2147483647
  for
    entry in [
      (0, 0),
      (0, 7),
      (0, 8),
      (5, 3800),
      (max - 7, max),
      (max - 8, max),
      (max - 3800, max),
      (max - 3807, max - 7),
    ] {
    let (start, end) = entry
    let groups_end = adler_groups_end(start, end)
    assert_true(groups_end >= start && groups_end <= end)
    assert_true(end - groups_end < 8)
    assert_eq((groups_end - start) % 8, 0)
  }
}

///|
/// The vector kernel against the serial definition, unreduced like the kernel:
/// every start and length around the chunk size, views that end exactly at
/// the end of their backing bytes, and the largest sums a block can reach.
#cfg(any(target="native", target="wasm"))
test "Adler 16-byte chunks agree with the serial sums and stay inside the view" {
  let mut state = 0x2545F491U
  let noise = Bytes::makei(4200, _ => {
    state = state * 1103515245U + 12345U
    (state >> 24).reinterpret_as_int().to_byte()
  })
  let high = Bytes::make(4200, b'\xFF')
  for input in [noise, high] {
    for seed in [(1, 0), (65520, 65520)] {
      for start in 0..<18 {
        for
          length in [
            ..Array::makei(82, i => i),
            127,
            128,
            129,
            3783,
            3784,
            3785,
            ADLER_BLOCK_SIZE,
          ] {
          let end = start + length
          // The backing bytes end where the view ends, then sixteen bytes
          // later: neither may change what the kernel folds.
          for spare in [0, 16] {
            let backing = input[:end + spare].to_owned()
            let view = backing[:end]
            let checksum = Adler32()
            checksum.a = seed.0
            checksum.b = seed.1
            let position = checksum.fold_chunks16(view, start, end)
            assert_eq(position, start + length / 16 * 16)
            let mut a = seed.0
            let mut b = seed.1
            for i in start..<position {
              a = a + view[i].to_int()
              b = b + a
            }
            assert_eq(checksum.a, a)
            assert_eq(checksum.b, b)
          }
        }
      }
    }
  }
}

///|
/// A view into the middle of larger bytes is folded from its own start.
#cfg(any(target="native", target="wasm"))
test "Adler 16-byte chunks honour the offset of a view" {
  let backing = Bytes::makei(300, i => (i * 131 + 7).to_byte())
  for offset in [0, 1, 15, 16, 17, 100] {
    for length in [0, 15, 16, 17, 64, 200] {
      let view = backing[offset:offset + length]
      let checksum = Adler32()
      let position = checksum.fold_chunks16(view, 0, length)
      let mut a = 1
      let mut b = 0
      for i in 0..<position {
        a = a + backing[offset + i].to_int()
        b = b + a
      }
      assert_eq(position, length / 16 * 16)
      assert_eq(checksum.a, a)
      assert_eq(checksum.b, b)
    }
  }
}
