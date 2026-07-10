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
        out.push({ sym: 18, extra: r - 11, nextra: 7 })
        run = run - r
      }
      while run >= 3 {
        let r = if run < 10 { run } else { 10 }
        out.push({ sym: 17, extra: r - 3, nextra: 3 })
        run = run - r
      }
      while run > 0 {
        out.push({ sym: 0, extra: 0, nextra: 0 })
        run = run - 1
      }
    } else {
      out.push({ sym: cur, extra: 0, nextra: 0 })
      run = run - 1
      while run >= 3 {
        let r = if run < 6 { run } else { 6 }
        out.push({ sym: 16, extra: r - 3, nextra: 2 })
        run = run - r
      }
      while run > 0 {
        out.push({ sym: cur, extra: 0, nextra: 0 })
        run = run - 1
      }
    }
  }
  out
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
  tokens : ArrayView[Token],
  ll_freq : Array[Int],
  d_freq : Array[Int],
  is_final~ : Bool,
) -> Unit {
  ll_freq[256] += 1 // end-of-block

  // Build dynamic codes.
  let (dll_len, dll_val) = gen_huffman(ll_freq, 286, 15)
  let (dd_len, dd_val) = gen_huffman(d_freq, 30, 15)
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
  let (codelen_code_len, codelen_code_val) = gen_huffman(codelen_freq, 19, 7)
  let mut hclen = 19
  while hclen > 4 && codelen_code_len[code_order[hclen - 1]] == 0 {
    hclen = hclen - 1
  }

  // Estimate all three encodings. Length/distance extra bits are shared by
  // fixed and dynamic but absent from stored, so they join the comparison.
  let mut dyn_sym_bits = 0
  let mut fixed_sym_bits = 0
  for s in 0..<286 {
    if ll_freq[s] != 0 {
      dyn_sym_bits = dyn_sym_bits + ll_freq[s] * dll_len[s]
      fixed_sym_bits = fixed_sym_bits + ll_freq[s] * fixed_litlen.1[s]
    }
  }
  for d in 0..<30 {
    if d_freq[d] != 0 {
      dyn_sym_bits = dyn_sym_bits + d_freq[d] * dd_len[d]
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
  let mut dyn_hdr_bits = 14 + 3 * hclen
  for it in codelen_syms {
    dyn_hdr_bits = dyn_hdr_bits + codelen_code_len[it.sym] + it.nextra
  }
  // Stored: ~5 bytes of framing per 65535-byte chunk, data verbatim. This is
  // the fallback that caps worst-case expansion on incompressible data.
  let len = end - start
  let stored_bits = 8 * (len + 5 * stored_block_count(len))
  let dyn_total = dyn_hdr_bits + dyn_sym_bits + extra_bits
  let fixed_total = fixed_sym_bits + extra_bits
  if stored_bits < dyn_total && stored_bits < fixed_total {
    write_stored(w, data, start, end, is_final~)
    return
  }
  let use_dynamic = dyn_total < fixed_total
  w.write_bit(if is_final { 1 } else { 0 }) // BFINAL
  if use_dynamic {
    w.write_bits(2, 2) // BTYPE = 10 (dynamic)
    w.write_bits(hlit - 257, 5)
    w.write_bits(hdist - 1, 5)
    w.write_bits(hclen - 4, 4)
    for k in 0..<hclen {
      w.write_bits(codelen_code_len[code_order[k]], 3)
    }
    for it in codelen_syms {
      w.write_rcode(codelen_code_val[it.sym], codelen_code_len[it.sym])
      if it.nextra > 0 {
        w.write_bits(it.extra, it.nextra)
      }
    }
    for tok in tokens {
      match tok {
        Lit(b) => w.write_rcode(dll_val[b], dll_len[b])
        Match(length, dist) => {
          let lidx = len_to_idx[length]
          let lsym = 257 + lidx
          w.write_rcode(dll_val[lsym], dll_len[lsym])
          if len_extra[lidx] > 0 {
            w.write_bits(length - len_base[lidx], len_extra[lidx])
          }
          let didx = dist_index(dist)
          w.write_rcode(dd_val[didx], dd_len[didx])
          if dist_extra[didx] > 0 {
            w.write_bits(dist - dist_base[didx], dist_extra[didx])
          }
        }
      }
    }
    w.write_rcode(dll_val[256], dll_len[256]) // EOB
  } else {
    w.write_bits(1, 2) // BTYPE = 01 (fixed)
    for tok in tokens {
      match tok {
        Lit(b) => w.write_code(fixed_litlen.0[b], fixed_litlen.1[b])
        Match(length, dist) => {
          let lidx = len_to_idx[length]
          let lsym = 257 + lidx
          w.write_code(fixed_litlen.0[lsym], fixed_litlen.1[lsym])
          if len_extra[lidx] > 0 {
            w.write_bits(length - len_base[lidx], len_extra[lidx])
          }
          let didx = dist_index(dist)
          w.write_code(didx, 5)
          if dist_extra[didx] > 0 {
            w.write_bits(dist - dist_base[didx], dist_extra[didx])
          }
        }
      }
    }
    w.write_code(fixed_litlen.0[256], fixed_litlen.1[256]) // EOB
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
