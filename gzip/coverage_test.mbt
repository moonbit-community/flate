///|
/// Concatenate owned byte strings for malformed-container fixtures.
fn cov_join(parts : Array[Bytes]) -> Bytes {
  let out = Buffer()
  for part in parts {
    for byte in part {
      out.write_byte(byte)
    }
  }
  out.to_bytes()
}

///|
fn cov_prefix(input : Bytes, length : Int) -> Bytes {
  let out = Buffer()
  for i in 0..<length {
    out.write_byte(input[i])
  }
  out.to_bytes()
}

///|
fn cov_suffix(input : Bytes, start : Int) -> Bytes {
  let out = Buffer()
  for i in start..<input.length() {
    out.write_byte(input[i])
  }
  out.to_bytes()
}

///|
/// Build a fixed gzip header followed by arbitrary bytes.
fn cov_header(compression_method : Int, flags : Int, rest : Bytes) -> Bytes {
  let out = Buffer()
  for
    value in [
      0x1F, 0x8B, compression_method, flags, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF,
    ] {
    out.write_byte(value.to_byte())
  }
  for byte in rest {
    out.write_byte(byte)
  }
  out.to_bytes()
}

///|
/// Replace the canonical ten-byte header while retaining a valid body/trailer.
fn cov_reheader(base : Bytes, flags : Int, fields : Bytes) -> Bytes {
  cov_header(8, flags, cov_join([fields, cov_suffix(base, 10)]))
}

///|
fn cov_xor_at(input : Bytes, index : Int) -> Bytes {
  let bytes : Array[Byte] = []
  for byte in input {
    bytes.push(byte)
  }
  bytes[index] = (bytes[index].to_int() ^ 1).to_byte()
  Bytes::from_array(bytes)
}

///|
fn cov_expect_gunzip_error(
  input : Bytes,
  expected_kind : @gzip.GzipErrorKind,
) -> Unit raise {
  try ignore(@gzip.gunzip(input)) catch {
    GzipError(kind, _) => assert_true(kind == expected_kind)
  } noraise {
    _ => fail("expected gunzip to reject malformed input")
  }
}

///|
fn cov_expect_decoder_error(
  input : Bytes,
  expected_kind : @gzip.GzipErrorKind,
) -> Unit raise {
  let decoder = @gzip.Decoder::new()
  let output = FixedArray::make(65536, b'\x00')
  try ignore(decoder.step(input[:], output.mut_view(), end=true)) catch {
    GzipError(kind, _) => assert_true(kind == expected_kind)
  } noraise {
    _ => fail("expected streaming gzip decoder to reject malformed input")
  }
}

///|
test "gzip coverage: one-shot fixed header failures" {
  cov_expect_gunzip_error(b"", Truncated)
  cov_expect_gunzip_error(Bytes::make(18, b'\x00'), InvalidHeader)
  cov_expect_gunzip_error(
    cov_join([b"\x1F", Bytes::make(17, b'\x00')]),
    InvalidHeader,
  )
  cov_expect_gunzip_error(
    cov_header(0, 0, Bytes::make(8, b'\x00')),
    InvalidHeader,
  )
}

///|
test "gzip coverage: streaming fixed header failures" {
  cov_expect_decoder_error(b"\x1F", Truncated)
  cov_expect_decoder_error(Bytes::make(10, b'\x00'), InvalidHeader)
  cov_expect_decoder_error(
    cov_join([b"\x1F", Bytes::make(9, b'\x00')]),
    InvalidHeader,
  )
  cov_expect_decoder_error(cov_header(0, 0, b""), InvalidHeader)
}

///|
test "gzip coverage: one-shot optional fields truncate" {
  cov_expect_gunzip_error(
    cov_header(8, 4, b"\xFF\xFF\x01\x02\x03\x04\x05\x06"),
    Truncated,
  )
  cov_expect_gunzip_error(cov_header(8, 8, b"NONUL123"), Truncated)
  cov_expect_gunzip_error(cov_header(8, 16, b"COMMENT!"), Truncated)
  cov_expect_gunzip_error(cov_header(8, 2, Bytes::make(8, b'\xAA')), Truncated)
}

///|
test "gzip coverage: streaming optional fields truncate" {
  cov_expect_decoder_error(cov_header(8, 4, b""), Truncated)
  cov_expect_decoder_error(cov_header(8, 4, b"\x04\x00\xAA"), Truncated)
  cov_expect_decoder_error(cov_header(8, 8, b"name-without-nul"), Truncated)
  cov_expect_decoder_error(cov_header(8, 16, b"comment-without-nul"), Truncated)
  cov_expect_decoder_error(cov_header(8, 2, b"\xAA"), Truncated)
}

///|
test "gzip coverage: streaming FEXTRA has buffered remainder" {
  let payload = b"extra field branch"
  let base = @gzip.gzip_compress(payload)
  let framed = cov_reheader(base, 4, b"\x01\x00\xAA")
  let decoder = @gzip.Decoder::new()
  let output = FixedArray::make(256, b'\x00')
  let (status, consumed, produced) = decoder.step(
    framed[:],
    output.mut_view(),
    end=true,
  )
  assert_true(status is Done)
  assert_eq(consumed, framed.length())
  assert_eq(Bytes::from_array(output[0:produced].to_owned()), payload)
}

///|
test "gzip coverage: truncated raw body and trailer" {
  let empty_member = @gzip.gzip_compress(b"")
  // The empty raw stream completes, but only six trailer bytes remain.
  cov_expect_gunzip_error(
    cov_prefix(empty_member, empty_member.length() - 2),
    Truncated,
  )
  // A level-zero stored body needs far more than the eight visible bytes.
  let stored = @gzip.gzip_compress(Bytes::make(100, b'A'), level=0)
  cov_expect_gunzip_error(cov_prefix(stored, 18), Truncated)
}

///|
test "gzip coverage: checksum failures" {
  let valid = @gzip.gzip_compress(b"checksum coverage")
  let bad_crc = cov_xor_at(valid, valid.length() - 8)
  let bad_size = cov_xor_at(valid, valid.length() - 4)
  cov_expect_gunzip_error(bad_crc, ChecksumMismatch)
  cov_expect_gunzip_error(bad_size, LengthMismatch)
  cov_expect_decoder_error(bad_crc, ChecksumMismatch)
  cov_expect_decoder_error(bad_size, LengthMismatch)
}

///|
test "gzip coverage: subsequent member boundaries" {
  let payload = b"first member"
  let first_member = @gzip.gzip_compress(payload)
  cov_expect_gunzip_error(cov_join([first_member, b"\x1F"]), Truncated)
  cov_expect_decoder_error(cov_join([first_member, b"\x1F"]), Truncated)

  let plain_tail = b"NEXT"
  assert_eq(@gzip.gunzip(cov_join([first_member, plain_tail])), payload)
  let partial_magic = b"\x1F\x00NEXT"
  assert_eq(@gzip.gunzip(cov_join([first_member, partial_magic])), payload)

  let decoder = @gzip.Decoder::new()
  let output = FixedArray::make(256, b'\x00')
  let combined = cov_join([first_member, partial_magic])
  let (status, consumed, produced) = decoder.step(
    combined[:],
    output.mut_view(),
    end=true,
  )
  assert_true(status is Done)
  assert_eq(consumed, combined.length())
  assert_eq(Bytes::from_array(output[0:produced].to_owned()), payload)
  assert_eq(decoder.unused_input(), partial_magic)
}

///|
test "gzip coverage: end after a clean member boundary" {
  let payload = b"clean member boundary"
  let first_member = @gzip.gzip_compress(payload)
  let decoder = @gzip.Decoder::new()
  let output = FixedArray::make(256, b'\x00')
  let (first_status, first_consumed, first_produced) = decoder.step(
    first_member[:],
    output.mut_view(),
  )
  assert_true(first_status is NeedMoreInput)
  assert_eq(first_consumed, first_member.length())
  assert_eq(Bytes::from_array(output[0:first_produced].to_owned()), payload)
  let (status, consumed, produced) = decoder.step(
    b""[:],
    output.mut_view(),
    end=true,
  )
  assert_true(status is Done)
  assert_eq(consumed, 0)
  assert_eq(produced, 0)
}
