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
