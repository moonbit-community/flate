///|
priv suberror CoverageUnexpectedDecoderError

///|
/// Finish a test-only LSB-first DEFLATE bit stream.
fn coverage_finish_bits(w : BitWriter) -> Bytes {
  w.flush()
  Bytes::from_array(w.out)
}

///|
/// Write a final dynamic-block header and its code-length alphabet.
fn coverage_dynamic_header(
  w : BitWriter,
  hlit : Int,
  hdist : Int,
  nclen : Int,
  code_lengths : Array[Int],
) -> Unit {
  w.write_bit(1) // BFINAL
  w.write_bits(2, 2) // BTYPE=10 (dynamic)
  w.write_bits(hlit, 5)
  w.write_bits(hdist, 5)
  w.write_bits(nclen - 4, 4)
  for i in 0..<nclen {
    w.write_bits(code_lengths[code_order[i]], 3)
  }
}

///|
/// Both decoder implementations must reject the same complete malformed stream.
fn coverage_expect_both_errors(data : Bytes, expected : String) -> Unit raise {
  try ignore(inflate_all(data)) catch {
    InflateError(message) => assert_eq(message, expected)
  } noraise {
    _ => fail("in-memory decoder accepted malformed DEFLATE")
  }
  let inflater = Inflater::new()
  let output = FixedArray::make(1, b'\x00')
  try ignore(inflater.step(data[:], output.mut_view())) catch {
    InflateError(message) => assert_eq(message, expected)
  } noraise {
    _ => fail("streaming decoder accepted malformed DEFLATE")
  }
}

///|
/// The shared repeat interpreter defines all three RFC symbols and retains a
/// total defensive error for values no valid code-length tree can produce.
test "code-length repeat interpretation is shared and total" {
  let repeat16 = interpret_code_length_repeat(16, Some(9))
  assert_eq(repeat16.base, 3)
  assert_eq(repeat16.extra_bits, 2)
  assert_eq(repeat16.value, 9)
  let repeat17 = interpret_code_length_repeat(17, None)
  assert_eq(repeat17.base, 3)
  assert_eq(repeat17.extra_bits, 3)
  assert_eq(repeat17.value, 0)
  let repeat18 = interpret_code_length_repeat(18, None)
  assert_eq(repeat18.base, 11)
  assert_eq(repeat18.extra_bits, 7)
  assert_eq(repeat18.value, 0)
  try ignore(interpret_code_length_repeat(19, None)) catch {
    InflateError(message) =>
      assert_eq(message, "corrupt: bad code-length symbol")
  } noraise {
    _ => fail("accepted an invalid code-length repeat symbol")
  }
}

///|
/// The streaming boundary classifier preserves known errors and maps every
/// other error kind to its stable public fallback.
test "streaming decoder error classification is total" {
  match classify_decoder_error(NeedInput) {
    DecoderInputExhausted => ()
    DecoderFailure(_) => fail("NeedInput was classified as corruption")
  }
  match classify_decoder_error(InflateError("known failure")) {
    DecoderFailure(message) => assert_eq(message, "known failure")
    DecoderInputExhausted => fail("InflateError was classified as suspension")
  }
  match classify_decoder_error(CoverageUnexpectedDecoderError) {
    DecoderFailure(message) =>
      assert_eq(message, "corrupt: unexpected decoder error")
    DecoderInputExhausted => fail("unknown error was classified as suspension")
  }
}

///|
/// A complete canonical tree with lengths above the nine-bit root-table width
/// must allocate and use the second-level link table in both decoders.
test "Huffman decoder uses its two-level table" {
  // Kraft sum: 1/2 + 1/4 + ... + 1/512 + 2/1024 = 1.
  let lengths = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 10]
  let h = HuffmanDecoder::new()
  assert_true(h.initialize(lengths[:]))
  assert_true(h.links.length() > 0)
  assert_eq(h.link_mask, 1U)

  // Symbols 9 and 10 have canonical codes 1022 and 1023. Their transmitted
  // (bit-reversed) forms are respectively 0x1ff and 0x3ff.
  let code9 : Bytes = [0xFF, 0x01]
  let stream9 = Inflater::new()
  stream9.view = code9[:]
  assert_eq(stream9.huff_sym(h), 9)
  let memory9 = MemDecoder::new(code9)
  assert_eq(memory9.huff_sym(h), 9)

  let code10 : Bytes = [0xFF, 0x03]
  let stream10 = Inflater::new()
  stream10.view = code10[:]
  assert_eq(stream10.huff_sym(h), 10)
  let memory10 = MemDecoder::new(code10)
  assert_eq(memory10.huff_sym(h), 10)
}

///|
/// Empty decode tables are permitted while reading a malformed dynamic header,
/// but selecting from one is an invalid Huffman code, not an input suspension.
test "both inflaters reject an empty Huffman alphabet" {
  let code_lengths = Array::make(num_codes, 0)
  let w = BitWriter::new()
  coverage_dynamic_header(w, 0, 0, 4, code_lengths)
  coverage_expect_both_errors(
    coverage_finish_bits(w),
    "corrupt: bad Huffman code",
  )
}

///|
/// HLIT and HDIST reserve values beyond the supported alphabets.
test "both inflaters reject oversized dynamic alphabets" {
  let code_lengths = Array::make(num_codes, 0)
  let too_many_literals = BitWriter::new()
  coverage_dynamic_header(too_many_literals, 31, 0, 4, code_lengths)
  coverage_expect_both_errors(
    coverage_finish_bits(too_many_literals),
    "corrupt: too many literal codes",
  )

  let too_many_distances = BitWriter::new()
  coverage_dynamic_header(too_many_distances, 0, 31, 4, code_lengths)
  coverage_expect_both_errors(
    coverage_finish_bits(too_many_distances),
    "corrupt: too many distance codes",
  )
}

///|
/// Three one-bit symbols oversubscribe the code-length Huffman tree.
test "both inflaters reject an oversubscribed code-length tree" {
  let code_lengths = Array::make(num_codes, 0)
  code_lengths[16] = 1
  code_lengths[17] = 1
  code_lengths[18] = 1
  let w = BitWriter::new()
  coverage_dynamic_header(w, 0, 0, 4, code_lengths)
  coverage_expect_both_errors(
    coverage_finish_bits(w),
    "corrupt: bad code-length tree",
  )
}

///|
/// Repeat symbol 16 cannot be the first decoded code length.
test "both inflaters reject repeat-without-previous" {
  let code_lengths = Array::make(num_codes, 0)
  code_lengths[16] = 1 // valid degenerate one-symbol tree; code is zero
  let w = BitWriter::new()
  coverage_dynamic_header(w, 0, 0, 4, code_lengths)
  w.write_bits(0, 1)
  coverage_expect_both_errors(
    coverage_finish_bits(w),
    "corrupt: repeat with no previous length",
  )
}

///|
/// Two maximum symbol-18 runs describe 276 lengths although only 258 are due.
test "both inflaters reject code-length repeat overflow" {
  let code_lengths = Array::make(num_codes, 0)
  code_lengths[18] = 1 // valid degenerate one-symbol tree; code is zero
  let w = BitWriter::new()
  coverage_dynamic_header(w, 0, 0, 4, code_lengths)
  w.write_bits(0, 1)
  w.write_bits(127, 7) // 11 + 127 = 138 zeros
  w.write_bits(0, 1)
  w.write_bits(127, 7) // 138 + 138 > 258
  coverage_expect_both_errors(
    coverage_finish_bits(w),
    "corrupt: code-length repeat overflow",
  )
}

///|
/// The code-length alphabet is valid, but it describes one lone two-bit
/// literal code, which is neither complete nor the permitted one-bit degenerate
/// tree.
test "both inflaters reject an incomplete literal-length tree" {
  let code_lengths = Array::make(num_codes, 0)
  code_lengths[0] = 1
  code_lengths[2] = 2
  code_lengths[18] = 2
  let w = BitWriter::new()
  coverage_dynamic_header(w, 0, 0, 16, code_lengths)
  w.write_bits(1, 2) // symbol 2: clbits[0] = 2
  w.write_bits(3, 2) // symbol 18
  w.write_bits(127, 7) // 138 zeros
  w.write_bits(3, 2) // symbol 18
  w.write_bits(108, 7) // 119 zeros; 1 + 138 + 119 = 258
  coverage_expect_both_errors(
    coverage_finish_bits(w),
    "corrupt: bad literal/length tree",
  )
}

///|
/// A one-bit EOB-only literal tree is valid, while a lone two-bit distance tree
/// is incomplete and must be rejected independently.
test "both inflaters reject an incomplete distance tree" {
  let code_lengths = Array::make(num_codes, 0)
  code_lengths[0] = 2
  code_lengths[1] = 2
  code_lengths[2] = 2
  code_lengths[18] = 2
  let w = BitWriter::new()
  coverage_dynamic_header(w, 0, 0, 18, code_lengths)
  w.write_bits(3, 2) // symbol 18
  w.write_bits(127, 7) // 138 zeros
  w.write_bits(3, 2) // symbol 18
  w.write_bits(107, 7) // 118 zeros; now at literal symbol 256
  w.write_bits(2, 2) // symbol 1: the EOB code has length one
  w.write_bits(1, 2) // symbol 2: the sole distance code has length two
  coverage_expect_both_errors(
    coverage_finish_bits(w),
    "corrupt: bad distance tree",
  )
}

///|
/// Fixed literal/length symbols 286 and 287 are reserved by RFC 1951.
test "both inflaters reject a reserved fixed literal-length symbol" {
  let w = BitWriter::new()
  w.write_bit(1)
  w.write_bits(1, 2) // BTYPE=01 (fixed)
  w.write_code(fixed_litlen.0[286], fixed_litlen.1[286])
  coverage_expect_both_errors(
    coverage_finish_bits(w),
    "corrupt: invalid literal/length code",
  )
}

///|
/// Fixed distance symbols 30 and 31 are reserved by RFC 1951.
test "both inflaters reject a reserved fixed distance symbol" {
  let w = BitWriter::new()
  w.write_bit(1)
  w.write_bits(1, 2) // BTYPE=01 (fixed)
  w.write_code(fixed_litlen.0[257], fixed_litlen.1[257]) // length 3
  w.write_code(30, 5)
  coverage_expect_both_errors(
    coverage_finish_bits(w),
    "corrupt: invalid distance code",
  )
}

///|
/// A valid distance code is still illegal before any history byte exists.
test "both inflaters reject a back-reference before the window" {
  let w = BitWriter::new()
  w.write_bit(1)
  w.write_bits(1, 2) // BTYPE=01 (fixed)
  w.write_code(fixed_litlen.0[257], fixed_litlen.1[257]) // length 3
  w.write_code(0, 5) // distance 1
  coverage_expect_both_errors(
    coverage_finish_bits(w),
    "corrupt: distance too far back",
  )
}

///|
/// The in-memory decoder reports truncation, while the streaming decoder owns
/// the incomplete atomic tail so the caller may drop the supplied byte.
test "stored header truncation stages streaming input" {
  let truncated : Bytes = [0x01]
  try ignore(inflate_all(truncated)) catch {
    InflateError(message) => assert_eq(message, "unexpected end of input")
  } noraise {
    _ => fail("in-memory decoder accepted a truncated stored header")
  }
  let inflater = Inflater::new()
  let output = FixedArray::make(1, b'\x00')
  let (status, consumed, produced) = inflater.step(
    truncated[:],
    output.mut_view(),
  )
  assert_true(status is NeedMoreInput)
  assert_eq(consumed, 1)
  assert_eq(produced, 0)
  assert_eq(inflater.staged_input.length(), 1)
  assert_eq(inflater.view.length(), 0)
  assert_eq(inflater.out.length(), 0)
}

///|
/// Stored-byte reads may resume from an owned atomic tail. Once part of that
/// tail is permanent, compaction must retain only the unread suffix.
test "stored input drains and compacts a partial staged tail" {
  let inflater = Inflater::new()
  inflater.staged_input = [b'\xAA', b'\xBB', b'\xCC']
  inflater.staged_pos = 0
  assert_true(inflater.next_stored_byte() == Some(b'\xAA'))
  assert_eq(inflater.staged_pos, 1)
  inflater.compact_staged_input()
  assert_eq(inflater.staged_pos, 0)
  assert_eq(inflater.staged_input.length(), 2)
  assert_eq(inflater.staged_input[0], b'\xBB')
  assert_eq(inflater.staged_input[1], b'\xCC')
}

///|
/// A complete stored header with a non-complementary NLEN is malformed in both
/// decoding modes.
test "both inflaters reject a stored length mismatch" {
  coverage_expect_both_errors(
    ([0x01, 0x01, 0x00, 0x00, 0x00] : Bytes),
    "stored block length mismatch",
  )
}

///|
/// A fixed block header alone permanently consumes that header in streaming
/// mode but leaves its first Huffman symbol incomplete.
test "fixed-symbol truncation suspends only the streaming inflater" {
  let truncated : Bytes = [0x03]
  try ignore(inflate_all(truncated)) catch {
    InflateError(message) => assert_eq(message, "unexpected end of input")
  } noraise {
    _ => fail("in-memory decoder accepted a truncated fixed block")
  }
  let inflater = Inflater::new()
  let output = FixedArray::make(1, b'\x00')
  let (status, consumed, produced) = inflater.step(
    truncated[:],
    output.mut_view(),
  )
  assert_true(status is NeedMoreInput)
  assert_eq(consumed, 1)
  assert_eq(produced, 0)
}

///|
/// Once an incomplete first header is accepted into the internal staging tail,
/// stream configuration is committed and a late dictionary must be rejected.
test "panic Inflater set_dictionary after staging the first header" {
  let inflater = Inflater::new()
  let output = FixedArray::make(1, b'\x00')
  let partial : Bytes = [0x00]
  let (status, consumed, produced) = inflater.step(
    partial[:],
    output.mut_view(),
  )
  assert_true(status is NeedMoreInput)
  assert_eq(consumed, 1)
  assert_eq(produced, 0)
  assert_true(inflater.started)
  inflater.set_dictionary(b"history"[:])
}

///|
/// A non-final zero-length stored block returns to AtBlock without producing
/// history. The old structural guard therefore mistook it for a fresh stream.
test "panic Inflater set_dictionary after a non-final empty stored block" {
  let inflater = Inflater::new()
  let output = FixedArray::make(1, b'\x00')
  let empty_nonfinal : Bytes = [0x00, 0x00, 0x00, 0xFF, 0xFF]
  ignore(inflater.step(empty_nonfinal[:], output.mut_view()))
  inflater.set_dictionary(b"late dictionary"[:])
}

///|
test "panic Inflater set_dictionary rejects a second dictionary" {
  let inflater = Inflater::new()
  inflater.set_dictionary(b"first"[:])
  inflater.set_dictionary(b"second"[:])
}

///|
test "panic Deflater set_dictionary rejects a second dictionary" {
  let deflater = Deflater::new()
  deflater.set_dictionary(b"first"[:])
  deflater.set_dictionary(b"second"[:])
}
