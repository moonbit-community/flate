///|
/// Successful completion must retain only the cached transport suffix, not the
/// consumed zlib stream or the immutable inflater snapshot.
test "zlib completion releases consumed input and caches read-ahead" {
  let stream = zlib_compress(b"release the completed zlib stream")
  let suffix = b"NEXT-FRAME"
  let combined : Array[Byte] = []
  for byte in stream {
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
  assert_eq(consumed, stream.length() + suffix.length())
  assert_eq(decoder.pending.length(), 0)
  assert_eq(decoder.pending_pos, 0)
  assert_eq(decoder.body_input, b"")
  assert_eq(decoder.body_pos, 0)
  assert_eq(decoder.unused, suffix)
  assert_eq(decoder.unused_input(), suffix)
  assert_eq(decoder.unused_input(), suffix)
}

///|
/// The failure latch is checked before buffering input or advancing either the
/// wrapper cursor or the immutable body snapshot cursor.
test "zlib failed state freezes decoder cursors" {
  let malformed : Bytes = [0x78, 0x01, 0x07, 0x00, 0x00, 0x00, 0x01]
  let decoder = Decoder::new()
  let output = FixedArray::make(1, b'\x00')
  let mut first_kind : ZlibErrorKind = InvalidHeader
  let mut first_error = ""
  try ignore(decoder.step(malformed[:], output.mut_view(), end=true)) catch {
    ZlibError(kind, message) => {
      first_kind = kind
      first_error = message
    }
  } noraise {
    _ => fail("expected malformed zlib input to fail")
  }
  let pending_pos = decoder.pending_pos
  let pending_length = decoder.pending.length()
  let body_pos = decoder.body_pos
  let body_input = decoder.body_input
  let mut repeated_kind : ZlibErrorKind = InvalidHeader
  let mut repeated_error = ""
  try
    ignore(decoder.step(b"must not be accepted"[:], output.mut_view()))
  catch {
    ZlibError(kind, message) => {
      repeated_kind = kind
      repeated_error = message
    }
  } noraise {
    _ => fail("a failed zlib decoder resumed")
  }
  assert_true(first_kind == InvalidDeflate)
  assert_true(repeated_kind == first_kind)
  assert_eq(repeated_error, first_error)
  assert_eq(decoder.pending_pos, pending_pos)
  assert_eq(decoder.pending.length(), pending_length)
  assert_eq(decoder.body_pos, body_pos)
  assert_eq(decoder.body_input, body_input)
}
