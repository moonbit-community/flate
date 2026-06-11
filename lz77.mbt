// LZ77 parsing stage of the encode pipeline: bytes in, tokens (literals and
// length/distance matches) plus symbol frequencies out. In modern terms,
// `tokenize` bundles the match finder (3-byte hash chains), the parsing
// policy (greedy or lazy, tuned per compression level), and the symbol tally
// (frequency tables, already in Huffman-symbol space).
//
// This is the designated seam for alternative LZ77 parsers (see the roadmap):
// encoder effort is invisible in the DEFLATE format, so anything that produces
// the same (tokens, frequencies) shape can replace `tokenize` wholesale.

///|
let hash_bits = 15

///|
/// Per-level match-search tuning. The good/lazy/nice/chain values are adopted
/// verbatim from zlib's `configuration_table` (its most field-tested knob
/// set); levels 1-3 are zlib's non-lazy "fast" strategy, expressed here as
/// `max_lazy = 0`. Level 0 (stored only) is special-cased in the block
/// planner and never searches.
priv struct LevelConfig {
  good_length : Int // shrink the chain budget once a match this long is held
  max_lazy : Int // 0 = greedy (commit immediately); else defer while best < this
  nice_length : Int // stop searching outright at this match length
  max_chain : Int // candidate positions examined per search
}

///|
let level_configs : FixedArray[LevelConfig] = [
  { good_length: 0, max_lazy: 0, nice_length: 0, max_chain: 0 }, // 0: stored
  { good_length: 4, max_lazy: 0, nice_length: 8, max_chain: 4 },
  { good_length: 4, max_lazy: 0, nice_length: 16, max_chain: 8 },
  { good_length: 4, max_lazy: 0, nice_length: 32, max_chain: 32 },
  { good_length: 4, max_lazy: 4, nice_length: 16, max_chain: 16 },
  { good_length: 8, max_lazy: 16, nice_length: 32, max_chain: 32 },
  { good_length: 8, max_lazy: 16, nice_length: 128, max_chain: 128 }, // 6: default
  { good_length: 8, max_lazy: 32, nice_length: 128, max_chain: 256 },
  { good_length: 32, max_lazy: 128, nice_length: 258, max_chain: 1024 },
  { good_length: 32, max_lazy: 258, nice_length: 258, max_chain: 4096 }, // 9
]

///|
fn hash3(data : Bytes, i : Int) -> Int {
  let a = data[i].to_int()
  let b = data[i + 1].to_int()
  let c = data[i + 2].to_int()
  (a ^ (b << 5) ^ (c << 10)) & ((1 << hash_bits) - 1)
}

///|
fn match_len(data : Bytes, src : Int, pos : Int, n : Int) -> Int {
  let max = if n - pos < 258 { n - pos } else { 258 }
  let mut k = 0
  while k < max && data[src + k] == data[pos + k] {
    k = k + 1
  }
  k
}

///|
/// Longest back-reference for position `i` that beats `base`, found by walking
/// the hash chain (does not insert `i`). Returns (length, distance); a zero
/// distance means nothing longer than `base` was found. zlib heuristics: the
/// chain budget shrinks 4x once `base` is already a good match, and the search
/// stops outright at `nice_length`.
fn find_match(
  data : Bytes,
  head : Array[Int],
  prev : Array[Int],
  i : Int,
  n : Int,
  base : Int,
  cfg : LevelConfig,
  seed_from : Int,
) -> (Int, Int) {
  let h = hash3(data, i)
  let mut cand = head[h]
  let mut best_len = base
  let mut best_dist = 0
  let mut budget = cfg.max_chain
  if base >= cfg.good_length {
    budget = budget >> 2
  }
  let mut steps = 0
  while cand >= 0 && steps < budget && i - cand <= 32768 {
    let l = match_len(data, cand, i, n)
    if l > best_len {
      best_len = l
      best_dist = i - cand
      if l >= cfg.nice_length {
        break
      }
    }
    // `prev` is indexed relative to `seed_from` so it spans only the working
    // window, not the absolute offset into `data` (see `tokenize`).
    cand = prev[cand - seed_from]
    steps = steps + 1
  }
  (best_len, best_dist)
}

///|
/// Record position `i` in the hash chain so later positions can match it.
fn insert_pos(
  data : Bytes,
  head : Array[Int],
  prev : Array[Int],
  i : Int,
  n : Int,
  seed_from : Int,
) -> Unit {
  if i + 3 <= n {
    let h = hash3(data, i)
    prev[i - seed_from] = head[h]
    head[h] = i
  }
}

///|
priv enum Token {
  Lit(Int)
  Match(Int, Int) // (length, distance)
}

///|
/// LZ77 over `data[start:end)` with the given level's search tuning, returning
/// the tokens, the literal/length and distance frequency tables (sized
/// 286 / 30, end-of-block not yet counted), and the absolute position one past
/// the last byte consumed (≥ `end` when a match straddled the boundary).
///
/// The window-eligible suffix of `data[0:start)` is seeded into the hash chain
/// as history so matches may reference it, but is not itself tokenized.
/// Matches may extend past `end` into any lookahead present in `data`, which
/// is how a streaming caller keeps cross-block back-references intact: pass
/// the carried window as `data[0:start)` and reserve a lookahead tail beyond
/// `end`.
fn tokenize(
  data : Bytes,
  start : Int,
  end : Int,
  cfg : LevelConfig,
) -> (Array[Token], Array[Int], Array[Int], Int) {
  let n = data.length()
  let tokens : Array[Token] = []
  let ll_freq = Array::make(286, 0)
  let d_freq = Array::make(30, 0)
  // LZ77 with hash chains: head[hash] is the most recent position with a
  // given 3-byte hash, prev[pos] the next-older. "Lazy" means a match found
  // at i is held back to see if i+1 starts a longer one.
  let head = Array::make(1 << hash_bits, -1)
  // Positions farther back than the window can never be referenced
  // (find_match rejects distances > 32768), so seeding them is pure waste.
  let seed_from = if start > window_size { start - window_size } else { 0 }
  // `prev` is indexed relative to `seed_from` and covers only positions that
  // are seeded or tokenized here — the carried window plus this segment plus a
  // match's worth of overhang — never the absolute offset into `data`. Sizing
  // it to `data.length()` instead would make a one-shot driver (whole input as
  // `data`, one block at a time) allocate the full input per block.
  let span_end = if end + 258 < n { end + 258 } else { n }
  let prev_size = span_end - seed_from
  let prev = Array::make(if prev_size > 0 { prev_size } else { 1 }, -1)
  for j in seed_from..<start {
    insert_pos(data, head, prev, j, n, seed_from)
  }
  let mut i = start
  let mut prev_len = 0
  let mut prev_dist = 0
  let mut have_prev = false // a match found at i-1 is pending a decision
  while i < end {
    // Skip the search when the deferred match is already >= max_lazy: it is
    // good enough to commit without looking for a longer one (zlib).
    let searching = i + 3 <= n && !(have_prev && prev_len >= cfg.max_lazy)
    let base = if have_prev { prev_len } else { 0 }
    let (cur_len, cur_dist) = if searching {
      find_match(data, head, prev, i, n, base, cfg, seed_from)
    } else {
      (0, 0)
    }
    insert_pos(data, head, prev, i, n, seed_from)
    if have_prev {
      if cur_dist > 0 {
        // A longer match starts at i: emit a literal for i-1, keep deferring.
        let b = data[i - 1].to_int()
        tokens.push(Lit(b))
        ll_freq[b] += 1
        prev_len = cur_len
        prev_dist = cur_dist
        i = i + 1
      } else {
        // The deferred match (starting at i-1) wins: emit it.
        tokens.push(Match(prev_len, prev_dist))
        ll_freq[257 + len_to_idx[prev_len]] += 1
        d_freq[dist_index(prev_dist)] += 1
        let match_end = i - 1 + prev_len
        for j in (i + 1)..<match_end {
          insert_pos(data, head, prev, j, n, seed_from)
        }
        i = match_end
        have_prev = false
      }
    } else if cur_dist > 0 && cur_len >= 3 {
      if cfg.max_lazy == 0 {
        // Greedy levels (1-3): commit the match immediately.
        tokens.push(Match(cur_len, cur_dist))
        ll_freq[257 + len_to_idx[cur_len]] += 1
        d_freq[dist_index(cur_dist)] += 1
        let match_end = i + cur_len
        for j in (i + 1)..<match_end {
          insert_pos(data, head, prev, j, n, seed_from)
        }
        i = match_end
      } else {
        prev_len = cur_len
        prev_dist = cur_dist
        have_prev = true
        i = i + 1
      }
    } else {
      let b = data[i].to_int()
      tokens.push(Lit(b))
      ll_freq[b] += 1
      i = i + 1
    }
  }
  if have_prev {
    // A still-pending match at the boundary commits here.
    tokens.push(Match(prev_len, prev_dist))
    ll_freq[257 + len_to_idx[prev_len]] += 1
    d_freq[dist_index(prev_dist)] += 1
    i = i - 1 + prev_len
  }
  (tokens, ll_freq, d_freq, i)
}
