// LZ77 parsing stage of the encode pipeline: bytes in, tokens (literals and
// length/distance matches) plus symbol frequencies out. In modern terms,
// `tokenize` bundles the match finder (3-byte heads and 4-byte hash chains), the parsing
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
/// Per-level baseline search tuning, adopted from zlib's configuration table.
/// The default level uses the distance-aware parser below; its initial and
/// lookahead search budgets are separate. Levels 1-3 are greedy, expressed as
/// `max_lazy = 0`. Level 0 (stored only) is special-cased in the block
/// planner and never searches.
#valtype
priv struct LevelConfig {
  good_length : Int // shrink the chain budget once a match this long is held
  max_lazy : Int // 0 = greedy (commit immediately); else defer while best < this
  nice_length : Int // stop searching outright at this match length
  max_chain : Int // candidate positions examined per search
} derive(Eq)

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
fn hash3_window(data : FixedArray[Byte], i : Int, shift? : Int = 9) -> Int {
  let offset = i & STREAM_RING_MASK
  let triple = (data[offset].to_int() |
  (data[offset + 1].to_int() << 8) |
  (data[offset + 2].to_int() << 16)).reinterpret_as_uint()
  short_hash_product(triple * 0x1E35A7BDU, shift~)
}

///|
// The fourth input byte contributes only above bit 23 of the wrapping
// product. Its lower 24 bits therefore hash the three-byte prefix too.
#inline
fn short_hash_product(product : UInt, shift? : Int = 9) -> Int {
  ((product & 0xFFFFFF) >> shift).reinterpret_as_int()
}

///|
fn short_hash3(data : Bytes, position : Int, shift? : Int = 9) -> Int {
  let triple = (data[position].to_int() |
  (data[position + 1].to_int() << 8) |
  (data[position + 2].to_int() << 16)).reinterpret_as_uint()
  short_hash_product(triple * 0x1E35A7BDU, shift~)
}

///|
const LONG_HASH_BITS : Int = 16

///|
#inline
fn long_hash_product(product : UInt, shift? : Int = 16) -> Int {
  (product >> shift).reinterpret_as_int()
}

///|
#inline
fn read_match_word(data : Bytes, position : Int) -> UInt {
  // SAFETY: insertion proves four bytes remain. Search clamps probe below
  // limit <= n - i and only visits earlier candidates, so prefix and suffix
  // words both stay inside the input, including its final four-byte tail.
  data.unsafe_read_uint32_le(position)
}

///|
#cfg(not(any(target="native", target="wasm")))
#inline
fn read_window_match_word(data : FixedArray[Byte], position : Int) -> UInt {
  let offset = position & STREAM_RING_MASK
  (data[offset].to_int() |
  (data[offset + 1].to_int() << 8) |
  (data[offset + 2].to_int() << 16) |
  (data[offset + 3].to_int() << 24)).reinterpret_as_uint()
}

///|
// The mirrored byte array and Bytes use the same backing layout on these
// backends. This borrowed view never escapes the immediate read below.
#cfg(any(target="native", target="wasm"))
fn match_window_as_bytes(data : FixedArray[Byte]) -> Bytes = "%identity"

///|
#cfg(any(target="native", target="wasm"))
#inline
fn read_window_match_word(data : FixedArray[Byte], position : Int) -> UInt {
  // SAFETY: masking selects the first half of the mirrored ring, leaving
  // at least four bytes of storage even when the read crosses the wrap.
  match_window_as_bytes(data).unsafe_read_uint32_le(position & STREAM_RING_MASK)
}

///|
// As in libdeflate's hc_matchfinder, short matches use a single recent
// 3-byte candidate; the chain is reserved for matches of at least 4 bytes.
// Heads contain stream-stamped positions; predecessors remain stream-relative.
// The predecessor ring stores saturated 16-bit backward distances across the
// full 32 KiB window. Distances survive stream rebasing without adjustment.
priv struct MatchFinder {
  mut min_match_length : Int
  mut position_base : Int
  mut next_base : Int
  mut short_shift : Int
  mut long_shift : Int
  mut short_head : FixedArray[Int]
  mut head : FixedArray[Int]
  prev : FixedArray[Byte]
}

///|
fn MatchFinder::MatchFinder(input_size? : Int = WINDOW_SIZE) -> MatchFinder {
  let short_size = match_table_capacity(
    input_size.min(16384) * 2,
    1 << HASH_BITS,
  )
  let long_size = match_table_capacity(
    input_size.min(16384) * 4,
    1 << LONG_HASH_BITS,
  )
  {
    min_match_length: 0,
    position_base: 0,
    next_base: 0,
    short_shift: 24 - short_size.ctz(),
    long_shift: 32 - long_size.ctz(),
    short_head: FixedArray::make(short_size, -1),
    head: FixedArray::make(long_size, -1),
    prev: FixedArray::make(WINDOW_SIZE * 2 + 2, b'\xFF'),
  }
}

///|
fn match_table_capacity(requested : Int, maximum : Int) -> Int {
  for capacity = 256 {
    guard capacity < requested && capacity < maximum else { break capacity }
    continue capacity * 2
  }
}

///|
// Logical size depends only on this input, even when larger backing tables
// are retained from an earlier stream. Cold and reused codecs choose the same
// candidates; allocations grow only when a larger input first needs them.
fn MatchFinder::size_for_input(self : MatchFinder, input_size : Int) -> Unit {
  let short_size = match_table_capacity(
    input_size.min(16384) * 2,
    1 << HASH_BITS,
  )
  let long_size = match_table_capacity(
    input_size.min(16384) * 4,
    1 << LONG_HASH_BITS,
  )
  if self.short_head.length() < short_size {
    self.short_head = FixedArray::make(short_size, -1)
  }
  if self.head.length() < long_size {
    self.head = FixedArray::make(long_size, -1)
  }
  self.short_shift = 24 - short_size.ctz()
  self.long_shift = 32 - long_size.ctz()
}

///|
fn MatchFinder::reset(self : MatchFinder) -> Unit {
  self.min_match_length = 0
  self.position_base = 0
  self.next_base = 0
  self.short_head.fill(-1)
  self.head.fill(-1)
  self.prev.fill(b'\xFF')
}

///|
// A streaming encoder knows the previous stream's accepted span at reset.
// Keep a half-GiB base ceiling: the encoder rebases its relative positions
// after one GiB, leaving ample Int headroom for a pending ring and lookahead.
fn MatchFinder::reset_stream(self : MatchFinder, previous_size : Int) -> Unit {
  self.min_match_length = 0
  let next = self.position_base + previous_size
  guard next < 1 << 29 else {
    self.reset()
    return
  }
  self.position_base = next
  self.next_base = next + (1 << 30) + STREAM_RING_SIZE
}

///|
// Head positions carry a monotonically increasing stream base. Old heads
// decode to negative positions and are rejected without clearing either table.
// Predecessor distances are overwritten before their head becomes
// reachable. Reset before Int overflow; empty inputs cannot publish a head.
fn MatchFinder::reset_for_input(self : MatchFinder, input : Bytes) -> Unit {
  self.min_match_length = 0
  self.size_for_input(input.length())
  if input.length() > 2147483647 - self.next_base {
    self.short_head.fill(-1)
    self.head.fill(-1)
    self.next_base = 0
  }
  self.position_base = self.next_base
  self.next_base += input.length()
}

///|
fn MatchFinder::rebase(self : MatchFinder, offset : Int) -> Unit {
  for table in [self.short_head, self.head] {
    for i in 0..<table.length() {
      if table[i] >= 0 {
        table[i] = table[i] - offset
      }
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
/// Find a recent length-3 match, then search the independent 4-byte chain.
/// Keep the existing per-level budget and nice/good/lazy tuning unchanged.
fn find_match_hashed(
  data : Bytes,
  finder : MatchFinder,
  i : Int,
  n : Int,
  base : Int,
  cfg : LevelConfig,
  prefix : UInt,
  product : UInt,
) -> Int {
  let limit = (n - i).min(258)
  guard base < limit else { return base << 16 }
  let mut budget = if base >= cfg.good_length {
    cfg.max_chain >> 2
  } else {
    cfg.max_chain
  }
  guard budget > 0 else { return base << 16 }
  let cutoff = (i - WINDOW_SIZE).max(0)
  let mut best_len = base
  let mut best_dist = 0
  if base < 3 {
    let short_hash = short_hash_product(product, shift=finder.short_shift)
    let short = finder.short_head.unsafe_get(short_hash) - finder.position_base
    // Every long-chain insertion also updates this short head. If even
    // the newest short-hash candidate expired, no four-byte match can exist.
    guard short >= cutoff else { return base << 16 }
    if (read_match_word(data, short) & 0xFFFFFF) == (prefix & 0xFFFFFF) {
      best_len = 3
      best_dist = i - short
    }
  }
  let mut cand = finder.head.unsafe_get(
      long_hash_product(product, shift=finder.long_shift),
    ) -
    finder.position_base
  guard cand >= cutoff else { return (best_len << 16) | best_dist }
  let prev = finder.prev
  let mut probe = best_len.max(3)
  let mut suffix = read_match_word(data, i + probe - 3)
  let nice_length = cfg.nice_length.min(limit)
  for ;; {
    for ;; {
      let candidate_suffix = read_match_word(data, cand + probe - 3)
      if candidate_suffix == suffix && read_match_word(data, cand) == prefix {
        break
      }
      budget -= 1
      cand = chain_previous(prev, cand)
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
      suffix = read_match_word(data, i + probe - 3)
    }
    budget -= 1
    cand = chain_previous(prev, cand)
    guard budget > 0 && cand >= cutoff else { break }
  }
  (best_len << 16) | best_dist
}

///|
fn find_match(
  data : Bytes,
  finder : MatchFinder,
  i : Int,
  n : Int,
  base : Int,
  cfg : LevelConfig,
) -> Int {
  let limit = (n - i).min(258)
  if limit < 4 {
    let budget = if base >= cfg.good_length {
      cfg.max_chain >> 2
    } else {
      cfg.max_chain
    }
    guard base < limit && budget > 0 else { return base << 16 }
    let cutoff = (i - WINDOW_SIZE).max(0)
    let short = finder.short_head.unsafe_get(
        short_hash3(data, i, shift=finder.short_shift),
      ) -
      finder.position_base
    if base < 3 && short >= cutoff {
      if data[short] == data[i] &&
        data[short + 1] == data[i + 1] &&
        data[short + 2] == data[i + 2] {
        return (3 << 16) | (i - short)
      }
    }
    return base << 16
  }
  let prefix = read_match_word(data, i)
  let product = prefix * 0x1E35A7BDU
  find_match_hashed(data, finder, i, n, base, cfg, prefix, product)
}

///|
/// Find a recent length-3 match, then search the independent 4-byte chain.
/// Keep the existing per-level budget and nice/good/lazy tuning unchanged.
fn find_window_match_hashed(
  data : FixedArray[Byte],
  finder : MatchFinder,
  i : Int,
  end : Int,
  base : Int,
  cfg : LevelConfig,
  prefix : UInt,
  product : UInt,
) -> Int {
  let limit = (end - i).min(258)
  guard base < limit else { return base << 16 }
  let mut budget = if base >= cfg.good_length {
    cfg.max_chain >> 2
  } else {
    cfg.max_chain
  }
  guard budget > 0 else { return base << 16 }
  let cutoff = (i - WINDOW_SIZE).max(0)
  let mut best_len = base
  let mut best_dist = 0
  if base < 3 {
    let short_hash = short_hash_product(product, shift=finder.short_shift)
    let short = finder.short_head.unsafe_get(short_hash) - finder.position_base
    // Every long-chain insertion also updates this short head. If even
    // the newest short-hash candidate expired, no four-byte match can exist.
    guard short >= cutoff else { return base << 16 }
    if (read_window_match_word(data, short) & 0xFFFFFF) == (prefix & 0xFFFFFF) {
      best_len = 3
      best_dist = i - short
    }
  }
  let mut cand = finder.head.unsafe_get(
      long_hash_product(product, shift=finder.long_shift),
    ) -
    finder.position_base
  guard cand >= cutoff else { return (best_len << 16) | best_dist }
  let prev = finder.prev
  let mut probe = best_len.max(3)
  let mut suffix = read_window_match_word(data, i + probe - 3)
  let nice_length = cfg.nice_length.min(limit)
  for ;; {
    for ;; {
      let candidate_suffix = read_window_match_word(data, cand + probe - 3)
      if candidate_suffix == suffix &&
        read_window_match_word(data, cand) == prefix {
        break
      }
      budget -= 1
      cand = chain_previous(prev, cand)
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
      suffix = read_window_match_word(data, i + probe - 3)
    }
    budget -= 1
    cand = chain_previous(prev, cand)
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
  let limit = (end - i).min(258)
  if limit < 4 {
    let budget = if base >= cfg.good_length {
      cfg.max_chain >> 2
    } else {
      cfg.max_chain
    }
    guard base < limit && budget > 0 else { return base << 16 }
    let cutoff = (i - WINDOW_SIZE).max(0)
    let short = finder.short_head.unsafe_get(
        hash3_window(data, i, shift=finder.short_shift),
      ) -
      finder.position_base
    if base < 3 && short >= cutoff {
      let candidate = short & STREAM_RING_MASK
      let position = i & STREAM_RING_MASK
      if data[candidate] == data[position] &&
        data[candidate + 1] == data[position + 1] &&
        data[candidate + 2] == data[position + 2] {
        return (3 << 16) | (i - short)
      }
    }
    return base << 16
  }
  let prefix = read_window_match_word(data, i)
  let product = prefix * 0x1E35A7BDU
  find_window_match_hashed(data, finder, i, end, base, cfg, prefix, product)
}

///|
fn insert_pos_hashed(finder : MatchFinder, i : Int, product : UInt) -> Unit {
  let h = long_hash_product(product, shift=finder.long_shift)
  let stamped = i + finder.position_base
  finder.short_head.unsafe_set(
    short_hash_product(product, shift=finder.short_shift),
    stamped,
  )
  set_chain_previous(
    finder.prev,
    i,
    finder.head.unsafe_get(h) - finder.position_base,
  )
  finder.head.unsafe_set(h, stamped)
}

///|
fn insert_pos(data : Bytes, finder : MatchFinder, i : Int, n : Int) -> Unit {
  if n - i >= 4 {
    insert_pos_hashed(finder, i, read_match_word(data, i) * 0x1E35A7BDU)
  } else if n - i >= 3 {
    finder.short_head.unsafe_set(
      short_hash3(data, i, shift=finder.short_shift),
      i + finder.position_base,
    )
  }
}

///|
// One packed load and multiplication feed both hash tables. The loop proves
// four available bytes. Masked indices address the private fixed-size tables.
fn insert_positions(
  data : Bytes,
  finder : MatchFinder,
  start : Int,
  end : Int,
  available_end : Int,
) -> Unit {
  let end = end.min(available_end - 2)
  guard start < end else { return }
  let long_end = end.min(available_end - 3)
  let head = finder.head
  let short_head = finder.short_head
  let prev = finder.prev
  let base = finder.position_base
  let short_shift = finder.short_shift
  let long_shift = finder.long_shift
  for position in start..<long_end {
    let product = read_match_word(data, position) * 0x1E35A7BDU
    let h = long_hash_product(product, shift=long_shift)
    let stamped = position + base
    short_head.unsafe_set(
      short_hash_product(product, shift=short_shift),
      stamped,
    )
    set_chain_previous(prev, position, head.unsafe_get(h) - base)
    head.unsafe_set(h, stamped)
  }
  if long_end < end {
    insert_pos(data, finder, long_end, available_end)
  }
}

///|
fn insert_window_pos_hashed(
  finder : MatchFinder,
  i : Int,
  product : UInt,
) -> Unit {
  let h = long_hash_product(product, shift=finder.long_shift)
  let stamped = i + finder.position_base
  finder.short_head.unsafe_set(
    short_hash_product(product, shift=finder.short_shift),
    stamped,
  )
  set_chain_previous(
    finder.prev,
    i,
    finder.head.unsafe_get(h) - finder.position_base,
  )
  finder.head.unsafe_set(h, stamped)
}

///|
fn insert_window_pos(
  data : FixedArray[Byte],
  finder : MatchFinder,
  i : Int,
  n : Int,
) -> Unit {
  if n - i >= 4 {
    insert_window_pos_hashed(
      finder,
      i,
      read_window_match_word(data, i) * 0x1E35A7BDU,
    )
  } else if n - i >= 3 {
    finder.short_head.unsafe_set(
      hash3_window(data, i, shift=finder.short_shift),
      i + finder.position_base,
    )
  }
}

///|
// One packed load and multiplication feed both hash tables. The loop proves
// four available bytes. Masked indices address the private fixed-size tables.
fn insert_window_positions(
  data : FixedArray[Byte],
  finder : MatchFinder,
  start : Int,
  end : Int,
  available_end : Int,
) -> Unit {
  let end = end.min(available_end - 2)
  guard start < end else { return }
  let long_end = end.min(available_end - 3)
  let head = finder.head
  let short_head = finder.short_head
  let prev = finder.prev
  let base = finder.position_base
  let short_shift = finder.short_shift
  let long_shift = finder.long_shift
  for position in start..<long_end {
    let product = read_window_match_word(data, position) * 0x1E35A7BDU
    let h = long_hash_product(product, shift=long_shift)
    let stamped = position + base
    short_head.unsafe_set(
      short_hash_product(product, shift=short_shift),
      stamped,
    )
    set_chain_previous(prev, position, head.unsafe_get(h) - base)
    head.unsafe_set(h, stamped)
  }
  if long_end < end {
    insert_window_pos(data, finder, long_end, available_end)
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
  if length >= 32 {
    insert_matched_positions(data, finder, start + 1, match_end, n)
  } else {
    insert_positions(data, finder, start + 1, match_end, n)
  }
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
  if length >= 32 {
    insert_matched_window_positions(data, finder, start + 1, match_end, end)
  } else {
    insert_window_positions(data, finder, start + 1, match_end, end)
  }
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
  // The default level uses a distance-aware lazy decision. Other levels
  // retain their existing search policy and budgets.
  // Tiny blocks have too little evidence for the sampled literal-cost model.
  let cost_model = cfg == level_configs[6] &&
    (finder.min_match_length > 0 || n - start >= 1024)
  if cost_model && finder.min_match_length == 0 && n - start >= 512 {
    let used = FixedArray::make(256, 0)
    for j in start..<(start + 4096).min(n) {
      used[data[j].to_int()] = 1
    }
    let mut distinct = 0
    for j in 0..<256 {
      distinct += used[j]
    }
    finder.min_match_length = minimum_match_length(distinct)
  }
  let min_length = if cost_model { finder.min_match_length.max(3) } else { 3 }
  let max_lazy = if cost_model { 65 } else { cfg.max_lazy }
  // A broad byte alphabet makes long hash chains mostly collision probes;
  // cap their work aggressively while retaining a larger budget for text.
  let chain_budget = if min_length >= 5 {
    17
  } else if min_length >= 4 {
    24
  } else {
    8
  }
  let chain_budget_after_prev = if min_length >= 5 {
    8
  } else if min_length >= 4 {
    12
  } else {
    4
  }
  let cost_cfg = {
    good_length: 259,
    max_lazy: 65,
    nice_length: 65,
    max_chain: chain_budget,
  }
  let cost_cfg_after_prev = {
    good_length: 259,
    max_lazy: 65,
    nice_length: 65,
    max_chain: chain_budget_after_prev,
  }
  // LZ77 with hash chains: head[hash] is the most recent position with a
  // given 4-byte hash, prev[pos] the next-older. "Lazy" means a match found
  // at i is held back to see if i+1 starts a longer one.
  let mut i = start
  let mut prev_len = 0
  let mut prev_dist = 0
  let mut have_prev = false // a match found at i-1 is pending a decision
  while i < end {
    // The current position is searched and inserted in the same iteration.
    // Carry its packed word/hash across both operations so incompressible
    // input pays for one load and multiply instead of two.
    let has_word = i + 4 <= n
    let mut prefix = 0U
    let mut product = 0U
    if has_word {
      prefix = read_match_word(data, i)
      product = prefix * 0x1E35A7BDU
    }
    // Skip the search when the deferred match is already >= max_lazy: it is
    // good enough to commit without looking for a longer one (zlib).
    let searching = i + 3 <= n && !(have_prev && prev_len >= max_lazy)
    let base = if have_prev {
      prev_len - (if cost_model { 1 } else { 0 })
    } else {
      min_length - 1
    }
    let search_cfg = if cost_model {
      if have_prev {
        cost_cfg_after_prev
      } else {
        cost_cfg
      }
    } else {
      cfg
    }
    let match_info = if searching {
      if has_word {
        find_match_hashed(data, finder, i, n, base, search_cfg, prefix, product)
      } else {
        find_match(data, finder, i, n, base, search_cfg)
      }
    } else {
      0
    }
    let cur_len = match_info >> 16
    let cur_dist = match_info & 0xFFFF
    // The deferred match (starting at i-1) wins: emit it.
    let prefer_current = cur_dist > 0 &&
      (
        !cost_model ||
        (
          cur_len >= prev_len &&
          4 * (cur_len - prev_len) + cur_dist.clz() - prev_dist.clz() > 2
        )
      )
    guard !have_prev || prefer_current else {
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
    if has_word {
      insert_pos_hashed(finder, i, product)
    } else {
      insert_pos(data, finder, i, n)
    }
    // A longer match starts at i: emit a literal for i-1, keep deferring.
    guard !have_prev else {
      emit_literal(tokens, ll_freq, data[i - 1].to_int())
      prev_len = cur_len
      prev_dist = cur_dist
      i = i + 1
      continue
    }
    // No match at i: literal.
    guard cur_dist > 0 &&
      cur_len >= min_length &&
      !(cost_model && cur_len == 3 && cur_dist > 8192) else {
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
  // The default level uses a distance-aware lazy decision. Other levels
  // retain their existing search policy and budgets.
  let cost_model = cfg == level_configs[6] &&
    (finder.min_match_length > 0 || available_end - start >= 1024)
  if cost_model && finder.min_match_length == 0 && available_end - start >= 512 {
    let used = FixedArray::make(256, 0)
    for j in start..<(start + 4096).min(available_end) {
      used[data[j & STREAM_RING_MASK].to_int()] = 1
    }
    let mut distinct = 0
    for j in 0..<256 {
      distinct += used[j]
    }
    finder.min_match_length = minimum_match_length(distinct)
  }
  let min_length = if cost_model { finder.min_match_length.max(3) } else { 3 }
  let max_lazy = if cost_model { 65 } else { cfg.max_lazy }
  // Match the whole-buffer parser's collision budget in the ring path.
  let chain_budget = if min_length >= 5 {
    17
  } else if min_length >= 4 {
    24
  } else {
    8
  }
  let chain_budget_after_prev = if min_length >= 5 {
    8
  } else if min_length >= 4 {
    12
  } else {
    4
  }
  let cost_cfg = {
    good_length: 259,
    max_lazy: 65,
    nice_length: 65,
    max_chain: chain_budget,
  }
  let cost_cfg_after_prev = {
    good_length: 259,
    max_lazy: 65,
    nice_length: 65,
    max_chain: chain_budget_after_prev,
  }
  let mut i = start
  let mut prev_len = 0
  let mut prev_dist = 0
  let mut have_prev = false
  while i < token_end {
    // Reuse the current four-byte hash between the match probe and insertion.
    let has_word = i + 4 <= available_end
    let mut prefix = 0U
    let mut product = 0U
    if has_word {
      prefix = read_window_match_word(data, i)
      product = prefix * 0x1E35A7BDU
    }
    let searching = i + 3 <= available_end &&
      !(have_prev && prev_len >= max_lazy)
    let base = if have_prev {
      prev_len - (if cost_model { 1 } else { 0 })
    } else {
      min_length - 1
    }
    let search_cfg = if cost_model {
      if have_prev {
        cost_cfg_after_prev
      } else {
        cost_cfg
      }
    } else {
      cfg
    }
    let match_info = if searching {
      if has_word {
        find_window_match_hashed(
          data, finder, i, available_end, base, search_cfg, prefix, product,
        )
      } else {
        find_window_match(data, finder, i, available_end, base, search_cfg)
      }
    } else {
      0
    }
    let cur_len = match_info >> 16
    let cur_dist = match_info & 0xFFFF
    let prefer_current = cur_dist > 0 &&
      (
        !cost_model ||
        (
          cur_len >= prev_len &&
          4 * (cur_len - prev_len) + cur_dist.clz() - prev_dist.clz() > 2
        )
      )
    guard !have_prev || prefer_current else {
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
    if has_word {
      insert_window_pos_hashed(finder, i, product)
    } else {
      insert_window_pos(data, finder, i, available_end)
    }
    guard !have_prev else {
      emit_literal(tokens, ll_freq, data[(i - 1) & STREAM_RING_MASK].to_int())
      prev_len = cur_len
      prev_dist = cur_dist
      i = i + 1
      continue
    }
    guard cur_dist > 0 &&
      cur_len >= min_length &&
      !(cost_model && cur_len == 3 && cur_dist > 8192) else {
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

///|
#inline
fn set_chain_previous(
  chain : FixedArray[Byte],
  position : Int,
  previous : Int,
) -> Unit {
  // Every reachable predecessor is older. Saturate expired links to a
  // distance beyond the window, which also fits in an unsigned 16-bit slot.
  let delta = (position - previous).min(WINDOW_SIZE + 1)
  let index = (position & WINDOW_MASK) * 2
  chain.unsafe_set(index, delta.to_byte())
  chain.unsafe_set(index + 1, (delta >> 8).to_byte())
}

///|
#cfg(any(target="native", target="wasm"))
#inline
fn chain_previous(chain : FixedArray[Byte], position : Int) -> Int {
  let index = (position & WINDOW_MASK) * 2
  // The ring has two padding bytes for the final unaligned four-byte load;
  // only the low halfword belongs to this link.
  let delta = match_window_as_bytes(chain).unsafe_read_uint32_le(index) & 0xFFFF
  position - delta.reinterpret_as_int()
}

///|
#cfg(not(any(target="native", target="wasm")))
#inline
fn chain_previous(chain : FixedArray[Byte], position : Int) -> Int {
  let index = (position & WINDOW_MASK) * 2
  let delta = chain.unsafe_get(index).to_int() |
    (chain.unsafe_get(index + 1).to_int() << 8)
  position - delta
}

///|
// Each complete four-byte word inside the match already occurs within the
// live window, so its predecessor distance needs no saturation. The final
// three positions may cross the match boundary and use general insertion.
// Callers have already proved a match length of at least 32 bytes.
fn insert_matched_positions(
  data : Bytes,
  finder : MatchFinder,
  start : Int,
  end : Int,
  available_end : Int,
) -> Unit {
  let end = end.min(available_end - 2)
  let long_end = (end - 3).min(available_end - 3)
  let head = finder.head
  let short_head = finder.short_head
  let prev = finder.prev
  let base = finder.position_base
  let short_shift = finder.short_shift
  let long_shift = finder.long_shift
  for position in start..<long_end {
    let product = read_match_word(data, position) * 0x1E35A7BDU
    let h = long_hash_product(product, shift=long_shift)
    let stamped = position + base
    short_head.unsafe_set(
      short_hash_product(product, shift=short_shift),
      stamped,
    )
    let delta = stamped - head.unsafe_get(h)
    let index = (position & WINDOW_MASK) * 2
    prev.unsafe_set(index, delta.to_byte())
    prev.unsafe_set(index + 1, (delta >> 8).to_byte())
    head.unsafe_set(h, stamped)
  }
  insert_positions(data, finder, long_end, end, available_end)
}

///|
fn insert_matched_window_positions(
  data : FixedArray[Byte],
  finder : MatchFinder,
  start : Int,
  end : Int,
  available_end : Int,
) -> Unit {
  let end = end.min(available_end - 2)
  let long_end = (end - 3).min(available_end - 3)
  let head = finder.head
  let short_head = finder.short_head
  let prev = finder.prev
  let base = finder.position_base
  let short_shift = finder.short_shift
  let long_shift = finder.long_shift
  for position in start..<long_end {
    let product = read_window_match_word(data, position) * 0x1E35A7BDU
    let h = long_hash_product(product, shift=long_shift)
    let stamped = position + base
    short_head.unsafe_set(
      short_hash_product(product, shift=short_shift),
      stamped,
    )
    let delta = stamped - head.unsafe_get(h)
    let index = (position & WINDOW_MASK) * 2
    prev.unsafe_set(index, delta.to_byte())
    prev.unsafe_set(index + 1, (delta >> 8).to_byte())
    head.unsafe_set(h, stamped)
  }
  insert_window_positions(data, finder, long_end, end, available_end)
}

///|
// Fewer distinct literals mean cheaper literal codes, making short matches
// less attractive. Sample once after at least 512 input bytes are available.
fn minimum_match_length(distinct : Int) -> Int {
  match () {
    _ if distinct >= 80 => 3
    _ if distinct >= 45 => 4
    _ if distinct >= 16 => 5
    _ if distinct >= 10 => 6
    _ if distinct >= 8 => 7
    _ if distinct >= 6 => 8
    _ => 9
  }
}
