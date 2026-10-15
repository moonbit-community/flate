///|
/// HLIT is validated immediately: a reserved value must not be hidden by a
/// missing HDIST field. The byte contains BFINAL=1, BTYPE=dynamic, HLIT=31 and
/// no further input.
test "reserved HLIT wins over a truncated HDIST" {
  let data : Bytes = [0xFD]
  let InflateError(kind, _) = @test.expect_error(() => inflate_all(data))
  @test.assert_eq(kind, Corrupt)
  let inflater = Inflater()
  let output = FixedArray::make(1, b'\x00')
  let InflateError(kind, _) = @test.expect_error(() => {
    inflater.step(data, output.mut_view(), end=true)
  })
  @test.assert_eq(kind, Corrupt)
}
