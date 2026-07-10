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
  priv mut flush_done : Bool // the current buffered content has been sync-flushed
  priv mut flush_requested : Bool // sticky until the requested flush is emitted
  priv mut end_requested : Bool // sticky until reset; no later input is accepted
  priv mut started : Bool // dictionary fixed, input accepted, or control emitted
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
    flush_done: false,
    flush_requested: false,
    end_requested: false,
    started: false,
    level: lv,
    cfg: level_configs[lv],
  }
}

///|
/// Enforce the one-time dictionary configuration contract. Panic tests exercise
/// the rejection path, but a terminating native subprocess cannot flush its
/// coverage trace, so keep this narrow precondition helper out of the metric.
#coverage.skip
fn Deflater::require_fresh_dictionary(self : Deflater) -> Unit {
  guard !self.started &&
    self.pending.length() == 0 &&
    self.w.out.length() == 0 &&
    self.w.bit_count == 0 &&
    !self.emitted_final else {
    abort("Deflater::set_dictionary: stream already started")
  }
}

///|
/// Preload the match window with a preset dictionary (the last 32 KB of
/// `dict`), so emitted back-references may reach into it (zlib
/// `deflateSetDictionary`). Must be called on a fresh stream — right after
/// `new()` or `reset()`, before any input. The decoder needs the same
/// dictionary.
pub fn Deflater::set_dictionary(self : Deflater, dict : BytesView) -> Unit {
  self.require_fresh_dictionary()
  let start = if dict.length() > window_size {
    dict.length() - window_size
  } else {
    0
  }
  for i in start..<dict.length() {
    self.pending.push(dict[i])
  }
  self.window_carry = self.pending.length()
  // Dictionary selection is a one-time stream configuration, including for an
  // empty dictionary. This also makes a second call unambiguously invalid.
  self.started = true
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
  self.flush_done = false
  self.flush_requested = false
  self.end_requested = false
  self.started = false
}

///|
/// Whether the final compressed stream has been fully emitted.
pub fn Deflater::is_finished(self : Deflater) -> Bool {
  self.done
}

///|
/// Run one compression step. Accepts as much of `input` as fits in one bounded
/// block window, emits blocks, and drains compressed bytes into `output`.
/// Returns `(status, consumed, produced)`; drop only `input[:consumed]` and
/// re-present the suffix. With a small output buffer a large input may be
/// consumed only partially, which propagates output backpressure instead of
/// growing internal memory with the caller's input size. Once a final block has
/// been emitted, calls only drain that block and consume no new input; after
/// completion they idempotently return `(Done, 0, 0)`.
///
/// Pass `end=true` with the final input view. The request is accepted after that
/// entire view has been consumed, then remains latched across `NeedMoreOutput`;
/// if a call reports partial consumption, re-present the suffix with `end=true`.
/// Later input is left unconsumed. Pass `flush=true` similarly to sync-flush
/// (zlib `Z_SYNC_FLUSH`):
/// everything buffered is compressed and the bit stream is padded to a byte
/// boundary with an empty stored block, so all produced bytes are final and
/// transmittable while the stream continues. A flush request is sticky across
/// output backpressure once accepted. An empty `output` may accept at most one
/// bounded block window before returning `NeedMoreOutput`.
pub fn Deflater::step(
  self : Deflater,
  input : BytesView,
  output : MutArrayView[Byte],
  end? : Bool = false,
  flush? : Bool = false,
) -> (Status, Int, Int) {
  // Completion is a stable terminal state. In particular, input presented by
  // a generic driver after it observes EOF remains unconsumed instead of
  // disappearing into a stream that can no longer encode it.
  if self.done {
    return (Done, 0, 0)
  }
  // An empty view is already fully accepted, so its control request can be
  // latched even while older compressed output is still backpressured.
  if input.length() == 0 && !self.end_requested && !self.emitted_final {
    if end {
      self.started = true
      self.end_requested = true
      self.flush_requested = false
    } else if flush && !self.flush_done {
      self.started = true
      self.flush_requested = true
    }
  }
  let out_end = output.length()
  let input_end = input.length()
  let input_limit = deflate_block_size + min_lookahead
  let mut consumed = 0
  let mut write_pos = 0
  for ;; {
    // Drain compressed bytes already produced into the caller's buffer.
    while self.out_pos < self.w.out.length() && write_pos < out_end {
      output.set(write_pos, self.w.out[self.out_pos])
      write_pos = write_pos + 1
      self.out_pos = self.out_pos + 1
    }
    if self.out_pos < self.w.out.length() {
      return (NeedMoreOutput, consumed, write_pos)
    }
    // The current block buffer is fully drained; reclaim it.
    if self.w.out.length() > 0 {
      self.w.out.clear()
      self.out_pos = 0
    }
    if self.emitted_final {
      self.done = true
      return (Done, consumed, write_pos)
    }
    // Produce already-requested control blocks before accepting later input.
    if self.end_requested {
      self.flush_requested = false
      self.emit_final()
      continue
    }
    if self.flush_requested {
      self.emit_flush()
      self.flush_done = true
      self.flush_requested = false
      continue
    }
    // A full token window becomes one bounded non-final block before more
    // input is accepted. This is the high-water mark that propagates output
    // backpressure through `consumed`.
    let buffered = self.pending.length() - self.window_carry
    if buffered >= input_limit {
      self.emit_one()
      continue
    }
    if consumed < input_end {
      let remaining = input_end - consumed
      let capacity = input_limit - buffered
      let take = if remaining < capacity { remaining } else { capacity }
      for i in consumed..<(consumed + take) {
        self.pending.push(input[i])
      }
      consumed = consumed + take
      if take > 0 {
        self.started = true
        self.flush_done = false
      }
      // Latch control the instant its complete input view is accepted, before
      // emitting that block can return through output backpressure.
      if consumed == input_end {
        if end {
          self.end_requested = true
          self.flush_requested = false
        } else if flush && !self.flush_done {
          self.flush_requested = true
        }
      }
      continue
    }
    return (NeedMoreInput, consumed, write_pos)
  }
}
