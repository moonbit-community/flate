// Block emission stage of the encode pipeline: one batch of tokens plus its
// frequency tables in, one DEFLATE block out. Chooses fixed- or
// dynamic-Huffman by exact estimated size, and run-length-encodes the dynamic
// table's code lengths (RFC 1951 §3.2.7).

///|
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
  ll_len : Array[Int],
  hlit : Int,
  dd_len : Array[Int],
  hdist : Int,
) -> Array[CodeLenSym] {
  let comb : Array[Int] = []
  for i in 0..<hlit {
    comb.push(ll_len[i])
  }
  for i in 0..<hdist {
    comb.push(dd_len[i])
  }
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
        let r = if run < 138 { run } else { 138 }
        out.push({ sym: 18, extra: r - 11, nextra: 7, })
        run = run - r
      }
      while run >= 3 {
        let r = if run < 10 { run } else { 10 }
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
        let r = if run < 6 { run } else { 6 }
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
priv struct BlockCost {
  stored : Int
  fixed : Int
  dynamic : Int
}

///|
/// Code tables of one dynamic-Huffman block, built once and shared between
/// cost estimation and `emit_block`'s write path so both always see the same
/// `hlit`/`hdist`/`hclen`, code lengths, and code words.
priv struct DynamicCodes {
  dll_len : Array[Int]
  dll_val : Array[UInt]
  dd_len : Array[Int]
  dd_val : Array[UInt]
  hlit : Int
  hdist : Int
  codelen_syms : Array[CodeLenSym]
  codelen_code_len : Array[Int]
  codelen_code_val : Array[UInt]
  hclen : Int
}

///|
/// Build the dynamic-Huffman code tables for one block from its symbol
/// frequencies. `ll_freq` must already include the end-of-block symbol.
fn build_dynamic_codes(
  ll_freq : Array[Int],
  d_freq : Array[Int],
) -> DynamicCodes {
  let dll_len = Array::make(286, 0)
  let dll_val = Array::make(286, 0U)
  gen_huffman(ll_freq, 286, 15, dll_len, code_val=dll_val)
  let dd_len = Array::make(30, 0)
  let dd_val = Array::make(30, 0U)
  gen_huffman(d_freq, 30, 15, dd_len, code_val=dd_val)
  let mut have_dist = false
  for d in 0..<30 {
    if dd_len[d] > 0 {
      have_dist = true
      break
    }
  }
  if !have_dist {
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
  let codelen_freq = Array::make(19, 0)
  for it in codelen_syms {
    codelen_freq[it.sym] += 1
  }
  let codelen_code_len = Array::make(19, 0)
  let codelen_code_val = Array::make(19, 0U)
  gen_huffman(codelen_freq, 19, 7, codelen_code_len, code_val=codelen_code_val)
  let mut hclen = 19
  while hclen > 4 && codelen_code_len[code_order[hclen - 1]] == 0 {
    hclen = hclen - 1
  }
  {
    dll_len,
    dll_val,
    dd_len,
    dd_val,
    hlit,
    hdist,
    codelen_syms,
    codelen_code_len,
    codelen_code_val,
    hclen,
  }
}

///|
/// Exact bit cost of each candidate encoding for one block of `byte_len`
/// input bytes. `ll_freq` must already include the end-of-block symbol.
/// Shared by `emit_block`'s encoding choice and the optimal planner's split
/// decisions, so both always use the same accounting.
fn estimate_block_cost(
  codes : DynamicCodes,
  byte_len : Int,
  ll_freq : Array[Int],
  d_freq : Array[Int],
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
/// Write the length extra bits for one match token (RFC 1951 §3.2.5), shared
/// by the fixed- and dynamic-Huffman write paths. The distance extras stay at
/// the call site, after the distance symbol that precedes them.
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
  ll_val : Array[UInt],
  ll_len : Array[Int],
  dd_val : Array[UInt],
  dd_len : Array[Int],
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
  ll_val : Array[UInt],
  ll_len : Array[Int],
  dd_val : Array[UInt],
  dd_len : Array[Int],
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
  w.write_bits(codes.hlit - 257, 5)
  w.write_bits(codes.hdist - 1, 5)
  w.write_bits(codes.hclen - 4, 4)
  for k in 0..<codes.hclen {
    w.write_bits(codes.codelen_code_len[code_order[k]], 3)
  }
  for it in codes.codelen_syms {
    w.write_rcode(
      codes.codelen_code_val[it.sym],
      codes.codelen_code_len[it.sym],
    )
    if it.nextra > 0 {
      w.write_bits(it.extra, it.nextra)
    }
  }
  write_tokens(
    w,
    tokens,
    codes.dll_val,
    codes.dll_len,
    codes.dd_val,
    codes.dd_len,
  )
  w.write_rcode(codes.dll_val[256], codes.dll_len[256]) // EOB
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
  let ll_freq = Array::make(MAX_NUM_LIT, 0)
  let d_freq = Array::make(MAX_NUM_DIST, 0)
  let none : Array[Int] = []
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
  ll_freq : Array[Int],
  d_freq : Array[Int],
  is_final~ : Bool,
) -> Unit {
  ll_freq[256] += 1 // end-of-block

  // Build dynamic codes once, then let the shared accounting choose the
  // encoding and the write path reuse the same tables.
  let codes = build_dynamic_codes(ll_freq, d_freq)
  let cost = estimate_block_cost(codes, end - start, ll_freq, d_freq)
  // Stored is the fallback that caps worst-case expansion on incompressible
  // data: verbatim bytes at ~5 bytes of framing per 65535-byte chunk.
  guard cost.stored >= cost.fixed || cost.stored >= cost.dynamic else {
    write_stored(w, data, start, end, is_final~)
    return
  }
  w.write_bit(if is_final { 1 } else { 0 }) // BFINAL
  if cost.dynamic < cost.fixed {
    write_dynamic_block(w, codes, tokens)
  } else {
    write_fixed_block(w, tokens)
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
    let chunk = if n < 65535 { n } else { 65535 }
    let last = p + chunk == end
    if is_final && last {
      w.write_bit(1) // BFINAL
    } else {
      w.write_bit(0)
    }
    w.write_bits(0, 2) // BTYPE = 00 (stored)
    w.flush() // stored blocks are byte-aligned
    let nlen = chunk ^ 0xFFFF
    w.out.push((chunk & 0xFF).to_byte())
    w.out.push(((chunk >> 8) & 0xFF).to_byte())
    w.out.push((nlen & 0xFF).to_byte())
    w.out.push(((nlen >> 8) & 0xFF).to_byte())
    for i in p..<(p + chunk) {
      w.out.push(data[i])
    }
    p = p + chunk
    if last {
      break
    }
  }
}
