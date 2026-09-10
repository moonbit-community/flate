///|
test "fresh reusable decoder rejects missing input before its first reset" {
  let decoder = Decompressor()
  let err = @test.expect_error(() => decoder.decoder.run())
  guard err is InflateError(kind, _)
  @test.assert_eq(kind, Truncated)
  @test.assert_eq(decoder.decoder.out.length, 0)
}

///|
test "decoded output sizes reject overflow before allocation or mutation" {
  let maximum = MAX_DECODE_OUTPUT_SIZE
  for entry in [(0, 0), (0, maximum), (maximum, 0), (maximum - 1, 1)] {
    let (length, additional) = entry
    @test.assert_eq(
      checked_decode_output_length(length, additional),
      length + additional,
    )
  }
  for entry in [(maximum, 1), (1, maximum), (maximum - 1, 2)] {
    let (length, additional) = entry
    let err = @test.expect_error(() => {
      checked_decode_output_length(length, additional)
    })
    guard err is InflateError(kind, _)
    @test.assert_eq(kind, OutputLimitExceeded)
  }
  for out in [DecodeOutput(1), DecodeOutput::into([b'\x00'])] {
    out.append_byte(b'a')
    let err = @test.expect_error(() => out.ensure_capacity(maximum))
    guard err is InflateError(kind, _)
    @test.assert_eq(kind, OutputLimitExceeded)
    @test.assert_eq(out.length, 1)
    @test.assert_eq(out.storage.length(), 1)
    @test.assert_eq(out.to_bytes(), b"a")
  }
}

///|
test "decoded output growth stays representable at the doubling boundary" {
  @test.assert_eq(grown_decode_output_capacity(4, 5), 8)
  @test.assert_eq(grown_decode_output_capacity(4, 9), 9)
  let half = MAX_DECODE_OUTPUT_SIZE / 2
  @test.assert_eq(
    grown_decode_output_capacity(half, half + 1),
    MAX_DECODE_OUTPUT_SIZE - 1,
  )
  @test.assert_eq(
    grown_decode_output_capacity(half, MAX_DECODE_OUTPUT_SIZE),
    MAX_DECODE_OUTPUT_SIZE,
  )
  @test.assert_eq(grown_decode_output_capacity(half + 1, half + 2), half + 2)
  @test.assert_eq(
    grown_decode_output_capacity(
      MAX_DECODE_OUTPUT_SIZE - 1,
      MAX_DECODE_OUTPUT_SIZE,
    ),
    MAX_DECODE_OUTPUT_SIZE,
  )
}

///|
test "rebasing preserves live match distances and pending ring bytes" {
  let d = Deflater()
  let position = (1 << 30) + 17
  let offset = (position / STREAM_RING_SIZE - 1) * STREAM_RING_SIZE
  d.parse_pos = position
  d.pending_end = position
  d.hashed_through = position - 2
  d.finder.head[0] = position - 3
  d.finder.prev[(position - 3) & WINDOW_MASK] = position - 9
  d.finder.head[1] = 0 // stale history becomes a negative sentinel
  d.finder.prev[0] = 0
  d.push_pending_byte(b'a')
  d.push_pending_byte(b'b')
  d.push_pending_byte(b'c')
  d.maybe_rebase()
  @test.assert_eq(d.parse_pos, position - offset)
  @test.assert_eq(d.pending_bytes(), 3)
  @test.assert_eq(d.hashed_through, position - 2 - offset)
  @test.assert_eq(d.finder.head[0], d.parse_pos - 3)
  @test.assert_eq(d.finder.prev[(position - 3) & WINDOW_MASK], d.parse_pos - 9)
  @test.assert_eq(d.finder.head[1], -offset)
  @test.assert_eq(d.finder.prev[0], -offset)
  @test.assert_eq(d.finder.head[2], -1)
  @test.assert_eq(d.finder.prev[1], -1)
  d.maybe_rebase()
  @test.assert_eq(d.parse_pos, position - offset)
  d.record_chained_positions(d.parse_pos - 3)
  @test.assert_eq(d.hashed_through, d.parse_pos - 2)
  d.write_stored_pending(is_final=true)
  @test.assert_eq(inflate_all(Bytes::from_array(d.w.out)), b"abc")
}

///|
test "stored ring blocks split at LEN limit and preserve wrapped bytes" {
  let ring = FixedArray::make(STREAM_RING_STORAGE_SIZE, b'\x00')
  for i in 0..<STREAM_RING_SIZE {
    let byte = ((i * 73 + i / 17) & 255).to_byte()
    ring[i] = byte
    ring[i + STREAM_RING_SIZE] = byte
  }
  let start = STREAM_RING_SIZE - 7
  for length in [0, 65535, 65536] {
    let w = BitWriter()
    write_stored_window(w, ring, start, start + length, is_final=true)
    let expected = Bytes::makei(length, i => {
      ring[(start + i) & STREAM_RING_MASK]
    })
    @test.assert_eq(inflate_all(Bytes::from_array(w.out)), expected)
    @test.assert_eq(w.out.length(), length + 5 * stored_block_count(length))
  }
}

///|
test "candidate probes reject each unequal byte and exhausted limits" {
  for base in [0, 2, 3, 7] {
    for mismatch in [-1, 0, 1, 2, 6, 7] {
      let data = Bytes::makei(32, i => {
        if i == 16 + mismatch && mismatch >= 0 {
          b'b'
        } else {
          b'a'
        }
      })
      let rejected = if base < 3 {
        mismatch >= 0 && mismatch <= 2
      } else {
        mismatch == 0 ||
        mismatch == 1 ||
        mismatch == base - 1 ||
        mismatch == base
      }
      @test.assert_eq(match_candidate_can_beat(data, 0, 16, base, 8), !rejected)
      @test.assert_eq(match_candidate_can_beat(data, 0, 16, base, base), false)
    }
  }
}

///|
test "streaming lazy match commits lookahead beyond a one-byte token range" {
  let data = b"abcabcabc"
  let ring = FixedArray::make(STREAM_RING_STORAGE_SIZE, b'\x00')
  for i in 0..<data.length() {
    ring[i] = data[i]
    ring[i + STREAM_RING_SIZE] = data[i]
  }
  let finder = MatchFinder()
  for i in 0..<3 {
    insert_window_pos(ring, finder, i, data.length())
  }
  let tokens : Array[Int] = []
  let ll = FixedArray::make(286, 0)
  let dd = FixedArray::make(30, 0)
  let end = tokenize_window(
    ring,
    finder,
    3,
    4,
    data.length(),
    level_configs[6],
    tokens,
    ll,
    dd,
  )
  @test.assert_eq(end, 9)
  @test.assert_eq(tokens, [pack_match_token(6, 3)])
  @test.assert_eq(ll[257 + len_to_idx[6]], 1)
  @test.assert_eq(dd[dist_index(3)], 1)
}

///|
test "stored decoder drains prefetched bytes before staged and external input" {
  let d = Inflater()
  let output = FixedArray::make(3, b'\x00')
  d.mode = InStored
  d.final_block = true
  d.stored_remaining = 3
  d.wpos = WINDOW_SIZE - 1
  d.bitbuf = 97
  d.bit_count = 8
  d.staged_input = [b'b']
  d.view = b"c"[:]
  d.out = output.mut_view()
  d.out_end = 3
  @test.assert_eq(d.run_step(), Done)
  @test.assert_eq(Bytes::from_array(output), b"abc")
  @test.assert_eq(d.wpos, WINDOW_SIZE + 2)
  @test.assert_eq(d.filled, true)
  @test.assert_eq(d.window[WINDOW_SIZE - 1], b'a')
  @test.assert_eq(d.window[0], b'b')
  @test.assert_eq(d.window[1], b'c')
  @test.assert_eq(d.stored_remaining, 0)
  @test.assert_eq(d.next_stored_byte(), None)
  d.copy_remaining = 2
  d.copy_dist = 1
  d.drain_match() // no output room: retain the suspended match
  @test.assert_eq(d.copy_remaining, 2)
  @test.assert_eq(d.wpos, WINDOW_SIZE + 2)
}

///|
test "fast Huffman lookup handles linked symbols invalid codes and short input" {
  let h = HuffmanDecoder()
  @test.assert_eq(h.initialize([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 10]), true)
  for entry in [(b"\xFF\x01\x00", 9), (b"\xFF\x03\x00", 10)] {
    let (input, expected) = entry
    let d = MemDecoder(input, () => false)
    @test.assert_eq(d.huff_sym_data(h), expected)
    @test.assert_eq(d.bit_count, 14)
  }
  let truncated = MemDecoder(b"\xFF", () => false)
  let err = @test.expect_error(() => truncated.huff_sym_data(h))
  guard err is InflateError(kind, _)
  @test.assert_eq(kind, Truncated)
  let invalid = MemDecoder(b"\x00\x00\x00", () => false)
  let err = @test.expect_error(() => invalid.huff_sym_data(HuffmanDecoder()))
  guard err is InflateError(kind, _)
  @test.assert_eq(kind, Corrupt)
}

///|
test "empty output appends preserve storage and cancellation starts before copies" {
  let out = DecodeOutput::into(FixedArray::make(0, b'\x00'))
  out.append_bytes(b"", 0, 0)
  out.append_repeated_suffix(1, 0)
  @test.assert_eq(out.to_bytes(), b"")
  let d = MemDecoder(b"abc", () => false)
  d.copy_stored(3)
  @test.assert_eq(d.out.to_bytes(), b"abc")
  @test.assert_eq(d.pos, 3)
  d.next_cancel = d.out.length
  d.copy_match(3, 3)
  @test.assert_eq(d.out.to_bytes(), b"abcabc")
}
