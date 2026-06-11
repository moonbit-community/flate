// Optimal LZ77 parsing (zopfli-style "squeeze"): the drop-in counterpart to
// the greedy/lazy parser in lz77.mbt, plugged into the same
// (tokens, frequencies) seam. The parse is a cost-driven shortest path over
// the token graph: every position may step one literal or any reachable
// match, with edge weights in bits. Real costs depend on the Huffman tables,
// which depend on the parse — so the parse is iterated: each round's
// frequencies build length-limited Huffman codes (the writer's own
// `gen_huffman`) whose code lengths become the next round's costs, and the
// cheapest parse seen (by exact block cost) wins.

///|
/// One Pareto-frontier entry among the matches at a position: lengths in
/// (previous entry's len, len] are reachable at `dist`, the smallest distance
/// achieving them (the chain walks nearest-first, so the first candidate
/// reaching a new length has the minimal distance for it).
priv struct MatchRange {
  len : Int
  dist : Int
}

///|
/// Chain candidates examined per position; effectively exhaustive, in keeping
/// with the offline effort budget.
let optimal_max_chain = 8192

///|
fn capped_match_len(data : Bytes, src : Int, pos : Int, limit : Int) -> Int {
  let mut k = 0
  while k < limit && data[src + k] == data[pos + k] {
    k = k + 1
  }
  k
}

///|
/// The match frontier at every position of `data[start:end)`, computed once
/// and reused by every squeeze iteration. Matches never extend past `end`
/// (the planner chose exact bounds). The window-eligible suffix of
/// `data[0:start)` is seeded as history so back-references may cross block
/// boundaries.
fn collect_matches(
  data : Bytes,
  start : Int,
  end : Int,
) -> Array[Array[MatchRange]] {
  let seed_from = if start > window_size { start - window_size } else { 0 }
  let head = Array::make(1 << hash_bits, -1)
  // `prev` slots are relative to seed_from, so the array is bounded by
  // window + segment, not by the absolute offset into the input.
  let prev = Array::make(if end > seed_from { end - seed_from } else { 1 }, -1)
  let n = data.length()
  let insert = fn(i : Int) {
    if i + 3 <= n {
      let h = hash3(data, i)
      prev[i - seed_from] = head[h]
      head[h] = i
    }
  }
  for j in seed_from..<start {
    insert(j)
  }
  let out : Array[Array[MatchRange]] = []
  for i in start..<end {
    let frontier : Array[MatchRange] = []
    let limit = if end - i < 258 { end - i } else { 258 }
    if limit >= 3 && i + 3 <= n {
      let h = hash3(data, i)
      let mut cand = head[h]
      let mut best = 2
      let mut steps = 0
      while cand >= 0 && steps < optimal_max_chain && i - cand <= 32768 {
        let l = capped_match_len(data, cand, i, limit)
        if l > best {
          frontier.push({ len: l, dist: i - cand })
          best = l
          if l >= limit {
            break
          }
        }
        cand = prev[cand - seed_from]
        steps = steps + 1
      }
    }
    insert(i)
    out.push(frontier)
  }
  out
}

///|
/// One shortest-path pass: bit costs in, parse out. `costs[o]` is the minimal
/// bits to encode `data[start:start+o)`; each position relaxes a literal edge
/// and every frontier match length.
fn squeeze_parse(
  data : Bytes,
  start : Int,
  end : Int,
  matches : Array[Array[MatchRange]],
  ll_cost : Array[Int],
  d_cost : Array[Int],
) -> (Array[Token], Array[Int], Array[Int]) {
  let m = end - start
  let inf = 0x3FFFFFFF
  let costs = Array::make(m + 1, inf)
  let len_choice = Array::make(m + 1, 0)
  let dist_choice = Array::make(m + 1, 0)
  costs[0] = 0
  for o in 0..<m {
    let base = costs[o]
    let i = start + o
    let lc = base + ll_cost[data[i].to_int()]
    if lc < costs[o + 1] {
      costs[o + 1] = lc
      len_choice[o + 1] = 1
      dist_choice[o + 1] = 0
    }
    let fr = matches[o]
    let mut lo = 3
    for k in 0..<fr.length() {
      let e = fr[k]
      let didx = dist_index(e.dist)
      let dbits = d_cost[didx] + dist_extra[didx]
      for l in lo..<=e.len {
        let lidx = len_to_idx[l]
        let c = base + ll_cost[257 + lidx] + len_extra[lidx] + dbits
        if c < costs[o + l] {
          costs[o + l] = c
          len_choice[o + l] = l
          dist_choice[o + l] = e.dist
        }
      }
      lo = e.len + 1
    }
  }
  // Trace the optimal path back, then replay it forward into tokens.
  let steps : Array[Int] = []
  let mut o = m
  while o > 0 {
    steps.push(o)
    o = o - len_choice[o]
  }
  let tokens : Array[Token] = []
  let ll_freq = Array::make(286, 0)
  let d_freq = Array::make(30, 0)
  let mut pos = start
  for k = steps.length() - 1; k >= 0; k = k - 1 {
    let at = steps[k]
    let l = len_choice[at]
    if l == 1 && dist_choice[at] == 0 {
      let b = data[pos].to_int()
      tokens.push(Lit(b))
      ll_freq[b] += 1
    } else {
      tokens.push(Match(l, dist_choice[at]))
      ll_freq[257 + len_to_idx[l]] += 1
      d_freq[dist_index(dist_choice[at])] += 1
    }
    pos = pos + l
  }
  (tokens, ll_freq, d_freq)
}

///|
/// Turn a parse's symbol frequencies into the next round's bit costs: real
/// length-limited Huffman code lengths (the same construction the writer
/// uses), with unused symbols priced at the maximum length so the parse may
/// still explore them.
fn stats_to_costs(
  ll_freq : Array[Int],
  d_freq : Array[Int],
) -> (Array[Int], Array[Int]) {
  let ll_freq_eob = Array::make(286, 0)
  for s in 0..<286 {
    ll_freq_eob[s] = ll_freq[s]
  }
  ll_freq_eob[256] += 1
  let (ll_len, _) = gen_huffman(ll_freq_eob, 286, 15)
  let (dd_len, _) = gen_huffman(d_freq, 30, 15)
  let ll_cost = Array::make(286, 0)
  for s in 0..<286 {
    ll_cost[s] = if ll_len[s] == 0 { 15 } else { ll_len[s] }
  }
  let d_cost = Array::make(30, 0)
  for d in 0..<30 {
    d_cost[d] = if dd_len[d] == 0 { 15 } else { dd_len[d] }
  }
  (ll_cost, d_cost)
}

///|
/// Iterated optimal parse of `data[start:end)`: squeeze under fixed-table
/// costs first, then re-derive costs from each round's own statistics,
/// keeping the cheapest parse seen (judged by exact block cost).
fn tokenize_optimal(
  data : Bytes,
  start : Int,
  end : Int,
  iterations : Int,
) -> (Array[Token], Array[Int], Array[Int]) {
  let matches = collect_matches(data, start, end)
  let mut ll_cost = Array::make(286, 0)
  for s in 0..<286 {
    ll_cost[s] = fixed_litlen.1[s]
  }
  let mut d_cost = Array::make(30, 5)
  let mut best_bits = 0x3FFFFFFF
  let mut best : (Array[Token], Array[Int], Array[Int])? = None
  for _it in 0..<iterations {
    let (toks, ll_freq, d_freq) = squeeze_parse(
      data, start, end, matches, ll_cost, d_cost,
    )
    let bits = block_cost_bits(end - start, ll_freq, d_freq)
    if bits < best_bits {
      best_bits = bits
      best = Some((toks, ll_freq, d_freq))
    }
    let (nl, nd) = stats_to_costs(ll_freq, d_freq)
    ll_cost = nl
    d_cost = nd
  }
  best.unwrap()
}
