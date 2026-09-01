// Property-based tests for the zlib container wrapper.

///|
/// Property: `zlib_compress` round-trips arbitrary bytes at every level, and
/// the optimal path round-trips too.
test "property: zlib round-trips at every level" {
  @quickcheck.check(
    (data : Bytes) => {
      for level in 0..<10 {
        if @zlib.zlib_decompress(@zlib.zlib_compress(data, level~)) != data {
          return false
        }
      }
      if @zlib.zlib_decompress(@zlib.zlib_compress_optimal(data, iterations=3)) !=
        data {
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
/// Property: decoding arbitrary bytes through `zlib_decompress` never panics
/// and is deterministic — the same input yields the same bytes or error every
/// time.
test "property: zlib_decompress never panics and is deterministic" {
  @quickcheck.check(
    (data : Bytes) => {
      let a = try @zlib.zlib_decompress(data) catch {
        @zlib.ZlibError(_, _) => b""
      } noraise {
        ok => ok
      }
      let b = try @zlib.zlib_decompress(data) catch {
        @zlib.ZlibError(_, _) => b""
      } noraise {
        ok => ok
      }
      a == b
    },
    count=60,
    max_size=2000,
    seed=0x7A1A002,
  )
}
