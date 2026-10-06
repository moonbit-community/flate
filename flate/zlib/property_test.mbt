// Property-based tests for the zlib container wrapper.

///|
/// Property: `compress` round-trips arbitrary bytes at every level, and
/// the optimal path round-trips too.
test "property: zlib round-trips at every level" {
  @quickcheck.check(
    (data : Bytes) => {
      for level in 0..<10 {
        if @zlib.decompress(@zlib.compress(data, level~)) != data {
          return false
        }
      }
      if @zlib.decompress(@zlib.compress_optimal(data, iterations=3)) != data {
        return false
      }
      true
    },
    count=40,
    max_size=2000,
    seed=0x7A1A001,
  )
}

///|
/// Property: decoding arbitrary bytes through `decompress` never panics
/// and is deterministic — the same input yields the same bytes or error every
/// time.
test "property: decompress never panics and is deterministic" {
  @quickcheck.check(
    (data : Bytes) => {
      let a = Ok(@zlib.decompress(data)) catch {
        ZlibError(kind, _) => Err(kind)
      }
      let b = Ok(@zlib.decompress(data)) catch {
        ZlibError(kind, _) => Err(kind)
      }
      a == b
    },
    count=60,
    max_size=2000,
    seed=0x7A1A002,
  )
}
