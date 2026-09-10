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
pub const HASH_BITS : Int = 15

///|
const WINDOW_MASK : Int = WINDOW_SIZE - 1

///|
// The streaming input ring holds the 32 KiB match window plus one accepted
// block and its lookahead. It is mirrored so a 16-byte SIMD load at its end
// can continue into the duplicate half without a wrap branch.
const STREAM_RING_SIZE : Int = 65536

///|
const STREAM_RING_MASK : Int = STREAM_RING_SIZE - 1

///|
const STREAM_RING_STORAGE_SIZE : Int = STREAM_RING_SIZE * 2

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
  { good_length: 0, max_lazy: 0, nice_length: 0, max_chain: 0, }, // 0: stored
  { good_length: 4, max_lazy: 0, nice_length: 8, max_chain: 4, },
  { good_length: 4, max_lazy: 0, nice_length: 16, max_chain: 8, },
  { good_length: 4, max_lazy: 0, nice_length: 32, max_chain: 32, },
  { good_length: 4, max_lazy: 4, nice_length: 16, max_chain: 16, },
  { good_length: 8, max_lazy: 16, nice_length: 32, max_chain: 32, },
  { good_length: 8, max_lazy: 16, nice_length: 128, max_chain: 128, }, // 6: default
  { good_length: 8, max_lazy: 32, nice_length: 128, max_chain: 256, },
  { good_length: 32, max_lazy: 128, nice_length: 258, max_chain: 1024, },
  { good_length: 32, max_lazy: 258, nice_length: 258, max_chain: 4096, }, // 9
]

///|
fn hash3(data : Bytes, i : Int) -> Int {
  let a = data[i].to_int()
  let b = data[i + 1].to_int()
  let c = data[i + 2].to_int()
  (a ^ (b << 5) ^ (c << 10)) & ((1 << HASH_BITS) - 1)
}

///|
fn hash3_window(data : FixedArray[Byte], i : Int) -> Int {
  let offset = i & STREAM_RING_MASK
  let a = data[offset].to_int()
  let b = data[offset + 1].to_int()
  let c = data[offset + 2].to_int()
  (a ^ (b << 5) ^ (c << 10)) & ((1 << HASH_BITS) - 1)
}

///|
// `head` records the most recent absolute position for each hash, while the
// fixed 32 KiB `prev` ring links to the next older one. A candidate is valid
// only while it remains within the DEFLATE window, so overwriting its slot on
// the next lap cannot hide a valid match.
priv struct MatchFinder {
  head : FixedArray[Int]
  prev : FixedArray[Int]
}

///|
fn MatchFinder::MatchFinder() -> MatchFinder {
  {
    head: FixedArray::make(1 << HASH_BITS, -1),
    prev: FixedArray::make(WINDOW_SIZE, -1),
  }
}

///|
fn MatchFinder::reset(self : MatchFinder) -> Unit {
  self.head.fill(-1)
  self.prev.fill(-1)
}

///|
fn MatchFinder::rebase(self : MatchFinder, offset : Int) -> Unit {
  for i in 0..<self.head.length() {
    if self.head[i] >= 0 {
      self.head[i] = self.head[i] - offset
    }
  }
  for i in 0..<self.prev.length() {
    if self.prev[i] >= 0 {
      self.prev[i] = self.prev[i] - offset
    }
  }
}

///|
/// `Bytes` and `FixedArray[Byte]` share the same immutable backing layout in
/// the current MoonBit runtime. Keep this experimental identity bridge private
/// and confined to the native/linear-wasm SIMD loader.
#cfg(any(target="native", target="wasm"))
fn bytes_as_fixedarray(data : Bytes) -> FixedArray[Byte] = "%identity"

///|
#cfg(any(target="native", target="wasm"))
fn match_len_up_to(data : Bytes, src : Int, pos : Int, limit : Int) -> Int {
  // Every wide-loop iteration proves both offsets have 16 available bytes.
  // Hoist the zero-copy representation bridge and call v128_load directly;
  // an otherwise tiny wrapper survives native optimization as two calls per
  // compared chunk.
  let bytes = bytes_as_fixedarray(data)
  let mut k = 0
  while k + 16 <= limit {
    let equal_lanes = @v128.i8x16_bitmask(
      @v128.i8x16_eq(
        @v128.v128_load(bytes, src + k),
        @v128.v128_load(bytes, pos + k),
      ),
    )
    if equal_lanes != 0xFFFF {
      return k + (equal_lanes ^ 0xFFFF).ctz()
    }
    k = k + 16
  }
  while k < limit && data[src + k] == data[pos + k] {
    k = k + 1
  }
  k
}

///|
#cfg(any(target="native", target="wasm"))
fn match_len_in_window(
  data : FixedArray[Byte],
  src : Int,
  pos : Int,
  limit : Int,
) -> Int {
  let src = src & STREAM_RING_MASK
  let pos = pos & STREAM_RING_MASK
  let mut k = 0
  while k + 16 <= limit {
    let equal_lanes = @v128.i8x16_bitmask(
      @v128.i8x16_eq(
        @v128.v128_load(data, src + k),
        @v128.v128_load(data, pos + k),
      ),
    )
    if equal_lanes != 0xFFFF {
      return k + (equal_lanes ^ 0xFFFF).ctz()
    }
    k = k + 16
  }
  while k < limit && data[src + k] == data[pos + k] {
    k = k + 1
  }
  k
}

///|
/// JS and wasm-gc currently lower V128 byte comparisons to BigInt/per-lane
/// fallback code. Keep their match finder scalar until those backends provide
/// real SIMD lowering; the native and linear-wasm implementation above remains
/// the semantic reference.
#cfg(not(any(target="native", target="wasm")))
fn match_len_up_to(data : Bytes, src : Int, pos : Int, limit : Int) -> Int {
  let mut k = 0
  while k < limit && data[src + k] == data[pos + k] {
    k = k + 1
  }
  k
}

///|
#cfg(not(any(target="native", target="wasm")))
fn match_len_in_window(
  data : FixedArray[Byte],
  src : Int,
  pos : Int,
  limit : Int,
) -> Int {
  let mut k = 0
  while k < limit &&
        data[(src + k) & STREAM_RING_MASK] == data[(pos + k) & STREAM_RING_MASK] {
    k = k + 1
  }
  k
}

///|
/// Scalar candidate probe retained for the optimal parser. The regular
/// match finders cache their current-position probes across the search loop.
#inline
fn match_candidate_can_beat(
  data : Bytes,
  candidate : Int,
  position : Int,
  best_len : Int,
  limit : Int,
) -> Bool {
  guard best_len < limit else { return false }
  if best_len < 3 {
    data[candidate] == data[position] &&
    data[candidate + 1] == data[position + 1] &&
    data[candidate + 2] == data[position + 2]
  } else {
    data[candidate] == data[position] &&
    data[candidate + 1] == data[position + 1] &&
    data[candidate + best_len - 1] == data[position + best_len - 1] &&
    data[candidate + best_len] == data[position + best_len]
  }
}

///|
/// Longest back-reference for position `i` that beats `base`, found by walking
/// the hash chain (does not insert `i`). Returns `length << 16 | distance`; a
/// zero distance means nothing longer than `base` was found. Both fields fit
/// exactly within their packed ranges (length <= 258, distance <= 32768), and
/// the scalar return avoids allocating a tuple at every searched position.
/// zlib heuristics: the chain budget shrinks 4x once `base` is already a good
/// match, and the search stops outright at `nice_length`.
fn find_match(
  data : Bytes,
  finder : MatchFinder,
  i : Int,
  n : Int,
  base : Int,
  cfg : LevelConfig,
) -> Int {
  let h = hash3(data, i)
  let mut cand = finder.head[h]
  let mut best_len = base
  let mut best_dist = 0
  let limit = if n - i < 258 { n - i } else { 258 }
  guard base < limit else { return base << 16 }
  let mut budget = cfg.max_chain
  if base >= cfg.good_length {
    budget = budget >> 2
  }
  let cutoff = (i - WINDOW_SIZE).max(0)
  guard cand >= cutoff && budget > 0 else { return base << 16 }
  let prefix = data[i].to_int() | (data[i + 1].to_int() << 8)
  let prev = finder.prev
  // Probe the end first, as in libdeflate's longer-match search. Keep the
  // current-position bytes in locals and refresh them only after improvement.
  // With no three-byte match yet, offset 2 checks the same three prefix bytes.
  // Pack adjacent bytes into 16-bit values to combine equality branches;
  // ordinary byte indexing keeps the same bounds guarantees on every target.
  let mut probe = base.max(2)
  let mut suffix = data[i + probe - 1].to_int() |
    (data[i + probe].to_int() << 8)
  let nice_length = cfg.nice_length.min(limit)
  // Like libdeflate's longest_match, keep rejection in a tight inner loop.
  // The cutoff folds both sentinel and window checks into one comparison.
  for ;; {
    for ;; {
      let candidate_suffix = data[cand + probe - 1].to_int() |
        (data[cand + probe].to_int() << 8)
      if candidate_suffix == suffix &&
        (data[cand].to_int() | (data[cand + 1].to_int() << 8)) == prefix {
        break
      }
      budget = budget - 1
      cand = prev[cand & WINDOW_MASK]
      guard budget > 0 && cand >= cutoff else {
        return (best_len << 16) | best_dist
      }
    }
    let length = match_len_up_to(data, cand, i, limit)
    if length > best_len {
      best_len = length
      best_dist = i - cand
      if length >= nice_length {
        break
      }
      probe = length
      suffix = data[i + probe - 1].to_int() | (data[i + probe].to_int() << 8)
    }
    budget = budget - 1
    cand = prev[cand & WINDOW_MASK]
    guard budget > 0 && cand >= cutoff else { break }
  }
  (best_len << 16) | best_dist
}

///|
fn find_window_match(
  data : FixedArray[Byte],
  finder : MatchFinder,
  i : Int,
  end : Int,
  base : Int,
  cfg : LevelConfig,
) -> Int {
  let h = hash3_window(data, i)
  let mut cand = finder.head[h]
  let mut best_len = base
  let mut best_dist = 0
  let limit = if end - i < 258 { end - i } else { 258 }
  guard base < limit else { return base << 16 }
  let mut budget = cfg.max_chain
  if base >= cfg.good_length {
    budget = budget >> 2
  }
  let cutoff = (i - WINDOW_SIZE).max(0)
  guard cand >= cutoff && budget > 0 else { return base << 16 }
  let position = i & STREAM_RING_MASK
  let prefix = data[position].to_int() | (data[position + 1].to_int() << 8)
  let prev = finder.prev
  let mut probe = base.max(2)
  let mut suffix = data[position + probe - 1].to_int() |
    (data[position + probe].to_int() << 8)
  let nice_length = cfg.nice_length.min(limit)
  // Like libdeflate's longest_match, keep rejection in a tight inner loop.
  // The cutoff folds both sentinel and window checks into one comparison.
  for ;; {
    for ;; {
      let candidate = cand & STREAM_RING_MASK
      let candidate_suffix = data[candidate + probe - 1].to_int() |
        (data[candidate + probe].to_int() << 8)
      if candidate_suffix == suffix &&
        (data[candidate].to_int() | (data[candidate + 1].to_int() << 8)) ==
        prefix {
        break
      }
      budget = budget - 1
      cand = prev[cand & WINDOW_MASK]
      guard budget > 0 && cand >= cutoff else {
        return (best_len << 16) | best_dist
      }
    }
    let length = match_len_in_window(data, cand, i, limit)
    if length > best_len {
      best_len = length
      best_dist = i - cand
      if length >= nice_length {
        break
      }
      probe = length
      suffix = data[position + probe - 1].to_int() |
        (data[position + probe].to_int() << 8)
    }
    budget = budget - 1
    cand = prev[cand & WINDOW_MASK]
    guard budget > 0 && cand >= cutoff else { break }
  }
  (best_len << 16) | best_dist
}

///|
/// Record position `i` in the hash chain so later positions can match it.
fn insert_pos(data : Bytes, finder : MatchFinder, i : Int, n : Int) -> Unit {
  if i + 3 <= n {
    let h = hash3(data, i)
    finder.prev[i & WINDOW_MASK] = finder.head[h]
    finder.head[h] = i
  }
}

///|
fn insert_window_pos(
  data : FixedArray[Byte],
  finder : MatchFinder,
  i : Int,
  end : Int,
) -> Unit {
  if i + 3 <= end {
    let h = hash3_window(data, i)
    finder.prev[i & WINDOW_MASK] = finder.head[h]
    finder.head[h] = i
  }
}

///|
/// Batch the interior of a committed match, as in libdeflate's skip_bytes
/// path. Check the available lookahead once and carry the overlapping bytes
/// between hashes. Every position is still inserted in the original order.
fn insert_positions(
  data : Bytes,
  finder : MatchFinder,
  start : Int,
  end : Int,
  available_end : Int,
) -> Unit {
  let end = end.min(available_end - 2)
  guard start < end else { return }
  let head = finder.head
  let prev = finder.prev
  for position = start, a = data[start].to_int(), b = data[start + 1].to_int() {
    guard position < end else { break }
    let c = data[position + 2].to_int()
    let hash = (a ^ (b << 5) ^ (c << 10)) & ((1 << HASH_BITS) - 1)
    prev[position & WINDOW_MASK] = head[hash]
    head[hash] = position
    continue position + 1, b, c
  }
}

///|
/// Streaming counterpart: carry bytes across the mirrored ring boundary,
/// while retaining absolute positions in the hash chains.
fn insert_window_positions(
  data : FixedArray[Byte],
  finder : MatchFinder,
  start : Int,
  end : Int,
  available_end : Int,
) -> Unit {
  let end = end.min(available_end - 2)
  guard start < end else { return }
  let head = finder.head
  let prev = finder.prev
  let offset = start & STREAM_RING_MASK
  for position = start, a = data[offset].to_int(), b = data[offset + 1].to_int() {
    guard position < end else { break }
    let c = data[(position & STREAM_RING_MASK) + 2].to_int()
    let hash = (a ^ (b << 5) ^ (c << 10)) & ((1 << HASH_BITS) - 1)
    prev[position & WINDOW_MASK] = head[hash]
    head[hash] = position
    continue position + 1, b, c
  }
}

///|
/// Packed private token representation. Literals are their byte value 0..255.
/// A match is `(length << 16) | distance`, the same layout returned by
/// `find_match`. With length <= 258 and distance <= 32768, every token is a
/// non-negative Int below 2^25 on every backend. Unlike enum payloads, this
/// scalar representation does not allocate once per input token.
#inline
fn pack_match_token(length : Int, distance : Int) -> Int {
  (length << 16) | distance
}

///|
/// Record one match token starting at byte `start` with the given `length` and
/// `distance`: push the packed token, tally its literal/length and distance
/// symbols, and fill the hash chain over the match's interior bytes so later
/// positions may match inside it. Returns the position one past the match.
#inline
fn commit_match(
  data : Bytes,
  finder : MatchFinder,
  n : Int,
  start : Int,
  length : Int,
  dist : Int,
  tokens : Array[Int],
  ll_freq : FixedArray[Int],
  d_freq : FixedArray[Int],
) -> Int {
  tokens.push(pack_match_token(length, dist))
  ll_freq[257 + len_to_idx[length]] += 1
  d_freq[dist_index(dist)] += 1
  let match_end = start + length
  insert_positions(data, finder, start + 1, match_end, n)
  match_end
}

///|
#inline
fn commit_window_match(
  data : FixedArray[Byte],
  finder : MatchFinder,
  end : Int,
  start : Int,
  length : Int,
  dist : Int,
  tokens : Array[Int],
  ll_freq : FixedArray[Int],
  d_freq : FixedArray[Int],
) -> Int {
  tokens.push(pack_match_token(length, dist))
  ll_freq[257 + len_to_idx[length]] += 1
  d_freq[dist_index(dist)] += 1
  let match_end = start + length
  insert_window_positions(data, finder, start + 1, match_end, end)
  match_end
}

///|
/// Record one literal token: push its byte value and tally its symbol.
#inline
fn emit_literal(
  tokens : Array[Int],
  ll_freq : FixedArray[Int],
  b : Int,
) -> Unit {
  tokens.push(b)
  ll_freq[b] += 1
}

///|
/// LZ77 over `data[start:end)` with the given level's search tuning. Appends to
/// the caller-owned `tokens`, increments the caller-owned literal/length and
/// distance frequency tables (sized 286 / 30, end-of-block not yet counted),
/// and returns the absolute position one past the last byte consumed (≥ `end`
/// when a match straddled the boundary). Callers pass fresh, zeroed outputs.
///
/// `finder` persists for the whole compression session, so prior blocks are
/// already chained when this call begins. Matches may extend past `end` into
/// any lookahead present in `data`.
fn tokenize(
  data : Bytes,
  finder : MatchFinder,
  start : Int,
  end : Int,
  cfg : LevelConfig,
  tokens : Array[Int],
  ll_freq : FixedArray[Int],
  d_freq : FixedArray[Int],
) -> Int {
  let n = data.length()
  // LZ77 with hash chains: head[hash] is the most recent position with a
  // given 3-byte hash, prev[pos] the next-older. "Lazy" means a match found
  // at i is held back to see if i+1 starts a longer one.
  let mut i = start
  let mut prev_len = 0
  let mut prev_dist = 0
  let mut have_prev = false // a match found at i-1 is pending a decision
  while i < end {
    // Skip the search when the deferred match is already >= max_lazy: it is
    // good enough to commit without looking for a longer one (zlib).
    let searching = i + 3 <= n && !(have_prev && prev_len >= cfg.max_lazy)
    let base = if have_prev { prev_len } else { 0 }
    let match_info = if searching {
      find_match(data, finder, i, n, base, cfg)
    } else {
      0
    }
    let cur_len = match_info >> 16
    let cur_dist = match_info & 0xFFFF
    // The deferred match (starting at i-1) wins: emit it.
    guard !have_prev || cur_dist > 0 else {
      i = commit_match(
        data,
        finder,
        n,
        i - 1,
        prev_len,
        prev_dist,
        tokens,
        ll_freq,
        d_freq,
      )
      have_prev = false
      continue
    }
    // A deferred commit inserts i as an interior position. Insert it here
    // only when that commit did not happen, so prev never links to itself.
    insert_pos(data, finder, i, n)
    // A longer match starts at i: emit a literal for i-1, keep deferring.
    guard !have_prev else {
      emit_literal(tokens, ll_freq, data[i - 1].to_int())
      prev_len = cur_len
      prev_dist = cur_dist
      i = i + 1
      continue
    }
    // No match at i: literal.
    guard cur_dist > 0 && cur_len >= 3 else {
      emit_literal(tokens, ll_freq, data[i].to_int())
      i = i + 1
      continue
    }
    // Greedy levels (1-3): commit the match immediately.
    guard cfg.max_lazy > 0 else {
      i = commit_match(
        data, finder, n, i, cur_len, cur_dist, tokens, ll_freq, d_freq,
      )
      continue
    }
    // Lazy levels: hold this match back to see if i+1 starts a longer one.
    prev_len = cur_len
    prev_dist = cur_dist
    have_prev = true
    i = i + 1
  }
  if have_prev {
    // A still-pending match at the boundary commits here.
    i = commit_match(
      data,
      finder,
      n,
      i - 1,
      prev_len,
      prev_dist,
      tokens,
      ll_freq,
      d_freq,
    )
  }
  i
}

///|
// Streaming counterpart of `tokenize`: positions are absolute within the
// mirrored input ring, but the parse policy and token accounting are exactly
// the same as the one-shot path above.
fn tokenize_window(
  data : FixedArray[Byte],
  finder : MatchFinder,
  start : Int,
  token_end : Int,
  available_end : Int,
  cfg : LevelConfig,
  tokens : Array[Int],
  ll_freq : FixedArray[Int],
  d_freq : FixedArray[Int],
) -> Int {
  let mut i = start
  let mut prev_len = 0
  let mut prev_dist = 0
  let mut have_prev = false
  while i < token_end {
    let searching = i + 3 <= available_end &&
      !(have_prev && prev_len >= cfg.max_lazy)
    let base = if have_prev { prev_len } else { 0 }
    let match_info = if searching {
      find_window_match(data, finder, i, available_end, base, cfg)
    } else {
      0
    }
    let cur_len = match_info >> 16
    let cur_dist = match_info & 0xFFFF
    guard !have_prev || cur_dist > 0 else {
      i = commit_window_match(
        data,
        finder,
        available_end,
        i - 1,
        prev_len,
        prev_dist,
        tokens,
        ll_freq,
        d_freq,
      )
      have_prev = false
      continue
    }
    // The deferred commit above already inserts its interior positions.
    insert_window_pos(data, finder, i, available_end)
    guard !have_prev else {
      emit_literal(tokens, ll_freq, data[(i - 1) & STREAM_RING_MASK].to_int())
      prev_len = cur_len
      prev_dist = cur_dist
      i = i + 1
      continue
    }
    guard cur_dist > 0 && cur_len >= 3 else {
      emit_literal(tokens, ll_freq, data[i & STREAM_RING_MASK].to_int())
      i = i + 1
      continue
    }
    guard cfg.max_lazy > 0 else {
      i = commit_window_match(
        data, finder, available_end, i, cur_len, cur_dist, tokens, ll_freq, d_freq,
      )
      continue
    }
    prev_len = cur_len
    prev_dist = cur_dist
    have_prev = true
    i = i + 1
  }
  if have_prev {
    i = commit_window_match(
      data,
      finder,
      available_end,
      i - 1,
      prev_len,
      prev_dist,
      tokens,
      ll_freq,
      d_freq,
    )
  }
  i
}
