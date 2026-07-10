///|
fn expect_one_shot_zlib_error(
  input : Bytes,
  expected_kind : @zlib.ZlibErrorKind,
  expected : String,
) -> Unit raise {
  try @zlib.zlib_decompress(input) catch {
    ZlibError(kind, message) => {
      assert_true(kind == expected_kind)
      assert_eq(message, expected)
    }
  } noraise {
    _ => fail("expected zlib_decompress to reject the input")
  }
}

///|
fn expect_streaming_zlib_error(
  input : Bytes,
  expected_kind : @zlib.ZlibErrorKind,
  expected : String,
) -> Unit raise {
  let decoder = @zlib.Decoder::new()
  let output = FixedArray::make(8, b'\x00')
  try decoder.step(input[:], output.mut_view()) catch {
    ZlibError(kind, message) => {
      assert_true(kind == expected_kind)
      assert_eq(message, expected)
    }
  } noraise {
    _ => fail("expected Decoder::step to reject the input")
  }
}

///|
test "coverage: one-shot zlib header errors" {
  expect_one_shot_zlib_error(
    b"\x78\x01\x03\x00\x00",
    Truncated,
    "zlib: input too short",
  )
  expect_one_shot_zlib_error(
    [0x79, 0x00, 0x00, 0x00, 0x00, 0x00],
    InvalidHeader,
    "zlib: unsupported compression method",
  )
  expect_one_shot_zlib_error(
    [0x78, 0x00, 0x00, 0x00, 0x00, 0x00],
    InvalidHeader,
    "zlib: bad header check",
  )
  expect_one_shot_zlib_error(
    [0x78, 0x20, 0x00, 0x00, 0x00, 0x01],
    DictionaryRequired,
    "zlib: preset dictionary required (use the streaming Decoder)",
  )
}

///|
test "coverage: one-shot zlib body and trailer errors" {
  // 0x03 begins a final fixed-Huffman block but omits its end-of-block code.
  expect_one_shot_zlib_error(
    [0x78, 0x01, 0x03, 0x00, 0x00, 0x00, 0x01],
    Truncated,
    "zlib: truncated DEFLATE stream",
  )
  let damaged = @zlib.zlib_compress(b"one-shot Adler coverage").to_array()
  damaged[damaged.length() - 1] = damaged[damaged.length() - 1] ^ b'\x01'
  expect_one_shot_zlib_error(
    Bytes::from_array(damaged),
    ChecksumMismatch,
    "zlib: Adler-32 mismatch",
  )
}

///|
test "coverage: streaming zlib header and FDICT errors" {
  let output = FixedArray::make(1, b'\x00')
  let short = @zlib.Decoder::new()
  let short_status = short.step(b"\x78"[:], output.mut_view())
  let short_consumed = short.last_consumed()
  let short_produced = short.last_produced()
  assert_true(short_status is NeedMoreInput)
  assert_eq(short_consumed, 1)
  assert_eq(short_produced, 0)

  expect_streaming_zlib_error(
    [0x79, 0x00],
    InvalidHeader,
    "zlib: unsupported compression method",
  )
  expect_streaming_zlib_error(
    [0x78, 0x00],
    InvalidHeader,
    "zlib: bad header check",
  )

  // CMF/FLG 0x7820 announces FDICT. Adler-32(b"") is 1, so the first
  // decoder can validate the split DICTID once all four bytes arrive.
  let split = @zlib.Decoder::new(dictionary=b"")
  let header_status = split.step(b"\x78\x20"[:], output.mut_view())
  let header_consumed = split.last_consumed()
  let header_produced = split.last_produced()
  assert_true(header_status is NeedMoreInput)
  assert_eq(header_consumed, 2)
  assert_eq(header_produced, 0)
  let dict_status = split.step(b"\x00\x00\x00\x01"[:], output.mut_view())
  let dict_consumed = split.last_consumed()
  let dict_produced = split.last_produced()
  assert_true(dict_status is NeedMoreInput)
  assert_eq(dict_consumed, 4)
  assert_eq(dict_produced, 0)

  expect_streaming_zlib_error(
    [0x78, 0x20, 0x00, 0x00, 0x00, 0x01],
    DictionaryRequired,
    "zlib: preset dictionary required",
  )
  let wrong = @zlib.Decoder::new(dictionary=b"wrong dictionary")
  try wrong.step(b"\x78\x20\x00\x00\x00\x01"[:], output.mut_view()) catch {
    ZlibError(kind, message) => {
      assert_true(kind == DictionaryMismatch)
      assert_eq(message, "zlib: dictionary id mismatch")
    }
  } noraise {
    _ => fail("expected the wrong dictionary to be rejected")
  }
}

///|
test "coverage: streaming truncated DEFLATE and output backpressure" {
  let output = FixedArray::make(1, b'\x00')
  let truncated = @zlib.Decoder::new()
  let truncated_status = truncated.step(b"\x78\x01\x03"[:], output.mut_view())
  let truncated_consumed = truncated.last_consumed()
  let truncated_produced = truncated.last_produced()
  assert_true(truncated_status is NeedMoreInput)
  assert_eq(truncated_consumed, 3)
  assert_eq(truncated_produced, 0)

  let source = b"one-byte output backpressure must preserve every byte"
  let encoded = @zlib.zlib_compress(source)
  let decoder = @zlib.Decoder::new()
  let no_output = FixedArray::make(0, b'\x00')
  let blocked_status = decoder.step(encoded[:], no_output.mut_view())
  let blocked_consumed = decoder.last_consumed()
  let blocked_produced = decoder.last_produced()
  assert_true(blocked_status is NeedMoreOutput)
  assert_eq(blocked_consumed, encoded.length())
  assert_eq(blocked_produced, 0)
  let decoded = Buffer()
  for _ in 0..<4096 {
    let status = decoder.step(b""[:], output.mut_view())
    let consumed = decoder.last_consumed()
    let produced = decoder.last_produced()
    assert_eq(consumed, 0)
    assert_true(produced >= 0 && produced <= 1)
    if produced == 1 {
      decoded.write_byte(output[0])
    }
    if status is Done {
      break
    }
  }
  assert_true(decoder.is_finished())
  assert_eq(decoded.to_bytes(), source)
}

///|
test "coverage: streaming Adler mismatch after backpressure" {
  let damaged = @zlib.zlib_compress(b"streaming Adler coverage").to_array()
  damaged[damaged.length() - 1] = damaged[damaged.length() - 1] ^ b'\x01'
  let input = Bytes::from_array(damaged)
  let decoder = @zlib.Decoder::new()
  let output = FixedArray::make(1, b'\x00')
  let mut first = true
  try {
    for _ in 0..<4096 {
      let chunk = if first { input[:] } else { b""[:] }
      let status = decoder.step(chunk, output.mut_view())
      let consumed = decoder.last_consumed()
      let produced = decoder.last_produced()
      if consumed != chunk.length() {
        abort("streaming decoder reported an invalid consumed count")
      }
      if produced < 0 || produced > 1 {
        abort("streaming decoder exceeded the output view")
      }
      first = false
      if status is Done {
        break
      }
    }
  } catch {
    ZlibError(kind, message) => {
      assert_true(kind == ChecksumMismatch)
      assert_eq(message, "zlib: Adler-32 mismatch")
    }
  } noraise {
    _ => fail("expected the damaged streaming trailer to be rejected")
  }
}
