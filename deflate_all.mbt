// One-shot DEFLATE compression: the whole input in, a complete raw DEFLATE
// stream out. The counterpart to the streaming `Deflater` (deflate.mbt) for
// when all input is already in hand.

///|
/// A reusable, whole-buffer raw DEFLATE compressor. Unlike the suspendable
/// `Deflater`, it reads the input directly and writes one complete stream into
/// a caller-provided buffer.
pub struct Compressor {
  priv level : Int
  priv cfg : LevelConfig
  priv finder : MatchFinder
  priv tokens : Array[Int]
  priv ll_freq : Array[Int]
  priv d_freq : Array[Int]
}

///|
/// Create a reusable whole-buffer compressor. `level` 0-9 is clamped, with
/// level 0 selecting stored blocks only.
pub fn Compressor::Compressor(level? : Int = 6) -> Compressor {
  let level = clamp_level(level)
  {
    level,
    cfg: level_configs[level],
    finder: MatchFinder(),
    tokens: [],
    ll_freq: Array::make(MAX_NUM_LIT, 0),
    d_freq: Array::make(MAX_NUM_DIST, 0),
  }
}

///|
/// A conservative output capacity for `deflate_into` or
/// `Compressor::compress_into`. The returned value covers the fixed 16 KiB
/// block cadence and final bit padding for a non-negative input length.
pub fn deflate_bound(input_size : Int) -> Int {
  let input_size = input_size.max(0)
  let block_count = if input_size == 0 {
    1
  } else {
    (input_size - 1) / DEFLATE_BLOCK_SIZE + 1
  }
  input_size + 5 * block_count + 1
}

///|
/// Compress `input` directly into `output`, returning its byte length. `None`
/// means that `output` was too small; any prefix written before exhaustion is
/// unspecified. Reuse one `Compressor` and one caller-owned output buffer to
/// avoid per-stream workspace and result-buffer allocation.
pub fn Compressor::compress_into(
  self : Compressor,
  input : Bytes,
  output : FixedArray[Byte],
) -> Int? {
  let w = BitWriter::into(output)
  let n = input.length()
  self.finder.reset()
  // Level 0 (and the empty input it subsumes): one stored pass, no parsing.
  guard self.level != 0 else {
    write_stored(w, input, 0, n, is_final=true)
    w.flush()
    if w.overflowed {
      None
    } else {
      Some(w.direct_pos)
    }
  }
  // Each non-final block covers up to `DEFLATE_BLOCK_SIZE` tokenizable bytes; a
  // boundary match may overhang, so `processed` (not `target`) sets the next
  // start.
  let mut pos = 0
  for ;; {
    let target = (pos + DEFLATE_BLOCK_SIZE).min(n)
    self.tokens.clear()
    self.ll_freq.fill(0)
    self.d_freq.fill(0)
    let processed = tokenize(
      input,
      self.finder,
      pos,
      target,
      self.cfg,
      self.tokens,
      self.ll_freq,
      self.d_freq,
    )
    emit_block(
      w,
      input,
      pos,
      processed,
      self.tokens[:],
      self.ll_freq,
      self.d_freq,
      is_final=processed >= n,
    )
    pos = processed
    guard pos < n else { break }
  }
  w.flush()
  if w.overflowed {
    None
  } else {
    Some(w.direct_pos)
  }
}

///|
/// Compress bytes into a complete raw DEFLATE stream held entirely in memory.
/// The whole input is tokenized directly, advancing a single offset and a
/// session-owned fixed matchfinder; unlike `Deflater`, no input staging ring
/// is needed.
pub fn deflate_all(input : Bytes, level? : Int = 6) -> Bytes {
  let lv = clamp_level(level)
  let w = BitWriter()
  let n = input.length()
  // Level 0 (and the empty input it subsumes): one stored pass, no parsing.
  guard lv != 0 else {
    write_stored(w, input, 0, n, is_final=true)
    w.flush()
    return Bytes::from_array(w.out)
  }
  let cfg = level_configs[lv]
  let finder = MatchFinder()
  let mut pos = 0
  for ;; {
    let target = (pos + DEFLATE_BLOCK_SIZE).min(n)
    let tokens : Array[Int] = []
    let ll_freq = Array::make(286, 0)
    let d_freq = Array::make(30, 0)
    let processed = tokenize(
      input, finder, pos, target, cfg, tokens, ll_freq, d_freq,
    )
    emit_block(
      w,
      input,
      pos,
      processed,
      tokens[:],
      ll_freq,
      d_freq,
      is_final=processed >= n,
    )
    pos = processed
    guard pos < n else { break }
  }
  w.flush()
  Bytes::from_array(w.out)
}

///|
/// One-shot convenience form of `Compressor::compress_into`. It creates a
/// compressor for this call; use `Compressor` when encoding many streams.
pub fn deflate_into(
  input : Bytes,
  output : FixedArray[Byte],
  level? : Int = 6,
) -> Int? {
  Compressor(level~).compress_into(input, output)
}
