// One-shot DEFLATE compression: the whole input in, a complete raw DEFLATE
// stream out. The counterpart to the streaming `Deflater` (deflate.mbt) for
// when all input is already in hand.

///|
/// Compress bytes into a complete raw DEFLATE stream held entirely in memory.
/// Because the whole input is in hand, no sliding window is needed: this
/// tokenizes directly over `input`, advancing a single offset, with none of the
/// streaming `Deflater`'s per-block buffering.
pub fn deflate_all(input : Bytes, level? : Int = 6) -> Bytes {
  let lv = if level < 0 { 0 } else if level > 9 { 9 } else { level }
  let w = BitWriter::new()
  let n = input.length()
  // Level 0 (and the empty input it subsumes): one stored pass, no parsing.
  if lv == 0 {
    write_stored(w, input, 0, n, is_final=true)
    w.flush()
    return Bytes::from_array(w.out)
  }
  let cfg = level_configs[lv]
  // Each non-final block covers up to `deflate_block_size` tokenizable bytes; a
  // boundary match may overhang, so `processed` (not `target`) sets the next
  // start. 
  let mut pos = 0
  for ;; {
    let target = if pos + deflate_block_size < n {
      pos + deflate_block_size
    } else {
      n
    }
    let tokens : Array[Int] = []
    let ll_freq = Array::make(286, 0)
    let d_freq = Array::make(30, 0)
    let processed = tokenize(input, pos, target, cfg, tokens, ll_freq, d_freq)
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
    if pos >= n {
      break
    }
  }
  w.flush()
  Bytes::from_array(w.out)
}
