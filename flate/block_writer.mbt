// Block emission stage of the encode pipeline: one batch of tokens plus its
// frequency tables in, one DEFLATE block out. Chooses fixed- or
// dynamic-Huffman by exact estimated size, and run-length-encodes the dynamic
// table's code lengths (RFC 1951 §3.2.7).

///|
#valtype
priv struct CodeLenSym {
  sym : Int
  extra : Int
  nextra : Int
}

///|
/// Number of stored blocks required for `byte_len` bytes. An empty range still
/// needs one block, while every non-empty exact 65535-byte multiple ends in its
/// last full block rather than requiring a second empty block.
fn stored_block_count(byte_len : Int) -> Int {
  if byte_len == 0 {
    1
  } else {
    (byte_len - 1) / 65535 + 1
  }
}

///|
/// Run-length-encode the concatenated literal/length and distance code lengths
/// into code-length symbols (RFC 1951 §3.2.7), using 16/17/18.
fn build_codelen_syms(
  ll_len : FixedArray[Int],
  hlit : Int,
  dd_len : FixedArray[Int],
  hdist : Int,
) -> Array[CodeLenSym] {
  let comb = FixedArray::make(hlit + hdist, 0)
  ll_len.blit_to(comb, len=hlit)
  dd_len.blit_to(comb, len=hdist, dst_offset=hlit)
  let out : Array[CodeLenSym] = []
  let m = comb.length()
  let mut i = 0
  while i < m {
    let cur = comb[i]
    let mut run = 1
    while i + run < m && comb[i + run] == cur {
      run = run + 1
    }
    i = i + run
    if cur == 0 {
      while run >= 11 {
        let r = run.min(138)
        out.push({ sym: 18, extra: r - 11, nextra: 7, })
        run = run - r
      }
      while run >= 3 {
        let r = run.min(10)
        out.push({ sym: 17, extra: r - 3, nextra: 3, })
        run = run - r
      }
      while run > 0 {
        out.push({ sym: 0, extra: 0, nextra: 0, })
        run = run - 1
      }
    } else {
      out.push({ sym: cur, extra: 0, nextra: 0, })
      run = run - 1
      while run >= 3 {
        let r = run.min(6)
        out.push({ sym: 16, extra: r - 3, nextra: 2, })
        run = run - r
      }
      while run > 0 {
        out.push({ sym: cur, extra: 0, nextra: 0, })
        run = run - 1
      }
    }
  }
  out
}

///|
/// Exact bit cost of each candidate encoding for one block, 3-bit block
/// header included.
#valtype
priv struct BlockCost {
  stored : Int
  fixed : Int
  dynamic : Int
}

///|
/// Code lengths and RLE header metadata for one dynamic-Huffman block. The
/// encoder builds this cheaper form before deciding whether dynamic coding
/// wins; code words are materialized only for a selected dynamic block.
priv struct DynamicCodeLengths {
  dll_len : FixedArray[Int]
  dd_len : FixedArray[Int]
  hlit : Int
  hdist : Int
  codelen_syms : Array[CodeLenSym]
  codelen_code_len : FixedArray[Int]
  hclen : Int
}

///|
/// Complete code tables for a dynamic-Huffman block that will be emitted.
priv struct DynamicCodes {
  lengths : DynamicCodeLengths
  dll_val : FixedArray[UInt]
  dd_val : FixedArray[UInt]
  codelen_code_val : FixedArray[UInt]
}

///|
priv enum BlockEncoding {
  Stored
  Fixed
  Dynamic(DynamicCodes)
}

///|
/// Build dynamic-Huffman code lengths for one block from its symbol
/// frequencies. `ll_freq` must already include the end-of-block symbol.
fn build_dynamic_code_lengths(
  ll_freq : FixedArray[Int],
  d_freq : FixedArray[Int],
) -> DynamicCodeLengths {
  let dll_len = FixedArray::make(286, 0)
  gen_huffman(ll_freq, 286, 15, dll_len)
  let dd_len = FixedArray::make(30, 0)
  gen_huffman(d_freq, 30, 15, dd_len)
  if !dd_len.any(length => length > 0) {
    dd_len[0] = 1 // DEFLATE requires at least one distance code
  }
  let mut hlit = 286
  while hlit > 257 && dll_len[hlit - 1] == 0 {
    hlit = hlit - 1
  }
  let mut hdist = 30
  while hdist > 1 && dd_len[hdist - 1] == 0 {
    hdist = hdist - 1
  }
  let codelen_syms = build_codelen_syms(dll_len, hlit, dd_len, hdist)
  let codelen_freq = FixedArray::make(19, 0)
  for it in codelen_syms {
    codelen_freq[it.sym] += 1
  }
  let codelen_code_len = FixedArray::make(19, 0)
  gen_huffman(codelen_freq, 19, 7, codelen_code_len)
  let mut hclen = 19
  while hclen > 4 && codelen_code_len[code_order[hclen - 1]] == 0 {
    hclen = hclen - 1
  }
  { dll_len, dd_len, hlit, hdist, codelen_syms, codelen_code_len, hclen, }
}

///|
/// Generate bit-reversed canonical code words from already-computed lengths.
/// This is only needed after a block has won the dynamic-Huffman comparison.
fn canonical_code_values(
  code_len : FixedArray[Int],
  max_bits : Int,
) -> FixedArray[UInt] {
  let counts = FixedArray::make(max_bits + 1, 0)
  for length in code_len {
    if length > 0 {
      counts[length] += 1
    }
  }
  let next_code = FixedArray::make(max_bits + 1, 0)
  for length in 1..<=max_bits {
    next_code[length] = (next_code[length - 1] + counts[length - 1]) << 1
  }
  let values = FixedArray::make(code_len.length(), 0U)
  for symbol in 0..<code_len.length() {
    let length = code_len[symbol]
    if length > 0 {
      values[symbol] = reverse_bits(
        next_code[length].reinterpret_as_uint(),
        length,
      )
      next_code[length] += 1
    }
  }
  values
}

///|
/// Materialize the code words for a dynamic block after its lengths have
/// already been used for exact cost estimation.
fn materialize_dynamic_codes(lengths : DynamicCodeLengths) -> DynamicCodes {
  {
    lengths,
    dll_val: canonical_code_values(lengths.dll_len, 15),
    dd_val: canonical_code_values(lengths.dd_len, 15),
    codelen_code_val: canonical_code_values(lengths.codelen_code_len, 7),
  }
}

///|
/// Exact bit cost of each candidate encoding for one block of `byte_len`
/// input bytes. `ll_freq` must already include the end-of-block symbol.
/// Shared by `emit_block`'s encoding choice and the optimal planner's split
/// decisions, so both always use the same accounting.
fn estimate_block_cost(
  codes : DynamicCodeLengths,
  byte_len : Int,
  ll_freq : FixedArray[Int],
  d_freq : FixedArray[Int],
) -> BlockCost {
  // Length/distance extra bits are shared by fixed and dynamic but absent
  // from stored, so they join the comparison.
  let mut dyn_sym_bits = 0
  let mut fixed_sym_bits = 0
  for s in 0..<286 {
    if ll_freq[s] != 0 {
      dyn_sym_bits = dyn_sym_bits + ll_freq[s] * codes.dll_len[s]
      fixed_sym_bits = fixed_sym_bits + ll_freq[s] * fixed_ll_len[s]
    }
  }
  for d in 0..<30 {
    if d_freq[d] != 0 {
      dyn_sym_bits = dyn_sym_bits + d_freq[d] * codes.dd_len[d]
      fixed_sym_bits = fixed_sym_bits + d_freq[d] * 5
    }
  }
  let mut extra_bits = 0
  for i in 0..<29 {
    extra_bits = extra_bits + ll_freq[257 + i] * len_extra[i]
  }
  for d in 0..<30 {
    extra_bits = extra_bits + d_freq[d] * dist_extra[d]
  }
  let mut dyn_hdr_bits = 14 + 3 * codes.hclen
  for it in codes.codelen_syms {
    dyn_hdr_bits = dyn_hdr_bits + codes.codelen_code_len[it.sym] + it.nextra
  }
  // Stored: ~5 bytes of framing per 65535-byte chunk, data verbatim. This is
  // the fallback that caps worst-case expansion on incompressible data.
  let stored_bits = 8 * (byte_len + 5 * stored_block_count(byte_len))
  {
    stored: stored_bits,
    fixed: 3 + fixed_sym_bits + extra_bits,
    dynamic: 3 + dyn_hdr_bits + dyn_sym_bits + extra_bits,
  }
}

///|
// Decide an encoding once for both input backings. The streaming writer can
// then copy a stored payload directly out of its ring, while one-shot callers
// retain their contiguous `Bytes` fast path.
fn choose_block_encoding(
  byte_len : Int,
  ll_freq : FixedArray[Int],
  d_freq : FixedArray[Int],
) -> BlockEncoding {
  ll_freq[256] += 1 // end-of-block
  let lengths = build_dynamic_code_lengths(ll_freq, d_freq)
  let cost = estimate_block_cost(lengths, byte_len, ll_freq, d_freq)
  if cost.stored < cost.fixed && cost.stored < cost.dynamic {
    Stored
  } else if cost.dynamic < cost.fixed {
    Dynamic(materialize_dynamic_codes(lengths))
  } else {
    Fixed
  }
}

///|
fn write_huffman_block(
  w : BitWriter,
  dynamic_codes : DynamicCodes?,
  tokens : ArrayView[Int],
  is_final : Bool,
) -> Unit {
  w.write_bit(if is_final { 1 } else { 0 }) // BFINAL
  guard dynamic_codes is Some(codes) else {
    write_fixed_block(w, tokens)
    return
  }
  write_dynamic_block(w, codes, tokens)
}

///|
/// Write the length extra bits for one match token (RFC 1951 §3.2.5), shared
/// by the fixed- and dynamic-Huffman write paths. The distance extras stay at
/// the call site, after the distance symbol that precedes them.
#inline
fn write_length_extras(w : BitWriter, length : Int) -> Unit {
  let lidx = len_to_idx[length]
  if len_extra[lidx] > 0 {
    w.write_bits(length - len_base[lidx], len_extra[lidx])
  }
}

///|
/// Write one match token (length symbol, length extras, distance symbol,
/// distance extras) through the given code tables, shared by the fixed- and
/// dynamic-Huffman write paths.
#inline
fn write_match_token(
  w : BitWriter,
  tok : Int,
  ll_val : FixedArray[UInt],
  ll_len : FixedArray[Int],
  dd_val : FixedArray[UInt],
  dd_len : FixedArray[Int],
) -> Unit {
  let length = tok >> 16
  let dist = tok & 0xFFFF
  let lsym = 257 + len_to_idx[length]
  w.write_rcode(ll_val[lsym], ll_len[lsym])
  write_length_extras(w, length)
  let didx = dist_index(dist)
  w.write_rcode(dd_val[didx], dd_len[didx])
  if dist_extra[didx] > 0 {
    w.write_bits(dist - dist_base[didx], dist_extra[didx])
  }
}

///|
/// Write a token stream (literals and length/distance matches) through the
/// given literal/length and distance tables, then the end-of-block symbol.
fn write_tokens(
  w : BitWriter,
  tokens : ArrayView[Int],
  ll_val : FixedArray[UInt],
  ll_len : FixedArray[Int],
  dd_val : FixedArray[UInt],
  dd_len : FixedArray[Int],
) -> Unit {
  for tok in tokens {
    if tok < 256 {
      w.write_rcode(ll_val[tok], ll_len[tok])
    } else {
      write_match_token(w, tok, ll_val, ll_len, dd_val, dd_len)
    }
  }
}

///|
/// Write one dynamic-Huffman block (BTYPE=10): the HLIT/HDIST/HCLEN fields, the
/// code-length code lengths, the RLE-coded code lengths, the token stream, and
/// the end-of-block symbol.
fn write_dynamic_block(
  w : BitWriter,
  codes : DynamicCodes,
  tokens : ArrayView[Int],
) -> Unit {
  w.write_bits(2, 2) // BTYPE = 10 (dynamic)
  w.write_bits(codes.lengths.hlit - 257, 5)
  w.write_bits(codes.lengths.hdist - 1, 5)
  w.write_bits(codes.lengths.hclen - 4, 4)
  for k in 0..<codes.lengths.hclen {
    w.write_bits(codes.lengths.codelen_code_len[code_order[k]], 3)
  }
  for it in codes.lengths.codelen_syms {
    w.write_rcode(
      codes.codelen_code_val[it.sym],
      codes.lengths.codelen_code_len[it.sym],
    )
    if it.nextra > 0 {
      w.write_bits(it.extra, it.nextra)
    }
  }
  write_tokens(
    w,
    tokens,
    codes.dll_val,
    codes.lengths.dll_len,
    codes.dd_val,
    codes.lengths.dd_len,
  )
  w.write_rcode(codes.dll_val[256], codes.lengths.dll_len[256]) // EOB
}

///|
/// Write one fixed-Huffman block (BTYPE=01): the token stream with the fixed
/// literal/length and distance tables, then the end-of-block symbol.
fn write_fixed_block(w : BitWriter, tokens : ArrayView[Int]) -> Unit {
  w.write_bits(1, 2) // BTYPE = 01 (fixed)
  write_tokens(
    w, tokens, fixed_ll_val, fixed_ll_len, fixed_dist_val, fixed_dist_len,
  )
  w.write_rcode(fixed_ll_val[256], fixed_ll_len[256]) // EOB
}

///|
/// Write one empty final block (no tokens) — the one-shot drivers' encoding of
/// an empty input.
fn emit_empty_block(w : BitWriter, input : Bytes) -> Unit {
  let ll_freq = FixedArray::make(MAX_NUM_LIT, 0)
  let d_freq = FixedArray::make(MAX_NUM_DIST, 0)
  let none : FixedArray[Int] = []
  emit_block(w, input, 0, 0, none[:], ll_freq, d_freq, is_final=true)
}

///|
/// Write one DEFLATE block for `tokens` into `w`, choosing stored, fixed- or
/// dynamic-Huffman by estimated size. `data[start:end)` is the raw input the
/// tokens cover, copied verbatim when the stored encoding wins (incompressible
/// data). `is_final` sets the BFINAL bit. Counts the end-of-block symbol into
/// `ll_freq` itself. Does not flush `w`: the bit stream continues into the
/// next block, so the caller flushes once, after the final block.
fn emit_block(
  w : BitWriter,
  data : Bytes,
  start : Int,
  end : Int,
  tokens : ArrayView[Int],
  ll_freq : FixedArray[Int],
  d_freq : FixedArray[Int],
  is_final~ : Bool,
) -> Unit {
  let encoding = choose_block_encoding(end - start, ll_freq, d_freq)
  match encoding {
    Stored => write_stored(w, data, start, end, is_final~)
    Fixed => write_huffman_block(w, None, tokens, is_final)
    Dynamic(codes) => write_huffman_block(w, Some(codes), tokens, is_final)
  }
}

///|
/// Write `data[start:end)` as stored (BTYPE=00) blocks: byte-aligned, raw
/// bytes, at most 65535 per block (LEN is 16-bit). `start == end` writes one
/// empty stored block — which is also the sync-flush marker (`00 00 FF FF`),
/// since the mandatory alignment pads the bit stream to a byte boundary.
fn write_stored(
  w : BitWriter,
  data : Bytes,
  start : Int,
  end : Int,
  is_final~ : Bool,
) -> Unit {
  let mut p = start
  for ;; {
    let n = end - p
    let chunk = n.min(65535)
    let last = p + chunk == end
    if is_final && last {
      w.write_bit(1) // BFINAL
    } else {
      w.write_bit(0)
    }
    w.write_bits(0, 2) // BTYPE = 00 (stored)
    w.flush() // stored blocks are byte-aligned
    let nlen = chunk ^ 0xFFFF
    w.write_byte((chunk & 0xFF).to_byte())
    w.write_byte(((chunk >> 8) & 0xFF).to_byte())
    w.write_byte((nlen & 0xFF).to_byte())
    w.write_byte(((nlen >> 8) & 0xFF).to_byte())
    w.write_bytes(data, p, chunk)
    p = p + chunk
    if last {
      break
    }
  }
}

///|
// Streaming equivalent of `write_stored`: absolute positions map through the
// low half of the mirrored input ring, so no temporary `Bytes` needs to be
// materialized for an incompressible block.
fn write_stored_window(
  w : BitWriter,
  data : FixedArray[Byte],
  start : Int,
  end : Int,
  is_final~ : Bool,
) -> Unit {
  let mut p = start
  for ;; {
    let n = end - p
    let chunk = n.min(65535)
    let last = p + chunk == end
    if is_final && last {
      w.write_bit(1)
    } else {
      w.write_bit(0)
    }
    w.write_bits(0, 2)
    w.flush()
    let nlen = chunk ^ 0xFFFF
    w.out.push((chunk & 0xFF).to_byte())
    w.out.push(((chunk >> 8) & 0xFF).to_byte())
    w.out.push((nlen & 0xFF).to_byte())
    w.out.push(((nlen >> 8) & 0xFF).to_byte())
    // A stored block is smaller than the ring, so at most one wrap occurs.
    let offset = p & STREAM_RING_MASK
    let first = chunk.min(STREAM_RING_SIZE - offset)
    w.out.append(data[offset:offset + first])
    w.out.append(data[:chunk - first])
    p = p + chunk
    if last {
      break
    }
  }
}

///|
fn emit_window_block(
  w : BitWriter,
  data : FixedArray[Byte],
  start : Int,
  end : Int,
  tokens : ArrayView[Int],
  ll_freq : FixedArray[Int],
  d_freq : FixedArray[Int],
  is_final~ : Bool,
) -> Unit {
  let encoding = choose_block_encoding(end - start, ll_freq, d_freq)
  match encoding {
    Stored => write_stored_window(w, data, start, end, is_final~)
    Fixed => write_huffman_block(w, None, tokens, is_final)
    Dynamic(codes) => write_huffman_block(w, Some(codes), tokens, is_final)
  }
}
