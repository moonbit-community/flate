///|
/// Header-phase memory must be O(1): FNAME bytes are discarded as they
/// arrive, never banked in `pending`, so an adversarial unterminated FNAME
/// cannot grow decoder memory.
test "gzip header FNAME bytes are discarded, not retained" {
  let dec = Decoder::new()
  let obuf = FixedArray::make(1, b'\x00')
  // Fixed header with FLG = FNAME only.
  let hdr : Bytes = [0x1F, 0x8B, 0x08, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF]
  let (_st, _c, _p) = dec.step(hdr[:], obuf.mut_view())
  // 64 KB of name bytes with no terminator, fed in 1 KB chunks.
  let chunk = Bytes::make(1024, b'x')
  for _i in 0..<64 {
    let (_st2, _c2, _p2) = dec.step(chunk[:], obuf.mut_view())
    assert_eq(dec.pending.length(), 0)
  }
}

///|
/// Output-only resume calls advance a cursor into one cached immutable input
/// snapshot. They must not rebuild or shift the large compressed tail on every
/// byte of output.
test "gzip body backpressure reuses pending storage" {
  let input : Array[Byte] = []
  for i in 0..<10000 {
    input.push((i & 0xFF).to_byte())
  }
  let gz = gzip_compress(Bytes::from_array(input), level=0)
  let dec = Decoder::new()
  let obuf = FixedArray::make(1, b'\x00')
  let split = 9000
  assert_true(gz.length() > split + 1)
  let (_st, consumed, produced) = dec.step(gz[:split], obuf.mut_view())
  assert_eq(consumed, split)
  assert_eq(produced, 1)
  let backing_len = dec.pending.length()
  let first_pos = dec.pending_pos
  assert_true(backing_len > 8900)
  assert_eq(dec.pending_bytes.length(), dec.pending_snapshot_end)
  for _i in 0..<64 {
    let (_st2, c, p) = dec.step(b""[:], obuf.mut_view())
    assert_eq(c, 0)
    assert_eq(p, 1)
    assert_eq(dec.pending.length(), backing_len)
    assert_eq(dec.pending_bytes.length(), dec.pending_snapshot_end)
  }
  assert_true(dec.pending_pos > first_pos)
  // Accepting more network input while a large active snapshot is still
  // output-backpressured appends to the Array but does not copy/rebuild that
  // snapshot. It will be merged only after the inflater exhausts the prefix.
  let snapshot_end = dec.pending_snapshot_end
  let pending_len = dec.pending.length()
  let (_st3, c3, p3) = dec.step(gz[split:split + 1], obuf.mut_view())
  assert_eq(c3, 1)
  assert_eq(p3, 1)
  assert_eq(dec.pending.length(), pending_len + 1)
  assert_eq(dec.pending_snapshot_end, snapshot_end)
}

///|
/// Successful completion must retain only the cached transport suffix, not the
/// consumed member or the immutable inflater snapshot it was decoded from.
test "gzip completion releases consumed input and caches read-ahead" {
  let gzip_stream = gzip_compress(b"release the completed member")
  let suffix = b"NEXT-FRAME"
  let combined : Array[Byte] = []
  for byte in gzip_stream {
    combined.push(byte)
  }
  for byte in suffix {
    combined.push(byte)
  }
  let decoder = Decoder::new()
  let output = FixedArray::make(128, b'\x00')
  let (status, consumed, _) = decoder.step(
    Bytes::from_array(combined)[:],
    output.mut_view(),
  )
  assert_true(status is Done)
  assert_eq(consumed, gzip_stream.length() + suffix.length())
  assert_eq(decoder.pending.length(), 0)
  assert_eq(decoder.pending_pos, 0)
  assert_eq(decoder.pending_bytes, b"")
  assert_eq(decoder.pending_snapshot_end, 0)
  assert_eq(decoder.unused, suffix)
  assert_eq(decoder.unused_input(), suffix)
  assert_eq(decoder.unused_input(), suffix)
}

///|
/// The public failure latch runs before buffering new input or touching the
/// inflater again.
test "gzip failed state freezes decoder cursors" {
  let malformed : Bytes = [
    0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x07, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  ]
  let decoder = Decoder::new()
  let output = FixedArray::make(1, b'\x00')
  let mut first_kind : GzipErrorKind = InvalidHeader
  let mut first_error = ""
  try ignore(decoder.step(malformed[:], output.mut_view(), end=true)) catch {
    GzipError(kind, message) => {
      first_kind = kind
      first_error = message
    }
  } noraise {
    _ => fail("expected malformed gzip input to fail")
  }
  let pending_pos = decoder.pending_pos
  let pending_length = decoder.pending.length()
  let snapshot_end = decoder.pending_snapshot_end
  let snapshot = decoder.pending_bytes
  let mut repeated_kind : GzipErrorKind = InvalidHeader
  let mut repeated_error = ""
  try
    ignore(decoder.step(b"must not be accepted"[:], output.mut_view()))
  catch {
    GzipError(kind, message) => {
      repeated_kind = kind
      repeated_error = message
    }
  } noraise {
    _ => fail("a failed gzip decoder resumed")
  }
  assert_true(first_kind == InvalidDeflate)
  assert_true(repeated_kind == first_kind)
  assert_eq(repeated_error, first_error)
  assert_eq(decoder.pending_pos, pending_pos)
  assert_eq(decoder.pending.length(), pending_length)
  assert_eq(decoder.pending_snapshot_end, snapshot_end)
  assert_eq(decoder.pending_bytes, snapshot)
}
