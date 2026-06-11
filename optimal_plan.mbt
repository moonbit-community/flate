// Optimal block planning (zopfli-style block splitting): the drop-in
// counterpart to the threshold planner in block_planner.mbt. A cheap greedy
// parse of each master chunk provides reference tokens; split points are
// searched by recursive narrowing (zopfli's FindMinimum) and inserted
// greedily while two blocks cost fewer exact bits than one, under a block
// budget. Segments are then re-parsed by the optimal parser, the splitting is
// repeated once on the optimal tokens (zopfli's blocksplittinglast), and the
// cheaper of the two groupings is emitted through the ordinary `emit_block` —
// planner and parser replaced, writer untouched, output standard DEFLATE.

///|
/// Splitting and parsing happen within master chunks of this many input
/// bytes, bounding the planner's working memory (zopfli's MASTER_BLOCK_SIZE
/// plays the same role).
let optimal_master_block = 262144

///|
/// Most blocks the splitter may cut one master chunk into (zopfli's default).
let optimal_max_blocks = 15

///|
/// Exact cost in bits of one block (3-bit header included): the cheapest of
/// stored / fixed / dynamic, mirroring `emit_block`'s accounting. Judges both
/// split candidates and squeeze iterations.
fn block_cost_bits(
  byte_len : Int,
  ll_freq_in : Array[Int],
  d_freq : Array[Int],
) -> Int {
  let ll_freq = Array::make(286, 0)
  for s in 0..<286 {
    ll_freq[s] = ll_freq_in[s]
  }
  ll_freq[256] += 1
  let (dll_len, _) = gen_huffman(ll_freq, 286, 15)
  let (dd_len, _) = gen_huffman(d_freq, 30, 15)
  let mut have_dist = false
  for d in 0..<30 {
    if dd_len[d] > 0 {
      have_dist = true
      break
    }
  }
  if !have_dist {
    dd_len[0] = 1
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
  let (codelen_code_len, _) = gen_huffman(codelen_freq, 19, 7)
  let mut hclen = 19
  while hclen > 4 && codelen_code_len[code_order[hclen - 1]] == 0 {
    hclen = hclen - 1
  }
  let mut dyn_sym = 0
  let mut fixed_sym = 0
  for s in 0..<286 {
    if ll_freq[s] != 0 {
      dyn_sym = dyn_sym + ll_freq[s] * dll_len[s]
      fixed_sym = fixed_sym + ll_freq[s] * fixed_litlen.1[s]
    }
  }
  for d in 0..<30 {
    if d_freq[d] != 0 {
      dyn_sym = dyn_sym + d_freq[d] * dd_len[d]
      fixed_sym = fixed_sym + d_freq[d] * 5
    }
  }
  let mut extra = 0
  for i in 0..<29 {
    extra = extra + ll_freq[257 + i] * len_extra[i]
  }
  for d in 0..<30 {
    extra = extra + d_freq[d] * dist_extra[d]
  }
  let mut dyn_hdr = 14 + 3 * hclen
  for it in codelen_syms {
    dyn_hdr = dyn_hdr + codelen_code_len[it.sym] + it.nextra
  }
  let stored = 8 * (byte_len + 5 * (byte_len / 65535 + 1))
  let dynamic = 3 + dyn_hdr + dyn_sym + extra
  let fixed = 3 + fixed_sym + extra
  let mut best = stored
  if fixed < best {
    best = fixed
  }
  if dynamic < best {
    best = dynamic
  }
  best
}

///|
/// Symbol frequencies of `tokens[lo:hi)`.
fn range_freqs(
  tokens : Array[Token],
  lo : Int,
  hi : Int,
) -> (Array[Int], Array[Int]) {
  let ll_freq = Array::make(286, 0)
  let d_freq = Array::make(30, 0)
  for k in lo..<hi {
    match tokens[k] {
      Lit(b) => ll_freq[b] += 1
      Match(l, d) => {
        ll_freq[257 + len_to_idx[l]] += 1
        d_freq[dist_index(d)] += 1
      }
    }
  }
  (ll_freq, d_freq)
}

///|
/// Exact block cost of `tokens[lo:hi)` covering `byte_len` input bytes.
fn split_range_cost(
  tokens : Array[Token],
  lo : Int,
  hi : Int,
  byte_len : Int,
) -> Int {
  let (ll_freq, d_freq) = range_freqs(tokens, lo, hi)
  block_cost_bits(byte_len, ll_freq, d_freq)
}

///|
/// zopfli's FindMinimum: locate the split point inside (lo, hi) minimizing
/// the two halves' summed exact cost, by sampling 9 evenly spaced candidates
/// and recursively narrowing to the winner's neighborhood; small intervals
/// are scanned exhaustively. Returns (split index, cost), index -1 if the
/// interval admits no interior point.
fn find_best_split(
  tokens : Array[Token],
  tok_pos : Array[Int],
  lo : Int,
  hi : Int,
) -> (Int, Int) {
  let eval = fn(k : Int) -> Int {
    split_range_cost(tokens, lo, k, tok_pos[k] - tok_pos[lo]) +
    split_range_cost(tokens, k, hi, tok_pos[hi] - tok_pos[k])
  }
  let sample = 9
  let mut plo = lo + 1
  let mut phi = hi - 1
  let mut best_k = -1
  let mut best_cost = 0x3FFFFFFF
  while phi - plo > sample {
    let step = (phi - plo) / (sample + 1)
    let mut win_i = 0
    let mut win_k = plo
    let mut win_c = 0x3FFFFFFF
    for i in 0..<sample {
      let k = plo + (i + 1) * step
      let c = eval(k)
      if c < win_c {
        win_c = c
        win_k = k
        win_i = i
      }
    }
    if win_c < best_cost {
      best_cost = win_c
      best_k = win_k
    }
    let nlo = if win_i == 0 { plo } else { plo + win_i * step }
    let nhi = if win_i == sample - 1 { phi } else { plo + (win_i + 2) * step }
    plo = nlo
    phi = nhi
  }
  for k in plo..<=phi {
    if k <= lo || k >= hi {
      continue
    }
    let c = eval(k)
    if c < best_cost {
      best_cost = c
      best_k = k
    }
  }
  (best_k, best_cost)
}

///|
/// Greedily insert split points (token indices) while a split still lowers
/// the exact total cost, up to `optimal_max_blocks` blocks. `tok_pos[k]` is
/// the byte offset where token k starts (with `tok_pos[m]` = chunk end).
fn plan_split_points(tokens : Array[Token], tok_pos : Array[Int]) -> Array[Int] {
  let bounds : Array[Int] = [0, tokens.length()]
  while bounds.length() - 1 < optimal_max_blocks {
    let mut best_gain = 0
    let mut best_seg = -1
    let mut best_k = -1
    for s in 0..<(bounds.length() - 1) {
      let lo = bounds[s]
      let hi = bounds[s + 1]
      if hi - lo < 16 {
        continue
      }
      let whole = split_range_cost(tokens, lo, hi, tok_pos[hi] - tok_pos[lo])
      let (k, cost) = find_best_split(tokens, tok_pos, lo, hi)
      if k >= 0 && whole - cost > best_gain {
        best_gain = whole - cost
        best_seg = s
        best_k = k
      }
    }
    if best_seg < 0 {
      break
    }
    bounds.insert(best_seg + 1, best_k)
  }
  bounds
}

///|
/// Total exact cost of a grouping (consecutive bounds over `tokens`).
fn grouping_cost(
  tokens : Array[Token],
  tok_pos : Array[Int],
  bounds : Array[Int],
) -> Int {
  let mut total = 0
  for s in 0..<(bounds.length() - 1) {
    let lo = bounds[s]
    let hi = bounds[s + 1]
    total = total + split_range_cost(tokens, lo, hi, tok_pos[hi] - tok_pos[lo])
  }
  total
}

///|
/// Compress with zopfli-style effort: content-driven block splitting plus
/// iterated optimal parsing, with a second splitting pass over the optimal
/// tokens (blocksplittinglast). Tens to hundreds of times slower than
/// `deflate_all` — for compress-once, serve-forever artifacts.  `iterations` is the squeeze count
/// per block (zopfli's default is 15).
pub fn deflate_all_optimal(input : Bytes, iterations? : Int = 15) -> Bytes {
  let iters = if iterations < 1 { 1 } else { iterations }
  let w = BitWriter::new()
  let n = input.length()
  if n == 0 {
    let ll_freq = Array::make(286, 0)
    let d_freq = Array::make(30, 0)
    let none : Array[Token] = []
    emit_block(w, input, 0, 0, none[:], ll_freq, d_freq, is_final=true)
    w.flush()
    return Bytes::from_array(w.out)
  }
  let mut pos = 0
  for ;; {
    let target = if pos + optimal_master_block < n {
      pos + optimal_master_block
    } else {
      n
    }
    // Phase 1: cheap greedy reference parse (level-9 tuning), split it, and
    // optimal-parse each segment, concatenating the optimal tokens.
    let (gtoks, _, _, processed) = tokenize(
      input,
      pos,
      target,
      level_configs[9],
    )
    let chunk_end = processed // a boundary match may overhang `target`
    let gtok_pos = Array::make(gtoks.length() + 1, 0)
    let mut p = pos
    for k in 0..<gtoks.length() {
      gtok_pos[k] = p
      p = p +
        (match gtoks[k] {
          Lit(_) => 1
          Match(l, _) => l
        })
    }
    gtok_pos[gtoks.length()] = chunk_end
    let bounds1 = plan_split_points(gtoks, gtok_pos)
    let all : Array[Token] = []
    let joins : Array[Int] = [0] // phase-1 boundaries, as optimal-token indices
    for s in 0..<(bounds1.length() - 1) {
      let a = gtok_pos[bounds1[s]]
      let b = gtok_pos[bounds1[s + 1]]
      let (toks, _llf, _df) = tokenize_optimal(input, a, b, iters)
      for t in toks {
        all.push(t)
      }
      joins.push(all.length())
    }
    let all_pos = Array::make(all.length() + 1, 0)
    let mut q = pos
    for k in 0..<all.length() {
      all_pos[k] = q
      q = q +
        (match all[k] {
          Lit(_) => 1
          Match(l, _) => l
        })
    }
    all_pos[all.length()] = chunk_end
    // Phase 2 (blocksplittinglast): re-split over the optimal tokens, then
    // emit whichever grouping is cheaper by exact cost.
    let bounds2 = plan_split_points(all, all_pos)
    let bounds = if grouping_cost(all, all_pos, bounds2) <
      grouping_cost(all, all_pos, joins) {
      bounds2
    } else {
      joins
    }
    for s in 0..<(bounds.length() - 1) {
      let lo = bounds[s]
      let hi = bounds[s + 1]
      let (ll_freq, d_freq) = range_freqs(all, lo, hi)
      emit_block(
        w,
        input,
        all_pos[lo],
        all_pos[hi],
        all[lo:hi],
        ll_freq,
        d_freq,
        is_final=all_pos[hi] == n,
      )
    }
    pos = chunk_end
    if pos >= n {
      break
    }
  }
  w.flush()
  Bytes::from_array(w.out)
}
