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

///|
test "canonical Huffman assigns values for two symbols" {
  let frequencies : FixedArray[Int] = [3, 0, 2]
  let lengths = FixedArray::make(3, 0)
  let values = FixedArray::make(3, 0U)
  gen_huffman(frequencies, 3, 15, lengths, code_val=values)
  @test.assert_eq(lengths, [1, 0, 1])
  @test.assert_eq(values, [0U, 0U, 1U])
}

///|
test "linear Huffman construction retains optimal bounded cost" {
  let rng = MatchLenDifferentialRng(0x142BCE83U)
  for n in [3, 5, 8, 19, 30, 64, 128, 286] {
    for max_bits in [7, 15] {
      guard n <= 1 << max_bits else { continue }
      for distribution in 0..<24 {
        let nodes : Array[Node] = []
        for lit in 0..<n {
          let freq = if distribution % 3 == 0 {
            1
          } else if distribution % 3 == 1 {
            1 << rng.below(16)
          } else {
            1 + rng.below(8192)
          }
          nodes.push({ lit, freq, })
        }
        nodes.sort_by((a, b) => {
          if a.freq != b.freq {
            a.freq - b.freq
          } else {
            a.lit - b.lit
          }
        })
        let counts = bit_counts(nodes, n, max_bits)
        let reference = bounded_bit_counts(nodes, n, max_bits)
        let lengths = FixedArray::make(n, 0)
        let expected = FixedArray::make(n, 0)
        assign_codes(counts, nodes, lengths, None)
        assign_codes(reference, nodes, expected, None)
        let mut cost = 0
        let mut optimal_cost = 0
        let mut kraft_sum = 0
        for node in nodes {
          let bits = lengths[node.lit]
          @test.assert_eq(bits >= 1 && bits <= max_bits, true)
          cost += node.freq * bits
          optimal_cost += node.freq * expected[node.lit]
          kraft_sum += 1 << (max_bits - bits)
        }
        @test.assert_eq(cost, optimal_cost)
        @test.assert_eq(kraft_sum, 1 << max_bits)
      }
    }
  }
}
