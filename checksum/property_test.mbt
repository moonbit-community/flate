// Property-based tests for the CRC-32 and Adler-32 checksums.

///|
/// Property: the one-shot, incremental, byte-at-a-time, and cancellable CRC-32
/// forms all agree; an always-true cancellation returns `None`, and a
/// cancellation observed only after all data has been processed also returns
/// `None` instead of silently succeeding.
test "property: crc32 forms agree and are cancellable" {
  @quickcheck.check(
    (data : Bytes) => {
      let one = crc32(data)
      let c = Crc32()
      c.update(data)
      if c.finish() != one {
        return false
      }
      let d = Crc32()
      for b in data {
        d.update_byte(b)
      }
      if d.finish() != one {
        return false
      }
      if crc32_cancellable(data, cancelled=() => false) != Some(one) {
        return false
      }
      if crc32_cancellable(data, cancelled=() => true) != None {
        return false
      }
      // `cancelled` is polled at entry, after each 4 KiB chunk, and once more
      // after the loop. A callback that turns `true` only on the very last
      // poll must still cancel, exercising the post-loop check.
      let total_polls = 2 + (data.length() - 1) / 4096
      let mut polls = 0
      let late_cancel = crc32_cancellable(data, cancelled=() => {
        polls = polls + 1
        polls >= total_polls
      })
      if late_cancel != None {
        return false
      }
      true
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
      let full = crc32(x + y)
      let c = Crc32()
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
      let one = adler32(data)
      let a = Adler32()
      a.update(data)
      if a.finish() != one {
        return false
      }
      let b = Adler32()
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
      let full = adler32(x + y)
      let a = Adler32()
      a.update(x)
      a.update(y)
      a.finish() == full
    },
    count=60,
    max_size=1000,
    seed=0xA021CF,
  )
}
