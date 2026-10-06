///|
test "compression levels clamp at both public boundaries" {
  let source = b"level clamping must be deterministic deterministic"
  @test.assert_eq(deflate_all(source, level=-7), deflate_all(source, level=0))
  @test.assert_eq(deflate_all(source, level=99), deflate_all(source, level=9))
  let low = Deflater(level=-7)
  let high = Deflater(level=99)
  @test.assert_eq(low.level, 0)
  @test.assert_eq(high.level, 9)
  @test.assert_eq(
    inflate_all(deflate_all_optimal(b"iteration clamp", iterations=0)),
    b"iteration clamp",
  )
}

///|
test "stored blocks split at the 16-bit LEN limit" {
  let split_source = Bytes::from_array(Array::make(65536, b'\x5A'))
  let split_stored = BitWriter()
  write_stored(
    split_stored,
    split_source,
    0,
    split_source.length(),
    is_final=true,
  )
  @test.assert_eq(
    inflate_all(Bytes::from_array(split_stored.out)),
    split_source,
  )
}

///|
test "lazy match pending at a block boundary is committed" {
  // The token range is one byte wide, but lookahead extends beyond it. A
  // history match beginning at index 3 is deferred by lazy parsing; reaching
  // `end=4` commits that pending match in tokenize's boundary epilogue.
  let data = b"abcabcabc"
  let tokens : Array[Int] = []
  let ll_freq = FixedArray::make(286, 0)
  let d_freq = FixedArray::make(30, 0)
  let finder = MatchFinder()
  for i in 0..<3 {
    insert_pos(data, finder, i, data.length())
  }
  let processed = tokenize(
    data,
    finder,
    3,
    4,
    level_configs[6],
    tokens,
    ll_freq,
    d_freq,
  )
  @test.assert_eq(tokens.length(), 1)
  let token = tokens[0]
  assert_true(token >= 256)
  let length = token >> 16
  let distance = token & 0xFFFF
  assert_true(length >= 3)
  @test.assert_eq(distance, 3)
  assert_true(ll_freq[257 + len_to_idx[length]] > 0)
  assert_true(d_freq[dist_index(distance)] > 0)
  assert_true(processed > 4)
}

///|
test "optimal planner crosses its master-block boundary" {
  // Repetition keeps the optimal parse small while forcing the outer planner
  // to choose its capped master target at least once.
  let source = Bytes::from_array(
    Array::make(OPTIMAL_MASTER_BLOCK + MIN_LOOKAHEAD + 1, b'\x41'),
  )
  let compressed = deflate_all_optimal(source, iterations=1)
  @test.assert_eq(inflate_all(compressed), source)
}

///|
fn make_second_split_candidate_for_coverage(variant : Int) -> Bytes {
  let bytes : Array[Byte] = []
  let trap = b"abcde abcdef lazy parsing boundary trap; "
  let mut state = (0xA341316CU + variant.reinterpret_as_uint()) | 1U
  for segment in 0..<7 {
    let length = 384 + (variant * 97 + segment * 193) % 521
    match (segment + variant) % 4 {
      0 =>
        for _ in 0..<length {
          state = state ^ (state << 13)
          state = state ^ (state >> 17)
          state = state ^ (state << 5)
          bytes.push((state & 0xFF).to_byte())
        }
      1 =>
        for i in 0..<length {
          bytes.push(trap[i % trap.length()])
        }
      2 =>
        for i in 0..<length {
          bytes.push(((i / (7 + variant % 9)) & 0x03).to_byte())
        }
      _ =>
        for i in 0..<length {
          bytes.push(((i * 29 + segment * 71) & 0xFF).to_byte())
        }
    }
  }
  Bytes::from_array(bytes)
}

///|
test "optimal planner round-trips mixed segment distributions" {
  let source = make_second_split_candidate_for_coverage(7)
  let compressed = deflate_all_optimal(source, iterations=2)
  @test.assert_eq(inflate_all(compressed), source)
}

///|
test "split planner cuts and resets observations across literal-class changes" {
  // Exercise planner behavior independently of a particular matchfinder's
  // token choices: three long literal regions have sharply different classes.
  let tokens : Array[Int] = []
  for literal in [97, 98, 97] {
    for _ in 0..<12000 {
      tokens.push(literal)
    }
  }
  let cuts = choose_splits(tokens)
  @test.assert_eq(cuts.length() >= 2, true)
  let data = Bytes::makei(tokens.length(), i => tokens[i].to_byte())
  let writer = BitWriter()
  cuts.push(tokens.length())
  let mut start = 0
  for end in cuts {
    @test.assert_eq(end > start && end <= tokens.length(), true)
    let literal_freq = FixedArray::make(MAX_NUM_LIT, 0)
    let distance_freq = FixedArray::make(MAX_NUM_DIST, 0)
    for i in start..<end {
      literal_freq[tokens[i]] += 1
    }
    emit_block(
      writer,
      data,
      start,
      end,
      tokens[start:end],
      literal_freq,
      distance_freq,
      is_final=end == tokens.length(),
    )
    start = end
  }
  writer.flush()
  @test.assert_eq(inflate_all(Bytes::from_array(writer.out)), data)
}

///|
fn coverage_divergent_bytes(size : Int) -> Bytes {
  let mut state = 0x12345678U
  Bytes::makei(size, i => {
    state = state * 1103515245U + 12345U
    let raw = ((state >> 16) & 0x3FU).reinterpret_as_int()
    match i / 16384 % 4 {
      0 => (0x40 + raw).to_byte()
      1 => (0x80 + raw).to_byte()
      2 => (0x20 + raw).to_byte()
      _ => (0xC0 + raw).to_byte()
    }
  })
}

///|
test "split planner round-trips changing byte distributions" {
  let data = coverage_divergent_bytes(65535)
  let compressed = deflate_all_split(data)
  @test.assert_eq(inflate_all(compressed), data)
}

///|
test "reusable compressor covers multi-block encode loop" {
  // The public whole-buffer helper tests normally fit in one block. A
  // reusable compressor must also carry its workspace into a second block.
  // A different suffix prevents a boundary-spanning periodic match from
  // making the first parse consume the entire input.
  let source = Bytes::makei(65535, i => {
      match i % 4 {
        0 => b'W'
        1 => b'X'
        2 => b'Y'
        _ => b'Z'
      }
    }) +
    Bytes::make(257, b'\x00')
  let codec = Compressor(level=6)
  let compressed = codec.compress(source)
  @test.assert_eq(inflate_all(compressed), source)
  @test.assert_eq(
    codec.compress(b"reuse after multi-block"),
    deflate_all(b"reuse after multi-block"),
  )
}
