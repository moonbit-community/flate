///|
test "shared stored-length validation checks the complement" {
  validate_stored_length(0x1234, 0xEDCB)
  let InflateError(kind, _) = @test.expect_error(() => {
    validate_stored_length(1, 0)
  })
  @test.assert_eq(kind, Corrupt)
}

///|
test "shared dynamic counts retain their RFC boundaries" {
  @test.assert_eq(dynamic_literal_count(29), 286)
  let InflateError(kind, _) = @test.expect_error(() => dynamic_literal_count(30))
  @test.assert_eq(kind, Corrupt)
  @test.assert_eq(dynamic_distance_count(29), 30)
  let InflateError(kind, _) = @test.expect_error(() => {
    dynamic_distance_count(30)
  })
  @test.assert_eq(kind, Corrupt)
}

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

///|
test "shared back-reference validation uses available history" {
  assert_true(back_reference_distance_is_valid(1, 1))
  assert_true(back_reference_distance_is_valid(WINDOW_SIZE, WINDOW_SIZE))
  assert_false(back_reference_distance_is_valid(0, WINDOW_SIZE))
  assert_false(back_reference_distance_is_valid(-1, WINDOW_SIZE))
  assert_false(back_reference_distance_is_valid(2, 1))
  assert_false(back_reference_distance_is_valid(1, 0))
}
