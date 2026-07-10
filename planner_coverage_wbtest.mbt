///|
fn fill_deflater_pending_for_coverage(d : Deflater, size : Int) -> Bytes {
  let bytes : Array[Byte] = []
  for i in 0..<size {
    let byte = ((i * 73 + i / 17) & 0xFF).to_byte()
    bytes.push(byte)
    d.pending.push(byte)
  }
  Bytes::from_array(bytes)
}

///|
test "compression levels clamp at both public boundaries" {
  let source = b"level clamping must be deterministic deterministic"
  assert_eq(deflate_all(source, level=-7), deflate_all(source, level=0))
  assert_eq(deflate_all(source, level=99), deflate_all(source, level=9))
  let low = Deflater::new(level=-7)
  let high = Deflater::new(level=99)
  assert_eq(low.level, 0)
  assert_eq(high.level, 9)
  assert_eq(
    inflate_all(deflate_all_optimal(b"iteration clamp", iterations=0)),
    b"iteration clamp",
  )
}

///|
test "block planner direct boundary paths emit valid work" {
  // Exercise emit_capped's defensive short-buffer branch directly. Normal
  // streaming callers enter it only after accumulating a full block.
  let short = Deflater::new()
  ignore(fill_deflater_pending_for_coverage(short, 257))
  short.emit_capped()
  assert_true(short.w.out.length() > 0)

  // Finalization with more than one token block must emit a capped non-final
  // block before the final remainder.
  let finishing = Deflater::new()
  let final_source = fill_deflater_pending_for_coverage(
    finishing,
    deflate_block_size + min_lookahead + 257,
  )
  finishing.emit_final()
  assert_true(finishing.emitted_final)
  assert_eq(inflate_all(Bytes::from_array(finishing.w.out)), final_source)

  // Both level-0 and parsed sync-flush paths have their own non-final block
  // loops before the empty stored marker.
  let stored = Deflater::new(level=0)
  ignore(fill_deflater_pending_for_coverage(stored, 31))
  stored.emit_flush()
  assert_eq(stored.pending.length(), 0)
  assert_true(stored.w.out.length() >= 4)

  let parsed = Deflater::new()
  ignore(
    fill_deflater_pending_for_coverage(
      parsed,
      deflate_block_size + min_lookahead + 257,
    ),
  )
  parsed.emit_flush()
  assert_true(parsed.pending.length() >= parsed.window_carry)
  assert_true(parsed.w.out.length() >= 4)

  // Validate the final stored-block bit directly. This is kept explicit
  // because the coverage compiler currently fails to credit the constant-one
  // arm inside write_stored's inline conditional.
  let final_stored = BitWriter::new()
  write_stored(final_stored, b"", 0, 0, is_final=true)
  assert_eq(final_stored.out[0] & b'\x01', b'\x01')

  // Force write_stored to split at the 16-bit LEN limit as well.
  let split_source = Bytes::from_array(Array::make(65536, b'\x5A'))
  let split_stored = BitWriter::new()
  write_stored(
    split_stored,
    split_source,
    0,
    split_source.length(),
    is_final=true,
  )
  assert_eq(inflate_all(Bytes::from_array(split_stored.out)), split_source)
}

///|
test "lazy match pending at a block boundary is committed" {
  // The token range is one byte wide, but lookahead extends beyond it. A
  // history match beginning at index 3 is deferred by lazy parsing; reaching
  // `end=4` commits that pending match in tokenize's boundary epilogue.
  let data = b"abcabcabc"
  let (tokens, ll_freq, d_freq, processed) = tokenize(
    data,
    3,
    4,
    level_configs[6],
  )
  assert_eq(tokens.length(), 1)
  match tokens[0] {
    Match(length, distance) => {
      assert_true(length >= 3)
      assert_eq(distance, 3)
      assert_true(ll_freq[257 + len_to_idx[length]] > 0)
      assert_true(d_freq[dist_index(distance)] > 0)
    }
    Lit(_) => fail("expected the deferred boundary match")
  }
  assert_true(processed > 4)
  assert_eq(collect_matches(b"", 0, 0).length(), 0)
}

///|
test "stored-byte helper drains a prefetched accumulator byte" {
  // Public state transitions currently leave bit_count at zero on entry to a
  // stored payload, but the helper deliberately supports a prefetched byte.
  let inflater = Inflater::new()
  inflater.bitbuf = 0xBBAA
  inflater.bit_count = 16
  assert_true(inflater.next_stored_byte() is Some(b'\xAA'))
  assert_eq(inflater.bitbuf, 0xBB)
  assert_eq(inflater.bit_count, 8)
}

///|
test "optimal planner crosses its master-block boundary" {
  // Repetition keeps the optimal parse small while forcing the outer planner
  // to choose its capped master target at least once.
  let source = Bytes::from_array(
    Array::make(optimal_master_block + min_lookahead + 1, b'\x41'),
  )
  let compressed = deflate_all_optimal(source, iterations=1)
  assert_eq(inflate_all(compressed), source)
}

///|
fn second_split_is_cheaper_for_coverage(input : Bytes) -> Bool {
  let (greedy, _, _, chunk_end) = tokenize(
    input,
    0,
    input.length(),
    level_configs[9],
  )
  let greedy_pos = Array::make(greedy.length() + 1, 0)
  let mut byte_pos = 0
  for i in 0..<greedy.length() {
    greedy_pos[i] = byte_pos
    byte_pos = byte_pos +
      (match greedy[i] {
        Lit(_) => 1
        Match(length, _) => length
      })
  }
  greedy_pos[greedy.length()] = chunk_end
  let first_bounds = plan_split_points(greedy, greedy_pos)
  let optimal : Array[Token] = []
  let first_joins : Array[Int] = [0]
  for i in 0..<(first_bounds.length() - 1) {
    let (tokens, _, _) = tokenize_optimal(
      input,
      greedy_pos[first_bounds[i]],
      greedy_pos[first_bounds[i + 1]],
      2,
    )
    for token in tokens {
      optimal.push(token)
    }
    first_joins.push(optimal.length())
  }
  let optimal_pos = Array::make(optimal.length() + 1, 0)
  byte_pos = 0
  for i in 0..<optimal.length() {
    optimal_pos[i] = byte_pos
    byte_pos = byte_pos +
      (match optimal[i] {
        Lit(_) => 1
        Match(length, _) => length
      })
  }
  optimal_pos[optimal.length()] = chunk_end
  let second_bounds = plan_split_points(optimal, optimal_pos)
  grouping_cost(optimal, optimal_pos, second_bounds) <
  grouping_cost(optimal, optimal_pos, first_joins)
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
test "optimal planner may prefer its second splitting pass" {
  let source = make_second_split_candidate_for_coverage(7)
  assert_true(second_split_is_cheaper_for_coverage(source))
  let compressed = deflate_all_optimal(source, iterations=2)
  assert_eq(inflate_all(compressed), source)
}
