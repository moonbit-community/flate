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
pub const OPTIMAL_MASTER_BLOCK : Int = 262144

///|
/// Most blocks the splitter may cut one master chunk into (zopfli's default).
const OPTIMAL_MAX_BLOCKS : Int = 15

///|
/// Exact cost in bits of one block (3-bit header included): the cheapest of
/// stored / fixed / dynamic, mirroring `emit_block`'s choice. Judges both
/// split candidates and squeeze iterations. Delegates the accounting to the
/// shared `build_dynamic_codes` + `estimate_block_cost` pair, so the planner
/// can never drift from what the writer actually emits.
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
  let codes = build_dynamic_codes(ll_freq, d_freq)
  let cost = estimate_block_cost(codes, byte_len, ll_freq, d_freq)
  cost.stored.min(cost.fixed).min(cost.dynamic)
}

///|
/// Symbol frequencies of `tokens[lo:hi)`.
fn range_freqs(
  tokens : Array[Int],
  lo : Int,
  hi : Int,
  ll_freq : Array[Int],
  d_freq : Array[Int],
) -> Unit {
  for s in 0..<286 {
    ll_freq[s] = 0
  }
  for d in 0..<30 {
    d_freq[d] = 0
  }
  for k in lo..<hi {
    let tok = tokens[k]
    if tok < 256 {
      ll_freq[tok] += 1
    } else {
      let length = tok >> 16
      let distance = tok & 0xFFFF
      ll_freq[257 + len_to_idx[length]] += 1
      d_freq[dist_index(distance)] += 1
    }
  }
}

///|
/// Exact block cost of `tokens[lo:hi)` covering `byte_len` input bytes.
fn split_range_cost(
  tokens : Array[Int],
  lo : Int,
  hi : Int,
  byte_len : Int,
  ll_freq : Array[Int],
  d_freq : Array[Int],
) -> Int {
  range_freqs(tokens, lo, hi, ll_freq, d_freq)
  block_cost_bits(byte_len, ll_freq, d_freq)
}

///|
fn split_candidate_cost(
  tokens : Array[Int],
  tok_pos : Array[Int],
  lo : Int,
  hi : Int,
  k : Int,
  ll_freq : Array[Int],
  d_freq : Array[Int],
) -> Int {
  split_range_cost(tokens, lo, k, tok_pos[k] - tok_pos[lo], ll_freq, d_freq) +
  split_range_cost(tokens, k, hi, tok_pos[hi] - tok_pos[k], ll_freq, d_freq)
}

///|
/// zopfli's FindMinimum: locate the split point inside (lo, hi) minimizing
/// the two halves' summed exact cost, by sampling 9 evenly spaced candidates
/// and recursively narrowing to the winner's neighborhood; small intervals
/// are scanned exhaustively. Writes split index and cost to `result[0:2]`;
/// index -1 means the interval admits no interior point. The caller reuses the
/// pair so each candidate search does not allocate a return tuple.
fn find_best_split(
  tokens : Array[Int],
  tok_pos : Array[Int],
  lo : Int,
  hi : Int,
  result : FixedArray[Int],
  ll_freq : Array[Int],
  d_freq : Array[Int],
) -> Unit {
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
      let c = split_candidate_cost(tokens, tok_pos, lo, hi, k, ll_freq, d_freq)
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
    let c = split_candidate_cost(tokens, tok_pos, lo, hi, k, ll_freq, d_freq)
    if c < best_cost {
      best_cost = c
      best_k = k
    }
  }
  result[0] = best_k
  result[1] = best_cost
}

///|
/// Greedily insert split points (token indices) while a split still lowers
/// the exact total cost, up to `OPTIMAL_MAX_BLOCKS` blocks. `tok_pos[k]` is
/// the byte offset where token k starts (with `tok_pos[m]` = chunk end).
fn plan_split_points(tokens : Array[Int], tok_pos : Array[Int]) -> Array[Int] {
  let bounds : Array[Int] = [0, tokens.length()]
  let split_result = FixedArray::make(2, 0)
  let ll_freq = Array::make(286, 0)
  let d_freq = Array::make(30, 0)
  while bounds.length() - 1 < OPTIMAL_MAX_BLOCKS {
    let mut best_gain = 0
    let mut best_seg = -1
    let mut best_k = -1
    for s in 0..<(bounds.length() - 1) {
      let lo = bounds[s]
      let hi = bounds[s + 1]
      if hi - lo < 16 {
        continue
      }
      let whole = split_range_cost(
        tokens,
        lo,
        hi,
        tok_pos[hi] - tok_pos[lo],
        ll_freq,
        d_freq,
      )
      find_best_split(tokens, tok_pos, lo, hi, split_result, ll_freq, d_freq)
      let k = split_result[0]
      let cost = split_result[1]
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
  tokens : Array[Int],
  tok_pos : Array[Int],
  bounds : Array[Int],
) -> Int {
  let mut total = 0
  let ll_freq = Array::make(286, 0)
  let d_freq = Array::make(30, 0)
  for s in 0..<(bounds.length() - 1) {
    let lo = bounds[s]
    let hi = bounds[s + 1]
    total = total +
      split_range_cost(
        tokens,
        lo,
        hi,
        tok_pos[hi] - tok_pos[lo],
        ll_freq,
        d_freq,
      )
  }
  total
}

///|
/// Byte offset where each token starts, with `positions[tokens.length()]`
/// pinned to `end`. A literal advances one byte; a match advances its length.
fn token_positions(tokens : Array[Int], start : Int, end : Int) -> Array[Int] {
  let positions = Array::make(tokens.length() + 1, 0)
  let mut p = start
  for k in 0..<tokens.length() {
    positions[k] = p
    let tok = tokens[k]
    p = p + (if tok < 256 { 1 } else { tok >> 16 })
  }
  positions[tokens.length()] = end
  positions
}

///|
/// Phase 1 for one master chunk: a cheap greedy reference parse (level-9
/// tuning), its split points, and an optimal parse of each segment,
/// concatenated into `tokens` with `joins` recording the phase-1 boundaries as
/// token indices. `chunk_end` may overhang `target` when a boundary match
/// straddled it.
priv struct OptimalChunk {
  tokens : Array[Int]
  joins : Array[Int]
  chunk_end : Int
}

///|
fn optimal_parse_chunk(
  input : Bytes,
  pos : Int,
  target : Int,
  iterations : Int,
) -> OptimalChunk {
  let gtoks : Array[Int] = []
  let greedy_ll_freq = Array::make(286, 0)
  let greedy_d_freq = Array::make(30, 0)
  let processed = tokenize(
    input,
    pos,
    target,
    level_configs[9],
    gtoks,
    greedy_ll_freq,
    greedy_d_freq,
  )
  let chunk_end = processed // a boundary match may overhang `target`
  let gtok_pos = token_positions(gtoks, pos, chunk_end)
  let bounds1 = plan_split_points(gtoks, gtok_pos)
  let tokens : Array[Int] = []
  let joins : Array[Int] = [0] // phase-1 boundaries, as optimal-token indices
  for s in 0..<(bounds1.length() - 1) {
    let a = gtok_pos[bounds1[s]]
    let b = gtok_pos[bounds1[s + 1]]
    let toks = tokenize_optimal(input, a, b, iterations)
    for t in toks {
      tokens.push(t)
    }
    joins.push(tokens.length())
  }
  { tokens, joins, chunk_end, }
}

///|
/// Phase 2 for one master chunk (zopfli's blocksplittinglast): re-split the
/// optimal tokens, then emit whichever grouping is cheaper by exact cost
/// through the ordinary `emit_block`.
fn emit_optimal_chunk(
  w : BitWriter,
  input : Bytes,
  chunk : OptimalChunk,
  pos : Int,
  n : Int,
) -> Unit {
  let all = chunk.tokens
  let all_pos = token_positions(all, pos, chunk.chunk_end)
  let bounds2 = plan_split_points(all, all_pos)
  let bounds = if grouping_cost(all, all_pos, bounds2) <
    grouping_cost(all, all_pos, chunk.joins) {
    bounds2
  } else {
    chunk.joins
  }
  for s in 0..<(bounds.length() - 1) {
    let lo = bounds[s]
    let hi = bounds[s + 1]
    let ll_freq = Array::make(286, 0)
    let d_freq = Array::make(30, 0)
    range_freqs(all, lo, hi, ll_freq, d_freq)
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
}

///|
/// Compress with zopfli-style effort: content-driven block splitting plus
/// iterated optimal parsing, with a second splitting pass over the optimal
/// tokens (blocksplittinglast). Tens to hundreds of times slower than
/// `deflate_all` — for compress-once, serve-forever artifacts.  `iterations` is the squeeze count
/// per block (zopfli's default is 15).
pub fn deflate_all_optimal(input : Bytes, iterations? : Int = 15) -> Bytes {
  let iters = iterations.max(1)
  let w = BitWriter()
  let n = input.length()
  guard n != 0 else {
    emit_empty_block(w, input)
    w.flush()
    return Bytes::from_array(w.out)
  }
  let mut pos = 0
  for ;; {
    let target = (pos + OPTIMAL_MASTER_BLOCK).min(n)
    let chunk = optimal_parse_chunk(input, pos, target, iters)
    emit_optimal_chunk(w, input, chunk, pos, n)
    pos = chunk.chunk_end
    guard pos < n else { break }
  }
  w.flush()
  Bytes::from_array(w.out)
}
