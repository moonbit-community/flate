///|
/// Validate the one's-complement length pair carried by a stored block.
#inline
fn validate_stored_length(len : Int, nlen : Int) -> Unit raise InflateError {
  guard len == (nlen ^ 0xFFFF) else {
    raise InflateError(Corrupt, "stored block length mismatch")
  }
}

///|
/// Interpret HLIT while preserving its reserved-value diagnostic before any
/// later dynamic-header fields are read.
#inline
fn dynamic_literal_count(bits : Int) -> Int raise InflateError {
  let count = bits + 257
  guard count <= MAX_NUM_LIT else {
    raise InflateError(Corrupt, "corrupt: too many literal codes")
  }
  count
}

///|
/// Interpret HDIST and reject the two reserved five-bit encodings.
#inline
fn dynamic_distance_count(bits : Int) -> Int raise InflateError {
  let count = bits + 1
  guard count <= MAX_NUM_DIST else {
    raise InflateError(Corrupt, "corrupt: too many distance codes")
  }
  count
}

///|
/// Check that a back-reference reaches a byte in the decoder's available
/// history. The caller supplies the history size appropriate to its execution
/// strategy (one-shot output or the streaming circular window), which is
/// always non-negative. Subtracting one as `UInt` turns the inclusive valid
/// interval `1..=available_history` into one upper-bound comparison; zero and
/// negative distances wrap above the bound and are rejected as well.
#inline
fn back_reference_distance_is_valid(
  distance : Int,
  available_history : Int,
) -> Bool {
  distance.reinterpret_as_uint() - 1U < available_history.reinterpret_as_uint()
}

///|
/// Static interpretation of one dynamic-header repeat symbol. Keeping this
/// independent of either bit reader makes the streaming and in-memory decoders
/// agree on the symbol's base count, extra-bit width, and repeated value.
priv struct CodeLengthRepeat {
  base : Int
  extra_bits : Int
  value : Int
}

///|
fn interpret_code_length_repeat(
  symbol : Int,
  previous : Int?,
) -> CodeLengthRepeat raise InflateError {
  match symbol {
    16 => {
      guard previous is Some(value) else {
        raise InflateError(Corrupt, "corrupt: repeat with no previous length")
      }
      { base: 3, extra_bits: 2, value, }
    }
    17 => { base: 3, extra_bits: 3, value: 0, }
    18 => { base: 11, extra_bits: 7, value: 0, }
    _ => raise InflateError(Corrupt, "corrupt: bad code-length symbol")
  }
}

///|
/// Interpret a literal/length code's base length and extra-bit width
/// (RFC 1951 §3.2.5). The caller adds `read_bits(extra)` to the base.
/// Split into two scalar helpers rather than returning a tuple so the per-token
/// decode path allocates nothing.
#inline
fn length_code_base(code : Int) -> Int {
  length_code_info_table[code - 257] >> 3
}

///|
#inline
fn length_code_extra(code : Int) -> Int {
  length_code_info_table[code - 257] & 0x7
}

///|
/// Interpret a distance code's base distance and extra-bit width
/// (RFC 1951 §3.2.5). The caller adds `read_bits(extra)` to the base.
#inline
fn distance_code_base(code : Int) -> Int {
  distance_code_info_table[code] >> 4
}

///|
#inline
fn distance_code_extra(code : Int) -> Int {
  distance_code_info_table[code] & 0xF
}

///|
/// The fixed-Huffman distance symbol carried by a raw five-bit code: the code
/// is stored bit-reversed in the lowest five bits (RFC 1951 §3.2.6).
#inline
fn fixed_distance_symbol(bits5 : Int) -> Int {
  reverse8(((bits5 << 3) & 0xFF).to_byte()).to_int()
}

///|
/// Decode one dynamic-Huffman block header, shared by the streaming `Inflater`
/// and the in-memory `MemDecoder` so both interpret HLIT/HDIST/HCLEN and the
/// code-length run-length encoding identically. `read_bits` and `huff_sym`
/// come from the caller's bit reader and raise only `InflateError`; the
/// streaming decoder's input-suspension signal is converted to `Truncated` at
/// its call site. `huff_sym` reads from the code-length tree, which this
/// function has just initialized inside `dyn_litlen`. `codebits` must have
/// `NUM_CODES` slots and `clbits` room for `nlit + ndist`. Returns the
/// literal/length and distance code counts.
fn decode_dynamic_header(
  read_bits : (Int) -> Int raise InflateError,
  huff_sym : () -> Int raise InflateError,
  dyn_litlen : HuffmanDecoder,
  codebits : Array[Int],
  clbits : Array[Int],
) -> (Int, Int) raise InflateError {
  let nlit = dynamic_literal_count(read_bits(5))
  let ndist = dynamic_distance_count(read_bits(5))
  let nclen = read_bits(4) + 4
  for i in 0..<nclen {
    codebits[code_order[i]] = read_bits(3)
  }
  for i in nclen..<code_order.length() {
    codebits[code_order[i]] = 0
  }
  if !dyn_litlen.initialize(codebits[:]) {
    raise InflateError(Corrupt, "corrupt: bad code-length tree")
  }
  let n = nlit + ndist
  let mut i = 0
  while i < n {
    let x = huff_sym()
    guard x >= 16 else {
      clbits[i] = x
      i = i + 1
      continue
    }
    let previous = if i == 0 { None } else { Some(clbits[i - 1]) }
    let repeat = interpret_code_length_repeat(x, previous)
    let rep = repeat.base + read_bits(repeat.extra_bits)
    guard i + rep <= n else {
      raise InflateError(Corrupt, "corrupt: code-length repeat overflow")
    }
    for _j in 0..<rep {
      clbits[i] = repeat.value
      i = i + 1
    }
  }
  (nlit, ndist)
}
