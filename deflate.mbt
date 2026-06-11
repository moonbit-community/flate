// Streaming DEFLATE compressor (RFC 1951), the push-based counterpart to
// `Inflater`. Unlike a one-shot `deflate_all`, it emits the stream as a
// sequence of blocks while input arrives, so memory is bounded and output is
// produced incrementally.
//
// Model:
//  - Input accumulates in `pending`, whose leading `window_carry` bytes are
//    history kept only so cross-block back-references resolve; the rest is
//    input not yet emitted.
//  - When enough tokenizable input has accrued (a block's worth, with a
//    lookahead margin reserved so matches near the boundary aren't truncated),
//    one non-final block is emitted via the shared `tokenize` + `emit_block`,
//    `pending` is trimmed back to a 32 KB window, and the bytes flow on.
//  - `end=true` tokenizes whatever remains into a final block and flushes.
//  - A persistent `BitWriter` carries the sub-byte bit remainder across blocks
//    (the bit stream is continuous; only the final block pads to a byte). Its
//    byte buffer is drained into the caller's output and reclaimed each block,
//    suspending with `NeedMoreOutput` whenever that buffer fills.

///|
/// Target tokenizable bytes per block, shared by the streaming `Deflater` and
/// one-shot `deflate_all`. 16 KB = zlib's default token-buffer size (memLevel 8
/// gives `lit_bufsize` = 2^(8+6) = 16384), the field-tested balance: large
/// enough to amortize the dynamic-Huffman table header over many bytes, small
/// enough that one table tracks roughly-stationary statistics and that
/// streaming bounds latency and memory rather than spanning whole megabytes.
let deflate_block_size = 16384

///|
/// Streaming DEFLATE compressor : a push-based, suspendable state
/// machine. It emits the stream block-by-block as input arrives , and chooses fixed- or dynamic-Huffman per block.
pub struct Deflater {
  priv mut pending : Array[Byte] // carried window history + un-emitted input
  priv mut window_carry : Int // leading history-only bytes in `pending`
  priv w : BitWriter // persistent bit sink spanning all blocks
  priv mut out_pos : Int // next `w.out` index to hand to the caller
  priv mut emitted_final : Bool // the final block has been written into `w`
  priv mut done : Bool // the final block has been fully drained
  priv level : Int // compression level 0-9 (0 = stored only)
  priv cfg : LevelConfig // match-search tuning for `level`
}

///|
/// Create a fresh compressor. `level` 0-9 (clamped) trades speed for ratio
/// with zlib-equivalent tuning; 0 emits stored blocks only, 6 is the default.
pub fn Deflater::new(level? : Int = 6) -> Deflater {
  let lv = if level < 0 { 0 } else if level > 9 { 9 } else { level }
  {
    pending: [],
    window_carry: 0,
    w: BitWriter::new(),
    out_pos: 0,
    emitted_final: false,
    done: false,
    level: lv,
    cfg: level_configs[lv],
  }
}

///|
/// Preload the match window with a preset dictionary (the last 32 KB of
/// `dict`), so emitted back-references may reach into it (zlib
/// `deflateSetDictionary`). Must be called on a fresh stream — right after
/// `new()` or `reset()`, before any input. The decoder needs the same
/// dictionary.
pub fn Deflater::set_dictionary(self : Deflater, dict : BytesView) -> Unit {
  guard self.pending.length() == 0 &&
    self.w.out.length() == 0 &&
    self.w.bit_count == 0 &&
    !self.emitted_final else {
    abort("Deflater::set_dictionary: stream already started")
  }
  let start = if dict.length() > window_size {
    dict.length() - window_size
  } else {
    0
  }
  for i in start..<dict.length() {
    self.pending.push(dict[i])
  }
  self.window_carry = self.pending.length()
}

///|
/// Reset to the start of a fresh DEFLATE stream, keeping the compression
/// level and reusing allocations across many streams (e.g. ZIP entries).
/// A preset dictionary, if any, must be set again.
pub fn Deflater::reset(self : Deflater) -> Unit {
  self.pending.clear()
  self.window_carry = 0
  self.w.out.clear()
  self.w.bitbuf = 0
  self.w.bit_count = 0
  self.out_pos = 0
  self.emitted_final = false
  self.done = false
}

///|
/// Whether the final compressed stream has been fully emitted.
pub fn Deflater::is_finished(self : Deflater) -> Bool {
  self.done
}

///|
/// Run one compression step. Buffers `input`, emits as many blocks as the
/// accrued input allows, and drains compressed bytes into `output` over
/// `out_off..<out_off+out_len`. Returns `(status, consumed, produced)`;
/// `consumed` is always the whole input view. Pass `end=true` (with any
/// remaining input, or none) to finalize, and keep calling with `end=true`
/// while it returns `NeedMoreOutput` to drain the rest. Pass `flush=true` to
/// sync-flush (zlib `Z_SYNC_FLUSH`): everything buffered is compressed and the
/// bit stream is padded to a byte boundary with an empty stored block, so all
/// produced bytes are final and transmittable while the stream continues.
pub fn Deflater::step(
  self : Deflater,
  input : BytesView,
  output : FixedArray[Byte],
  out_off~ : Int,
  out_len? : Int = output.length() - out_off,
  end? : Bool = false,
  flush? : Bool = false,
) -> (Status, Int, Int) {
  for i in 0..<input.length() {
    self.pending.push(input[i])
  }
  let consumed = input.length()
  let out_end = out_off + out_len
  let mut write_pos = out_off
  let mut flushed = false
  for ;; {
    // Drain compressed bytes already produced into the caller's buffer.
    while self.out_pos < self.w.out.length() && write_pos < out_end {
      output[write_pos] = self.w.out[self.out_pos]
      write_pos = write_pos + 1
      self.out_pos = self.out_pos + 1
    }
    if self.out_pos < self.w.out.length() {
      return (NeedMoreOutput, consumed, write_pos - out_off)
    }
    // The current block buffer is fully drained; reclaim it.
    if self.w.out.length() > 0 {
      self.w.out.clear()
      self.out_pos = 0
    }
    if self.emitted_final {
      self.done = true
      return (Done, consumed, write_pos - out_off)
    }
    // Produce the next block, or wait for more input.
    if end {
      self.emit_final()
    } else if flush && !flushed {
      self.emit_flush()
      flushed = true
    } else if self.pending.length() - self.window_carry >=
      deflate_block_size + min_lookahead {
      self.emit_one()
    } else {
      return (NeedMoreInput, consumed, write_pos - out_off)
    }
  }
}
