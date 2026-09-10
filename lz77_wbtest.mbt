///|
// Exhaustively compare candidate bytes, independently of the optimized probes.
fn scalar_find_match_reference(
  data : Bytes,
  finder : MatchFinder,
  position : Int,
  end : Int,
  base : Int,
  cfg : LevelConfig,
) -> Int {
  let limit = (end - position).min(258)
  let budget = if base >= cfg.good_length {
    cfg.max_chain >> 2
  } else {
    cfg.max_chain
  }
  for candidate = finder.head[hash3(data, position)], steps = 0, best = base, distance = 0 {
    guard candidate >= 0 &&
      position - candidate <= WINDOW_SIZE &&
      steps < budget else {
      break (best << 16) | distance
    }
    let length = scalar_match_len_up_to_reference(
      data, candidate, position, limit,
    )
    if length >= 3 && length > best {
      let distance = position - candidate
      if length >= cfg.nice_length {
        break (length << 16) | distance
      }
      continue finder.prev[candidate & WINDOW_MASK], steps + 1, length, distance
    }
    continue finder.prev[candidate & WINDOW_MASK], steps + 1, best, distance
  }
}

///|
test "match search agrees with scalar candidates across budgets tails and ring boundaries" {
  let rng = MatchLenDifferentialRng(0x53EA2C11U)
  for alphabet in [1, 8, 256] {
    let bytes = Array::make(STREAM_RING_SIZE + 260, b'\x00')
    for i in 0..<bytes.length() {
      bytes[i] = rng.below(alphabet).to_byte()
    }
    let input = Bytes::from_array(bytes)
    for
      position in [
        0,
        1,
        3,
        128,
        WINDOW_SIZE,
        WINDOW_SIZE + 1,
        STREAM_RING_SIZE - 1,
        STREAM_RING_SIZE,
      ] {
      let finder = MatchFinder()
      let window = FixedArray::make(STREAM_RING_STORAGE_SIZE, b'\x00')
      // Include a stale position just outside the allowed history as well.
      let first = (position - WINDOW_SIZE - 1).max(0)
      for i in first..<(position + 258) {
        let offset = i & STREAM_RING_MASK
        window[offset] = input[i]
        window[offset + STREAM_RING_SIZE] = input[i]
        if i < position {
          insert_pos(input, finder, i, input.length())
        }
      }
      for available in [3, 4, 16, 129, 258] {
        for base in [0, 1, 2, 3, 15, 128, 258] {
          for level in [0, 1, 4, 6, 9] {
            let end = position + available
            let cfg = level_configs[level]
            let expected = scalar_find_match_reference(
              input, finder, position, end, base, cfg,
            )
            @test.assert_eq(
              find_match(input, finder, position, end, base, cfg),
              expected,
            )
            @test.assert_eq(
              find_window_match(window, finder, position, end, base, cfg),
              expected,
            )
          }
        }
      }
    }
  }
}

///|
test "match probes refresh after improvements and retain the nearest equal match" {
  let bytes = Array::make(1800, b'\xFF')
  let position = 1500
  for i in 0..<258 {
    bytes[position + i] = (i % 251).to_byte()
  }
  // Search visits lengths 16, 32, 64, 64, 128, in that order.
  for entry in [(0, 128), (300, 64), (600, 64), (900, 32), (1200, 16)] {
    let (candidate, length) = entry
    for i in 0..<length {
      bytes[candidate + i] = bytes[position + i]
    }
  }
  let input = Bytes::from_array(bytes)
  let window = FixedArray::make(STREAM_RING_STORAGE_SIZE, b'\x00')
  for i in 0..<input.length() {
    window[i] = input[i]
    window[i + STREAM_RING_SIZE] = input[i]
  }
  let finder = MatchFinder()
  for candidate in [0, 300, 600, 900, 1200] {
    insert_pos(input, finder, candidate, input.length())
  }
  for budget in [1, 2, 3, 4, 5, 128] {
    for nice_length in [16, 32, 64, 258] {
      for base in [0, 2, 3, 15, 16, 31, 32, 63, 64, 128] {
        let cfg = {
          good_length: 32,
          max_lazy: 16,
          nice_length,
          max_chain: budget,
        }
        let expected = scalar_find_match_reference(
          input,
          finder,
          position,
          input.length(),
          base,
          cfg,
        )
        @test.assert_eq(
          find_match(input, finder, position, input.length(), base, cfg),
          expected,
        )
        @test.assert_eq(
          find_window_match(window, finder, position, input.length(), base, cfg),
          expected,
        )
      }
    }
  }
}

///|
test "batch insertion preserves scalar hash chains across tails and ring boundaries" {
  for repeated in [false, true] {
    let data = Array::make(2 * STREAM_RING_SIZE + 300, b'a')
    if !repeated {
      for i in 0..<data.length() {
        data[i] = ((i * 37 + i / 7) & 0xFF).to_byte()
      }
    }
    let input = Bytes::from_array(data)
    for
      start in [
        0,
        1,
        WINDOW_SIZE - 2,
        STREAM_RING_SIZE - 2,
        2 * STREAM_RING_SIZE - 2,
      ] {
      for length in [0, 1, 2, 3, 16, 257, 258] {
        for lookahead in 0..<=2 {
          let end = start + length
          let available_end = end + lookahead
          let first = (start - 64).max(0)
          let window = FixedArray::make(STREAM_RING_STORAGE_SIZE, b'\x00')
          for i in first..<available_end {
            let offset = i & STREAM_RING_MASK
            window[offset] = input[i]
            window[offset + STREAM_RING_SIZE] = input[i]
          }
          let scalar = MatchFinder()
          let direct = MatchFinder()
          let streaming = MatchFinder()
          for i in first..<start {
            insert_pos(input, scalar, i, available_end)
            insert_pos(input, direct, i, available_end)
            insert_window_pos(window, streaming, i, available_end)
          }
          for i in start..<end {
            insert_pos(input, scalar, i, available_end)
          }
          insert_positions(input, direct, start, end, available_end)
          insert_window_positions(window, streaming, start, end, available_end)
          @test.assert_eq(direct.head, scalar.head)
          @test.assert_eq(direct.prev, scalar.prev)
          @test.assert_eq(streaming.head, scalar.head)
          @test.assert_eq(streaming.prev, scalar.prev)
        }
      }
    }
  }
}

///|
test "lazy parsers keep hash chains strictly backward across block boundaries" {
  let input = b"abcabcXabcabcYabcabcZabcabcXabcabcY"
  let window = FixedArray::make(STREAM_RING_STORAGE_SIZE, b'\x00')
  for i in 0..<input.length() {
    window[i] = input[i]
    window[i + STREAM_RING_SIZE] = input[i]
  }
  for level in [1, 4, 6, 9] {
    for block_size in [4, input.length()] {
      let direct = MatchFinder()
      let streaming = MatchFinder()
      let direct_tokens : Array[Int] = []
      let streaming_tokens : Array[Int] = []
      let direct_ll = FixedArray::make(MAX_NUM_LIT, 0)
      let direct_dist = FixedArray::make(MAX_NUM_DIST, 0)
      let streaming_ll = FixedArray::make(MAX_NUM_LIT, 0)
      let streaming_dist = FixedArray::make(MAX_NUM_DIST, 0)
      let mut start = 0
      while start < input.length() {
        let end = (start + block_size).min(input.length())
        let processed = tokenize(
          input,
          direct,
          start,
          end,
          level_configs[level],
          direct_tokens,
          direct_ll,
          direct_dist,
        )
        let streamed = tokenize_window(
          window,
          streaming,
          start,
          end,
          input.length(),
          level_configs[level],
          streaming_tokens,
          streaming_ll,
          streaming_dist,
        )
        @test.assert_eq(processed, streamed)
        for position in 0..<processed.min(input.length() - 2) {
          // Every eligible position is inserted exactly once, even when a
          // deferred match overhangs a block boundary.
          @test.assert_eq(direct.prev[position] < position, true)
          @test.assert_eq(streaming.prev[position] < position, true)
        }
        @test.assert_eq(direct.head, streaming.head)
        @test.assert_eq(direct.prev, streaming.prev)
        start = processed
      }
      @test.assert_eq(direct_tokens, streaming_tokens)
    }
  }
}

///|
fn match_len_fixture(mismatch? : Int) -> Bytes {
  let data = Array::make(516, b'\x00')
  for i in 0..<258 {
    let byte = ((i * 37 + i / 7) & 0xFF).to_byte()
    data[i] = byte
    data[258 + i] = byte
  }
  if mismatch is Some(index) {
    data[258 + index] = (data[258 + index].to_int() ^ 0xFF).to_byte()
  }
  Bytes::from_array(data)
}

///|
fn scalar_match_len_up_to_reference(
  data : Bytes,
  src : Int,
  pos : Int,
  limit : Int,
) -> Int {
  let mut k = 0
  while k < limit && data[src + k] == data[pos + k] {
    k = k + 1
  }
  k
}

///|
priv struct MatchLenDifferentialRng {
  mut state : UInt
}

///|
fn MatchLenDifferentialRng::MatchLenDifferentialRng(
  seed : UInt,
) -> MatchLenDifferentialRng {
  { state: seed, }
}

///|
fn MatchLenDifferentialRng::next(self : MatchLenDifferentialRng) -> UInt {
  self.state = self.state * 1664525U + 1013904223U
  self.state
}

///|
fn MatchLenDifferentialRng::below(
  self : MatchLenDifferentialRng,
  maximum : Int,
) -> Int {
  (self.next() >> 1).reinterpret_as_int() % maximum
}

///|
fn assert_match_len_differential_case(
  rng : MatchLenDifferentialRng,
  case_index : Int,
  src : Int,
  pos : Int,
  limit : Int,
  mismatch : Int,
) -> Unit {
  let bytes = Array::make(768, b'\x00')
  for i in 0..<bytes.length() {
    bytes[i] = (rng.next() >> 24).reinterpret_as_int().to_byte()
  }
  for i in 0..<limit {
    bytes[pos + i] = bytes[src + i]
  }
  if mismatch >= 0 && mismatch < limit {
    bytes[pos + mismatch] = (bytes[pos + mismatch].to_int() ^ 0xFF).to_byte()
  }
  let data = Bytes::from_array(bytes)
  let expected = scalar_match_len_up_to_reference(data, src, pos, limit)
  let actual = match_len_up_to(data, src, pos, limit)
  if actual != expected {
    abort(
      "match_len_up_to differential mismatch: case=\{case_index}, src=\{src}, pos=\{pos}, limit=\{limit}, mismatch=\{mismatch}, expected=\{expected}, actual=\{actual}",
    )
  }
}

///|
test "packed tokens preserve all DEFLATE boundaries" {
  let lengths = [3, 3, 258, 258]
  let distances = [1, 32768, 1, 32768]
  for i in 0..<lengths.length() {
    let length = lengths[i]
    let distance = distances[i]
    let token = pack_match_token(length, distance)
    assert_true(token > 255)
    assert_true(token < 1 << 25)
    assert_eq(token >> 16, length)
    assert_eq(token & 0xFFFF, distance)
  }
}

///|
test "v128 match length finds the first unequal lane and scalar tail" {
  for mismatch in [0, 1, 2, 15, 16, 17, 31, 32, 127, 255, 257] {
    let data = match_len_fixture(mismatch~)
    assert_eq(match_len_up_to(data, 0, 258, 258), mismatch)
  }
  let identical = match_len_fixture()
  assert_eq(match_len_up_to(identical, 0, 258, 258), 258)
  assert_eq(match_len_up_to(b"abcabcX", 0, 3, 4), 3)
}

///|
test "match length agrees with scalar reference across boundaries and tails" {
  let rng = MatchLenDifferentialRng(0x51DDFEEDU)
  let limits = [
    0, 1, 2, 7, 15, 16, 17, 18, 31, 32, 33, 47, 48, 49, 63, 64, 65, 127, 128, 129,
    255, 256, 257, 258,
  ]
  let mut case_index = 0
  for limit in limits {
    let src = case_index * 7 % 96
    let pos = 384 + case_index * 11 % 96
    assert_match_len_differential_case(rng, case_index, src, pos, limit, -1)
    case_index = case_index + 1
    if limit > 0 {
      assert_match_len_differential_case(
        rng,
        case_index,
        src,
        pos,
        limit,
        limit - 1,
      )
      case_index = case_index + 1
    }
  }

  let mismatch_limits = [
    0, 1, 14, 15, 16, 17, 30, 31, 32, 33, 47, 48, 49, 63, 64, 65, 127, 128, 129,
    255, 256, 257,
  ]
  for mismatch in mismatch_limits {
    assert_match_len_differential_case(
      rng,
      case_index,
      mismatch * 5 % 96,
      384 + mismatch * 13 % 96,
      258,
      mismatch,
    )
    case_index = case_index + 1
  }
  for _ in 0..<512 {
    let src = rng.below(96)
    let pos = 384 + rng.below(96)
    let limit = rng.below(259)
    let mismatch = if limit == 0 || rng.below(4) == 0 {
      -1
    } else {
      rng.below(limit)
    }
    assert_match_len_differential_case(
      rng, case_index, src, pos, limit, mismatch,
    )
    case_index = case_index + 1
  }
}
