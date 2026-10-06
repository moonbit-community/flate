///|
/// Header-phase memory must be O(1): FNAME bytes are discarded as they
/// arrive, never banked in `pending`, so an adversarial unterminated FNAME
/// cannot grow decoder memory.
test "gzip header FNAME bytes are discarded, not retained" {
  let dec = Decoder()
  let obuf = FixedArray::make(1, b'\x00')
  // Fixed header with FLG = FNAME only.
  let hdr : Bytes = [0x1F, 0x8B, 0x08, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF]
  let _st = dec.step(hdr, obuf.mut_view())
  let _c = dec.last_consumed()
  let _p = dec.last_produced()
  // 64 KB of name bytes with no terminator, fed in 1 KB chunks.
  let chunk = Bytes::make(1024, b'x')
  for _i in 0..<64 {
    let _st2 = dec.step(chunk, obuf.mut_view())
    let _c2 = dec.last_consumed()
    let _p2 = dec.last_produced()
    @test.assert_eq(dec.pending.length(), 0)
  }
}

///|
/// Output-only resume calls advance a cursor into the retained input.
/// They must not rebuild or shift the large compressed tail on every
/// byte of output.
test "gzip body backpressure reuses pending storage" {
  let input : Array[Byte] = []
  for i in 0..<10000 {
    input.push((i & 0xFF).to_byte())
  }
  let gz = compress(Bytes::from_array(input), level=0)
  let dec = Decoder()
  let obuf = FixedArray::make(1, b'\x00')
  let split = 9000
  assert_true(gz.length() > split + 1)
  let _st = dec.step(gz[:split], obuf.mut_view())
  let consumed = dec.last_consumed()
  let produced = dec.last_produced()
  @test.assert_eq(consumed, split)
  @test.assert_eq(produced, 1)
  let backing_len = dec.pending.length()
  let first_pos = dec.pending_pos
  assert_true(backing_len > 8900)
  assert_true(backing_len <= DECODER_INPUT_LIMIT)
  assert_false(dec.borrowed_input)
  for _i in 0..<64 {
    let _st2 = dec.step(b"", obuf.mut_view())
    let c = dec.last_consumed()
    let p = dec.last_produced()
    @test.assert_eq(c, 0)
    @test.assert_eq(p, 1)
    @test.assert_eq(dec.pending.length(), backing_len)
    assert_false(dec.borrowed_input)
  }
  assert_true(dec.pending_pos > first_pos)
  // While accepted body input remains output-backpressured, a new transport
  // byte stays with the caller and the decoder keeps draining its current view.
  let pending_len = dec.pending.length()
  let _st3 = dec.step(gz[split:split + 1], obuf.mut_view())
  let c3 = dec.last_consumed()
  let p3 = dec.last_produced()
  @test.assert_eq(c3, 0)
  @test.assert_eq(p3, 1)
  @test.assert_eq(dec.pending.length(), pending_len)
  assert_false(dec.borrowed_input)
}

///|
/// Successful completion must retain only the cached transport suffix, not the
/// consumed member.
test "gzip completion releases consumed input and caches read-ahead" {
  let gzip_stream = compress(b"release the completed member")
  let suffix = b"NEXT-FRAME"
  let combined : Array[Byte] = []
  for byte in gzip_stream {
    combined.push(byte)
  }
  for byte in suffix {
    combined.push(byte)
  }
  let decoder = Decoder()
  let output = FixedArray::make(128, b'\x00')
  let status = decoder.step(Bytes::from_array(combined), output.mut_view())
  let consumed = decoder.last_consumed()
  let _produced = decoder.last_produced()
  assert_true(status is Done)
  @test.assert_eq(consumed, gzip_stream.length() + suffix.length())
  @test.assert_eq(decoder.pending.length(), 0)
  @test.assert_eq(decoder.pending_pos, 0)
  assert_false(decoder.borrowed_input)
  @test.assert_eq(decoder.unused, suffix)
  @test.assert_eq(decoder.unused_input(), suffix)
  @test.assert_eq(decoder.unused_input(), suffix)
}

///|
/// The public failure latch runs before buffering new input or touching the
/// inflater again.
test "gzip failed state freezes decoder cursors" {
  let malformed : Bytes = [
    0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x07, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  ]
  let decoder = Decoder()
  let output = FixedArray::make(1, b'\x00')
  let GzipError(first_kind, first_error) = @test.expect_error(() => {
    decoder.step(malformed, output.mut_view(), end=true)
  })
  @test.assert_eq(decoder.last_consumed(), 0)
  @test.assert_eq(decoder.last_produced(), 0)
  let pending_pos = decoder.pending_pos
  let pending_length = decoder.pending.length()
  let snapshot = decoder.pending.to_owned()
  assert_false(decoder.borrowed_input)
  let GzipError(repeated_kind, repeated_error) = @test.expect_error(() => {
    decoder.step(b"must not be accepted", output.mut_view())
  })
  @test.assert_eq(decoder.last_consumed(), 0)
  @test.assert_eq(decoder.last_produced(), 0)
  assert_true(first_kind == InvalidDeflate)
  assert_true(repeated_kind == first_kind)
  @test.assert_eq(repeated_error, first_error)
  @test.assert_eq(decoder.pending_pos, pending_pos)
  @test.assert_eq(decoder.pending.length(), pending_length)
  @test.assert_eq(decoder.pending.to_owned(), snapshot)
  assert_false(decoder.borrowed_input)
}
