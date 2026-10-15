// Property-based tests for the gzip container wrapper.

///|
/// Property: `compress` round-trips arbitrary bytes at every level, and
/// the optimal path round-trips too.
test "property: gzip round-trips at every level" {
  @quickcheck.check(
    (data : Bytes) => {
      for level in 0..<10 {
        if @gzip.decompress(@gzip.compress(data, level~)) != data {
          return false
        }
      }
      if @gzip.decompress(@gzip.compress_optimal(data, iterations=3)) != data {
        return false
      }
      true
    },
    count=40,
    max_size=2000,
    seed=0x6A7F001,
  )
}
