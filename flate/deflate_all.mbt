// One-shot DEFLATE compression: the whole input in, a complete raw DEFLATE
// stream out. The counterpart to the streaming `Deflater` (deflate.mbt) for
// when all input is already in hand.

///|
/// A reusable, whole-buffer raw DEFLATE compressor. Unlike the suspendable
/// `Deflater`, it reads the input directly and writes one complete stream into
/// either a caller-provided buffer or reusable growable output storage.
pub struct Compressor {
  priv level : Int
  priv fast_store : Bool
  priv cfg : LevelConfig
  priv finder : MatchFinder
  priv tokens : Array[Int]
  priv mut output : FixedArray[Byte]
  priv ll_freq : FixedArray[Int]
  priv d_freq : FixedArray[Int]
}

///|
/// Create a reusable whole-buffer compressor. `level` 0-9 is clamped, with
/// level 0 selecting stored blocks only. `fast_store` defaults to false; when
/// enabled, sampled high-diversity inputs may bypass compression and use stored
/// blocks. It trades compression ratio for speed without changing the data.
pub fn Compressor::Compressor(
  level? : Int = 6,
  fast_store? : Bool = false,
) -> Compressor {
  let level = clamp_level(level)
  {
    level,
    fast_store,
    cfg: level_configs[level],
    finder: MatchFinder(input_size=0),
    tokens: [],
    output: [],
    ll_freq: FixedArray::make(MAX_NUM_LIT, 0),
    d_freq: FixedArray::make(MAX_NUM_DIST, 0),
  }
}

///|
/// A conservative output capacity for `deflate_into` or
/// `Compressor::compress_into`. The returned value covers the fixed 16 KiB
/// minimum block cadence and final bit padding for a non-negative input length.
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
  self.encode(input, BitWriter::into(output))
}

///|
/// Compress a complete stream, reusing the parsing and output workspace.
/// The returned bytes are independent of subsequent calls to this compressor.
pub fn Compressor::compress(self : Compressor, input : Bytes) -> Bytes {
  let writer = BitWriter::growing(self.output)
  ignore(self.encode(input, writer))
  if writer.direct_output is Some(output) {
    self.output = output
  }
  Bytes::from_array(self.output[:writer.direct_pos])
}

///|
fn Compressor::encode(self : Compressor, input : Bytes, w : BitWriter) -> Int? {
  let n = input.length()
  // Level 0 or an explicit heuristic decision bypasses parsing entirely.
  guard self.level != 0 && !(self.fast_store && should_fast_store(input)) else {
    write_stored(w, input, 0, n, is_final=true)
    w.flush()
    if w.overflowed {
      None
    } else {
      Some(w.direct_pos)
    }
  }
  self.finder.reset_for_input(input)
  // The default level amortizes block construction over 65535 bytes; a
  // boundary match may overhang, so `processed` (not `target`) sets the next
  // start.
  let block_size = if self.level == 6 { 65535 } else { DEFLATE_BLOCK_SIZE }
  let mut pos = 0
  for ;; {
    let target = (pos + block_size).min(n)
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
/// is needed. Opt-in `fast_store` may emit stored blocks after a heuristic
/// check; false (the default) preserves normal compression behavior.
pub fn deflate_all(
  input : Bytes,
  level? : Int = 6,
  fast_store? : Bool = false,
) -> Bytes {
  let lv = clamp_level(level)
  let w = BitWriter()
  let n = input.length()
  // Level 0 or an explicit heuristic decision bypasses parsing entirely.
  guard lv != 0 && !(fast_store && should_fast_store(input)) else {
    write_stored(w, input, 0, n, is_final=true)
    w.flush()
    return Bytes::from_array(w.out)
  }
  let cfg = level_configs[lv]
  let finder = MatchFinder(input_size=n)
  let block_size = if lv == 6 { 65535 } else { DEFLATE_BLOCK_SIZE }
  let mut pos = 0
  for ;; {
    let target = (pos + block_size).min(n)
    let tokens : Array[Int] = []
    let ll_freq = FixedArray::make(286, 0)
    let d_freq = FixedArray::make(30, 0)
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
/// Optional `fast_store` has the same opt-in speed/ratio trade-off as `deflate_all`.
pub fn deflate_into(
  input : Bytes,
  output : FixedArray[Byte],
  level? : Int = 6,
  fast_store? : Bool = false,
) -> Int? {
  Compressor(level~, fast_store~).compress_into(input, output)
}
