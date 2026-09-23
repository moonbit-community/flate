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
  guard base < limit && budget > 0 else { return base << 16 }
  let short = finder.short_head[short_hash3(
      data,
      position,
      shift=finder.short_shift,
    )] -
    finder.position_base
  let short_matches = base < 3 &&
    short >= 0 &&
    position - short <= WINDOW_SIZE &&
    scalar_match_len_up_to_reference(data, short, position, limit) >= 3
  let initial_best = if short_matches { 3 } else { base }
  let initial_distance = if short_matches { position - short } else { 0 }
  guard limit >= 4 && initial_best < limit else {
    return (initial_best << 16) | initial_distance
  }
  for candidate = finder.head[long_hash_product(
          read_match_word(data, position) * 0x1E35A7BDU,
          shift=finder.long_shift,
        )] -
        finder.position_base, steps = 0, best = initial_best, distance = initial_distance {
    guard candidate >= 0 &&
      position - candidate <= WINDOW_SIZE &&
      steps < budget else {
      break (best << 16) | distance
    }
    let length = scalar_match_len_up_to_reference(
      data, candidate, position, limit,
    )
    if length >= 4 && length > best {
      let distance = position - candidate
      if length >= cfg.nice_length {
        break (length << 16) | distance
      }
      continue chain_previous(finder.prev, candidate),
        steps + 1,
        length,
        distance
    }
    continue chain_previous(finder.prev, candidate), steps + 1, best, distance
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
test "match search cutoff includes distance 32768 and excludes stale history" {
  let input = Bytes::from_array(FixedArray::make(WINDOW_SIZE + 260, b'a'))
  let window = FixedArray::make(STREAM_RING_STORAGE_SIZE, b'a')
  for position in [WINDOW_SIZE - 1, WINDOW_SIZE, WINDOW_SIZE + 1] {
    let finder = MatchFinder()
    insert_pos(input, finder, 0, input.length())
    for budget in [0, 1, 2] {
      let cfg = {
        good_length: 4,
        max_lazy: 0,
        nice_length: 258,
        max_chain: budget,
      }
      let expected = if position <= WINDOW_SIZE && budget > 0 {
        (8 << 16) | position
      } else {
        2 << 16
      }
      @test.assert_eq(
        find_match(input, finder, position, position + 8, 2, cfg),
        expected,
      )
      @test.assert_eq(
        find_window_match(window, finder, position, position + 8, 2, cfg),
        expected,
      )
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
          @test.assert_eq(direct.short_head, scalar.short_head)
          @test.assert_eq(direct.head, scalar.head)
          @test.assert_eq(direct.prev, scalar.prev)
          @test.assert_eq(streaming.short_head, scalar.short_head)
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
          @test.assert_eq(
            chain_previous(direct.prev, position) < position,
            true,
          )
          @test.assert_eq(
            chain_previous(streaming.prev, position) < position,
            true,
          )
        }
        @test.assert_eq(direct.short_head, streaming.short_head)
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

///|
test "dual hash separates long matches from a nearer three-byte prefix" {
  let data = b"abcX0123456789---abcY9876543210---abcX0123456789"
  let target = 34
  let finder = MatchFinder()
  insert_pos(data, finder, 0, data.length())
  insert_pos(data, finder, 17, data.length())
  let packed = find_match(
    data,
    finder,
    target,
    data.length(),
    0,
    level_configs[6],
  )
  @test.assert_eq(packed >> 16, 14)
  @test.assert_eq(packed & 0xFFFF, 34)
  // At a three-byte tail the short table must still work without a wide read.
  let short = find_match(data, finder, target, target + 3, 0, level_configs[6])
  @test.assert_eq(short >> 16, 3)
  @test.assert_eq(short & 0xFFFF, 17)
}

///|
test "streaming dual hash backfills a fourth byte exactly once" {
  let d = Deflater(dictionary=b"abc")
  @test.assert_eq(d.hashed_through, 0)
  @test.assert_eq(d.finder.short_head[short_hash3(b"abc", 0)], 0)
  d.push_pending_byte(b'd')
  d.chain_ready_history()
  @test.assert_eq(d.hashed_through, 1)
  let bucket = long_hash_product(read_match_word(b"abcd", 0) * 0x1E35A7BDU)
  @test.assert_eq(d.finder.head[bucket], 0)
  @test.assert_eq(chain_previous(d.finder.prev, 0), -1)
  d.chain_ready_history()
  @test.assert_eq(chain_previous(d.finder.prev, 0), -1)
  for byte in b"efabcd" {
    d.push_pending_byte(byte)
  }
  let packed = find_window_match(
    d.pending,
    d.finder,
    6,
    10,
    0,
    level_configs[6],
  )
  @test.assert_eq(packed >> 16, 4)
  @test.assert_eq(packed & 0xFFFF, 6)
  d.reset()
  @test.assert_eq(d.finder.head[bucket] < d.finder.position_base, true)
  @test.assert_eq(
    d.finder.short_head[short_hash3(b"abc", 0)] < d.finder.position_base,
    true,
  )
}

///|
test "match table sizing preserves compact small-input workspaces" {
  for (size, capacity) in [(4096, 16384), (8192, 32768)] {
    let input = Bytes::makei(size, i => (i & 255).to_byte())
    let fresh = MatchFinder(input_size=size)
    let reused = MatchFinder(input_size=0)
    reused.reset_for_input(input)
    @test.assert_eq(fresh.head.length(), capacity)
    @test.assert_eq(reused.head.length(), capacity)
    @test.assert_eq(reused.long_shift, fresh.long_shift)
  }
}

///|
test "match table sizing realizes each selected adaptive width" {
  for (alphabet, expected_bits) in [(16, 16), (80, 17), (256, 18)] {
    let input = Bytes::makei(65536, i => (i % alphabet).to_byte())
    let bits = long_hash_bits_for_input(input)
    @test.assert_eq(bits, expected_bits)
    let fresh = MatchFinder(input_size=input.length(), long_hash_bits=bits)
    let reused = MatchFinder(input_size=0)
    reused.reset_for_input(input)
    @test.assert_eq(fresh.head.length(), 1 << bits)
    @test.assert_eq(reused.head.length(), 1 << bits)
    @test.assert_eq(fresh.long_shift, 32 - bits)
    @test.assert_eq(reused.long_shift, fresh.long_shift)
  }
}

///|
test "stamped heads isolate successive inputs without clearing tables" {
  let finder = MatchFinder()
  let sources = [
    b"",
    b"a",
    b"ab",
    b"abc",
    b"abcabcXabcabcYabcabcZ",
    Bytes::makei(1027, i => ((i * 37 + i / 11) & 255).to_byte()),
    b"abc",
    b"",
    b"xyzxyzxyzxyzxyz",
  ]
  for _ in 0..<3 {
    for input in sources {
      finder.reset_for_input(input)
      for position in 0..<(input.length() - 2).max(0) {
        for base in [0, 2, 3, 8] {
          @test.assert_eq(
            find_match(
              input,
              finder,
              position,
              input.length(),
              base,
              level_configs[6],
            ),
            scalar_find_match_reference(
              input,
              finder,
              position,
              input.length(),
              base,
              level_configs[6],
            ),
          )
        }
        insert_pos(input, finder, position, input.length())
      }
    }
  }
}

///|
test "stamped heads reset before the position base can overflow" {
  let finder = MatchFinder()
  let input = b"abcabcXabcabcYabcabcZabcabcXabcabcY"
  finder.next_base = 2147483647 - input.length()
  finder.reset_for_input(input)
  @test.assert_eq(finder.next_base, 2147483647)
  for position in 0..<(input.length() - 2) {
    @test.assert_eq(
      find_match(input, finder, position, input.length(), 0, level_configs[6]),
      scalar_find_match_reference(
        input,
        finder,
        position,
        input.length(),
        0,
        level_configs[6],
      ),
    )
    insert_pos(input, finder, position, input.length())
  }
  finder.reset_for_input(b"")
  @test.assert_eq(finder.position_base, 2147483647)
  finder.reset_for_input(input)
  @test.assert_eq(finder.position_base, 0)
  @test.assert_eq(finder.next_base, input.length())
  @test.assert_eq(
    find_match(input, finder, 3, input.length(), 0, level_configs[6]),
    0,
  )
}

///|
test "reused compressors preserve output across failed and empty generations" {
  let codec = Compressor()
  codec.finder.next_base = 2147483600
  for size in [0, 1, 2, 3, 4, 1023, 1024, 1025, 40000, 4, 0, 63] {
    let input = Bytes::makei(size, i => ((i * 19 + i / 7) & 255).to_byte())
    @test.assert_eq(
      codec.compress_into(input, FixedArray::make(0, b'\x00')),
      None,
    )
    let compressed = codec.compress(input)
    @test.assert_eq(compressed, deflate_all(input))
    @test.assert_eq(inflate_all(compressed), input)
  }
}

///|
test "all fourth bytes retain the same short-match bucket" {
  let data = Bytes::makei(1027, i => {
    if i >= 1024 {
      b"abc"[i - 1024]
    } else {
      match i % 4 {
        0 => b'a'
        1 => b'b'
        2 => b'c'
        _ => (i / 4).to_byte()
      }
    }
  })
  let finder = MatchFinder()
  finder.reset_for_input(data)
  for position = 0; position < 1024; position = position + 4 {
    insert_pos(data, finder, position, data.length())
  }
  @test.assert_eq(
    find_match(data, finder, 1024, 1027, 0, level_configs[6]),
    (3 << 16) | 4,
  )
}

///|
test "stream bases retain rebase headroom and discard prior dictionaries" {
  let d = Deflater(dictionary=b"abcabcabcabcabcabc")
  d.finder.position_base = (1 << 29) - 8
  d.reset()
  @test.assert_eq(d.finder.position_base, 0)
  @test.assert_eq(
    find_window_match(d.pending, d.finder, 3, 7, 0, level_configs[6]),
    0,
  )
  d.reset(dictionary=b"abcabcabc")
  let first_base = d.finder.position_base
  d.reset(dictionary=b"xyzxyzxyz")
  @test.assert_eq(d.finder.position_base, first_base + 9)
  // Old abc heads must be rejected even though their physical slots survive.
  @test.assert_eq(
    d.finder.short_head[short_hash3(b"abc", 0)] < d.finder.position_base,
    true,
  )
}

///|
test "stream rebasing preserves nonzero stamped heads and relative links" {
  let d = Deflater()
  let base = 1 << 28
  let position = (1 << 30) + 17
  let offset = (position / STREAM_RING_SIZE - 1) * STREAM_RING_SIZE
  d.finder.position_base = base
  d.parse_pos = position
  d.pending_end = position + 100
  d.hashed_through = position
  d.finder.head[0] = base + position - 3
  d.finder.short_head[0] = base + position - 3
  set_chain_previous(d.finder.prev, position - 3, position - 9)
  d.maybe_rebase()
  @test.assert_eq(d.finder.head[0] - base, position - 3 - offset)
  @test.assert_eq(d.finder.short_head[0] - base, position - 3 - offset)
  @test.assert_eq(
    chain_previous(d.finder.prev, position - 3 - offset),
    position - 9 - offset,
  )
  d.reset()
  @test.assert_eq(d.finder.position_base, base + position + 100 - offset)
  @test.assert_eq(d.finder.head[0] < d.finder.position_base, true)
}

///|
test "short hash collision must not hide an older four-byte match" {
  // The intervening three-byte prefix hashes to the same short bucket as
  // abc, but its bytes differ. Only an expired head can rule out a match.
  let data = b"abcd1234\x04\x12\x00Z----abcd1234"
  let window = FixedArray::make(STREAM_RING_STORAGE_SIZE, b'\x00')
  for i in 0..<data.length() {
    window[i] = data[i]
    window[i + STREAM_RING_SIZE] = data[i]
  }
  for input_size in [0, 4096, WINDOW_SIZE] {
    let finder = MatchFinder(input_size~)
    @test.assert_eq(
      short_hash3(data, 0, shift=finder.short_shift),
      short_hash3(data, 8, shift=finder.short_shift),
    )
    insert_pos(data, finder, 0, data.length())
    insert_pos(data, finder, 8, data.length())
    @test.assert_eq(
      find_match(data, finder, 16, data.length(), 0, level_configs[6]),
      (8 << 16) | 16,
    )
    @test.assert_eq(
      find_window_match(window, finder, 16, data.length(), 0, level_configs[6]),
      (8 << 16) | 16,
    )
  }
}

///|
test "compact predecessor distances preserve window endpoints and expire older links" {
  let finder = MatchFinder()
  for position in [0, 32767, 32768, 65535, 65536, (1 << 30) + 17] {
    for distance in [1, 2, 257, WINDOW_SIZE, WINDOW_SIZE + 1, 200000] {
      set_chain_previous(finder.prev, position, position - distance)
      let previous = chain_previous(finder.prev, position)
      if distance <= WINDOW_SIZE {
        @test.assert_eq(previous, position - distance)
      } else {
        @test.assert_eq(previous < position - WINDOW_SIZE, true)
      }
    }
  }
}

///|
test "default parser resamples narrow alphabets after compressor reuse" {
  let codec = Compressor(level=6, fast_store=false)
  let rng = MatchLenDifferentialRng(0x715832ABU)
  for alphabet in [256, 8, 256, 8] {
    let data = Bytes::makei(2048, _ => rng.below(alphabet).to_byte())
    let compressed = codec.compress(data)
    @test.assert_eq(compressed, deflate_all(data, level=6, fast_store=false))
    @test.assert_eq(inflate_all(compressed), data)
  }
}
