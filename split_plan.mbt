// Content-driven block planning (libdeflate's observation-divergence split,
// as adopted by lean-zip): the drop-in counterpart to the fixed 16 KB
// threshold planner for the one-shot `deflate_all`. A large window is
// tokenized once with the full 32 KB history, then the token stream is
// partitioned where the literal/match observation distribution drifts —
// each segment becomes one dynamic-Huffman block, so trees track local
// statistics instead of a fixed cadence. Emits through the ordinary
// `emit_block`, so the writer is untouched and output stays standard DEFLATE.

///|
/// Master chunk size for the splitter: the whole chunk is tokenized at once,
/// then partitioned. Bounds the planner's working memory exactly like the
/// optimal planner's `OPTIMAL_MASTER_BLOCK`.
const SPLIT_MASTER_CHUNK : Int = 65536

///|
/// Number of literal observation classes (libdeflate `NUM_LITERAL_OBSERVATION_TYPES`):
/// literals are bucketed by bits 7,6,0 — a cheap proxy separating
/// case/digit/punctuation regimes.
const SPLIT_NUM_LITERAL_CLASSES : Int = 8

///|
/// Total observation classes: 8 literal classes plus 2 match classes (short/long).
const SPLIT_NUM_CLASSES : Int = 10

///|
/// New observations between divergence checks (libdeflate `NUM_OBSERVATIONS_PER_BLOCK_CHECK`).
const SPLIT_CHECK_TOKENS : Int = 512

///|
/// Floor on block output bytes (libdeflate `MIN_BLOCK_LENGTH`): per-block tree
/// headers stop paying for themselves below this.
const SPLIT_MIN_BLOCK_BYTES : Int = 10000

///|
/// Unconditional cut ceiling on block output bytes (libdeflate `SOFT_MAX_BLOCK_LENGTH`).
const SPLIT_SOFT_MAX_BLOCK_BYTES : Int = 300000

///|
/// Divergence threshold numerator/denominator (libdeflate's 200/512): cut when
/// the sum of absolute probability deltas reaches ~39%.
const SPLIT_CUTOFF_NUM : Int = 200

///|
const SPLIT_CUTOFF_DEN : Int = 512

///|
/// Length bias divisor (libdeflate's `block_length / 4096` term): longer blocks
/// cut progressively easier, since a fresh tree amortizes better.
const SPLIT_BIAS_BYTES : Int = 4096

///|
/// Observation class of a packed token: literals map to 0–7 by bits 7,6,0;
/// matches map to 8 (length < 9) or 9.
#inline
fn split_token_class(tok : Int) -> Int {
  // Branch-free form of: literals -> bits 7,6,0 (0..7); matches -> 8 + (len>=9).
  // `is_lit = (tok - 256) >> 31` is the arithmetic-shift mask: -1 (all ones)
  // for a literal, 0 for a match. The literal class is selected by `is_lit`,
  // the match class `8 + (len>=9)` (0 for a literal's len == 0, masked out) by
  // its complement, so no branch on the token kind.
  let lit = ((tok >> 5) & 6) | (tok & 1)
  let len = tok >> 16
  let is_lit = (tok - 256) >> 31
  let match_class = SPLIT_NUM_LITERAL_CLASSES + (1 - (((len - 9) >> 31) & 1))
  (lit & is_lit) | (match_class & (is_lit ^ -1))
}

///|
/// Output bytes a token contributes: 1 for a literal, the match length for a
/// reference.
#inline
fn split_token_bytes(tok : Int) -> Int {
  // Branch-free form of `if tok < 256 { 1 } else { tok >> 16 }`: the
  // `(is_lit ^ -1)` mask is 0 for a literal (yielding 1) and -1 for a match
  // (yielding `1 + (len - 1)`).
  let is_lit = (tok - 256) >> 31
  1 + ((is_lit ^ -1) & ((tok >> 16) - 1))
}

///|
/// The divergence test (libdeflate `do_end_block_check`): cut when the recent
/// window's class distribution differs from the block-so-far distribution by
/// at least ~39% probability mass (less for long blocks). Integer-only; the
/// caller guarantees `old_tot > 0`.
fn split_end_block_check(
  old : Array[Int],
  old_tot : Int,
  new : Array[Int],
  new_tot : Int,
  block_bytes : Int,
) -> Bool {
  let mut delta = 0
  for i in 0..<SPLIT_NUM_CLASSES {
    let a = new[i] * old_tot
    let b = old[i] * new_tot
    delta = delta + (if a >= b { a - b } else { b - a })
  }
  let cutoff = new_tot * SPLIT_CUTOFF_NUM / SPLIT_CUTOFF_DEN * old_tot
  delta + block_bytes / SPLIT_BIAS_BYTES * old_tot >= cutoff
}

///|
/// Entropy-divergence cut points for a packed token stream: one pass,
/// accumulating per-class observation counts. Block-so-far (`old`) and
/// recent-window (`new`) histograms are compared every `SPLIT_CHECK_TOKENS`
/// tokens once the block and the remaining input are both at least
/// `SPLIT_MIN_BLOCK_BYTES` output bytes; on divergence the block is cut at the
/// next token boundary, otherwise the window merges into `old`. Blocks are
/// force-cut at `SPLIT_SOFT_MAX_BLOCK_BYTES`. Returns token indices where the
/// following block begins (strictly increasing, within `[1, tokens.length()]`).
fn choose_splits(tokens : Array[Int]) -> Array[Int] {
  let mut total_bytes = 0
  for tok in tokens {
    total_bytes = total_bytes + split_token_bytes(tok)
  }
  let old = Array::make(SPLIT_NUM_CLASSES, 0)
  let mut old_tot = 0
  let new = Array::make(SPLIT_NUM_CLASSES, 0)
  let mut new_tot = 0
  let mut block_bytes = 0
  let mut done_bytes = 0
  let cuts : Array[Int] = []
  for i, tok in tokens {
    let c = split_token_class(tok)
    new[c] = new[c] + 1
    new_tot = new_tot + 1
    let tb = split_token_bytes(tok)
    block_bytes = block_bytes + tb
    done_bytes = done_bytes + tb
    if block_bytes >= SPLIT_MIN_BLOCK_BYTES &&
      total_bytes - done_bytes >= SPLIT_MIN_BLOCK_BYTES {
      let cut = block_bytes >= SPLIT_SOFT_MAX_BLOCK_BYTES ||
        (
          new_tot >= SPLIT_CHECK_TOKENS &&
          old_tot > 0 &&
          split_end_block_check(old, old_tot, new, new_tot, block_bytes)
        )
      if cut {
        cuts.push(i + 1)
        for j in 0..<SPLIT_NUM_CLASSES {
          old[j] = 0
          new[j] = 0
        }
        old_tot = 0
        new_tot = 0
        block_bytes = 0
      } else if new_tot >= SPLIT_CHECK_TOKENS {
        for j in 0..<SPLIT_NUM_CLASSES {
          old[j] = old[j] + new[j]
          new[j] = 0
        }
        old_tot = old_tot + new_tot
        new_tot = 0
      }
    }
  }
  cuts
}

///|
/// Token-boundary cuts approximating the fixed `DEFLATE_BLOCK_SIZE` cadence:
/// cut at the first token whose start offset reaches each 16 KB output-byte
/// multiple. Used as the arbitration baseline so the adaptive split can never
/// regress the fixed-cadence ratio.
fn fixed_cadence_cuts(
  tokens : Array[Int],
  all_pos : Array[Int],
  pos : Int,
) -> Array[Int] {
  let m = tokens.length()
  let cuts : Array[Int] = []
  let mut target = pos + DEFLATE_BLOCK_SIZE
  let mut k = 1
  while k < m {
    if all_pos[k] >= target {
      cuts.push(k)
      target = target + DEFLATE_BLOCK_SIZE
    }
    k = k + 1
  }
  cuts
}

///|
/// Exact bit cost of emitting `tokens` partitioned by `cuts`, judged by the
/// same accounting `emit_block` uses (`block_cost_bits`: the cheapest of
/// stored / fixed / dynamic, 3-bit header included). Mirrors the emitter's
/// grouping exactly, so the cheaper partition is never larger on the wire.
fn partition_cost(
  tokens : Array[Int],
  all_pos : Array[Int],
  cuts : Array[Int],
) -> Int {
  let m = tokens.length()
  let mut total = 0
  let mut lo = 0
  for cut in cuts {
    let ll_freq = Array::make(MAX_NUM_LIT, 0)
    let d_freq = Array::make(MAX_NUM_DIST, 0)
    range_freqs(tokens, lo, cut, ll_freq, d_freq)
    total = total + block_cost_bits(all_pos[cut] - all_pos[lo], ll_freq, d_freq)
    lo = cut
  }
  if lo < m {
    let ll_freq = Array::make(MAX_NUM_LIT, 0)
    let d_freq = Array::make(MAX_NUM_DIST, 0)
    range_freqs(tokens, lo, m, ll_freq, d_freq)
    total = total + block_cost_bits(all_pos[m] - all_pos[lo], ll_freq, d_freq)
  }
  total
}

///|
/// Emit the token stream `tokens` (covering `data[start:processed)`) as blocks
/// cut at `cuts`, through the ordinary `emit_block`. `all_pos` maps token index
/// to the byte offset where it starts (with `all_pos[tokens.length()]` = end).
fn emit_split_blocks(
  w : BitWriter,
  data : Bytes,
  tokens : Array[Int],
  all_pos : Array[Int],
  cuts : Array[Int],
  n : Int,
) -> Unit {
  let m = tokens.length()
  let mut lo = 0
  for cut in cuts {
    let ll_freq = Array::make(MAX_NUM_LIT, 0)
    let d_freq = Array::make(MAX_NUM_DIST, 0)
    range_freqs(tokens, lo, cut, ll_freq, d_freq)
    emit_block(
      w,
      data,
      all_pos[lo],
      all_pos[cut],
      tokens[lo:cut],
      ll_freq,
      d_freq,
      is_final=all_pos[cut] >= n,
    )
    lo = cut
  }
  if lo < m {
    let ll_freq = Array::make(MAX_NUM_LIT, 0)
    let d_freq = Array::make(MAX_NUM_DIST, 0)
    range_freqs(tokens, lo, m, ll_freq, d_freq)
    emit_block(
      w,
      data,
      all_pos[lo],
      all_pos[m],
      tokens[lo:m],
      ll_freq,
      d_freq,
      is_final=all_pos[m] >= n,
    )
  }
}

///|
/// Compress with content-driven block splitting: tokenize each master chunk
/// once (full 32 KB cross-block history), cut the token stream where the
/// symbol statistics drift, and emit one dynamic-Huffman block per segment.
/// A mid-tier between the fixed-cadence `deflate_all` and the offline zopfli
/// `deflate_all_optimal`.
pub fn deflate_all_split(input : Bytes, level? : Int = 6) -> Bytes {
  let lv = if level < 0 { 0 } else if level > 9 { 9 } else { level }
  let w = BitWriter()
  let n = input.length()
  if lv == 0 {
    write_stored(w, input, 0, n, is_final=true)
    w.flush()
    return Bytes::from_array(w.out)
  }
  if n == 0 {
    let ll_freq = Array::make(MAX_NUM_LIT, 0)
    let d_freq = Array::make(MAX_NUM_DIST, 0)
    let none : Array[Int] = []
    emit_block(w, input, 0, 0, none[:], ll_freq, d_freq, is_final=true)
    w.flush()
    return Bytes::from_array(w.out)
  }
  let cfg = level_configs[lv]
  let mut pos = 0
  for ;; {
    let target = if pos + SPLIT_MASTER_CHUNK < n {
      pos + SPLIT_MASTER_CHUNK
    } else {
      n
    }
    let tokens : Array[Int] = []
    let ll_freq = Array::make(MAX_NUM_LIT, 0)
    let d_freq = Array::make(MAX_NUM_DIST, 0)
    let processed = tokenize(input, pos, target, cfg, tokens, ll_freq, d_freq)
    let all_pos = token_positions(tokens, pos, processed)
    let split_cuts = choose_splits(tokens)
    // Arbitrate against the fixed cadence by exact cost so the adaptive split
    // never regresses the fixed-cadence ratio (libdeflate-style arbitration).
    // This must run even when `split_cuts` is empty: a single undivided block
    // can still lose to the fixed cadence when the chunk drifts slowly.
    let fixed_cuts = fixed_cadence_cuts(tokens, all_pos, pos)
    let cuts = if partition_cost(tokens, all_pos, split_cuts) <=
      partition_cost(tokens, all_pos, fixed_cuts) {
      split_cuts
    } else {
      fixed_cuts
    }
    emit_split_blocks(w, input, tokens, all_pos, cuts, n)
    pos = processed
    if pos >= n {
      break
    }
  }
  w.flush()
  Bytes::from_array(w.out)
}
