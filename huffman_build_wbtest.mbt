///|
test "canonical Huffman codes retain symbol order across frequency groups" {
  // The classic six-symbol tree, with unused symbols interspersed. The
  // optimal lengths are 4,4,3,3,3,1; DEFLATE transmits reversed codewords.
  let frequencies : FixedArray[Int] = [5, 0, 9, 12, 0, 13, 16, 45]
  let lengths = FixedArray::make(8, 0)
  let values = FixedArray::make(8, 0U)
  gen_huffman(frequencies, 8, 15, lengths, code_val=values)
  @test.assert_eq(lengths, [4, 0, 4, 3, 0, 3, 3, 1])
  @test.assert_eq(values, [7U, 0U, 15U, 1U, 0U, 5U, 3U, 0U])

  let limited_lengths = FixedArray::make(8, 0)
  let limited_values = FixedArray::make(8, 0U)
  gen_huffman(frequencies, 8, 3, limited_lengths, code_val=limited_values)
  @test.assert_eq(limited_lengths, [3, 0, 3, 3, 0, 3, 2, 2])
  @test.assert_eq(limited_values, [1U, 0U, 5U, 3U, 0U, 7U, 0U, 2U])

  let lengths_only = FixedArray::make(8, 0)
  gen_huffman(frequencies, 8, 3, lengths_only)
  @test.assert_eq(lengths_only, limited_lengths)
}
