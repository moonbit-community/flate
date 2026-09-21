///|
test "distance symbols agree with the linear mapping for every legal distance" {
  for distance in 1..<=WINDOW_SIZE {
    let expected = for symbol = 0 {
      guard symbol + 1 < MAX_NUM_DIST && dist_base[symbol + 1] <= distance else {
        break symbol
      }
      continue symbol + 1
    }
    @test.assert_eq(dist_index(distance), expected)
  }
}
