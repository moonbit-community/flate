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
//  - `Finish` tokenizes whatever remains into a final block and flushes.
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
  priv mut step_consumed : Int // input accepted by the latest successful step
  priv mut step_produced : Int // output written by the latest successful step
  priv level : Int // compression level 0-9 (0 = stored only)
  priv cfg : LevelConfig // match-search tuning for `level`
}

///|
/// Create a fresh compressor. `level` 0-9 (clamped) trades speed for ratio
/// with zlib-equivalent tuning; 0 emits stored blocks only, 6 is the default.
/// `dictionary`, when supplied, preloads the match window with its last 32 KB;
/// the decoder must use the same preset dictionary.
pub fn Deflater::new(level? : Int = 6, dictionary? : BytesView) -> Deflater {
  let lv = if level < 0 { 0 } else if level > 9 { 9 } else { level }
  let deflater = {
    pending: [],
    window_carry: 0,
    w: BitWriter::new(),
    out_pos: 0,
    emitted_final: false,
    done: false,
    flush_done: false,
    flush_requested: false,
    end_requested: false,
    step_consumed: 0,
    step_produced: 0,
    level: lv,
    cfg: level_configs[lv],
  }
  match dictionary {
    Some(dict) => deflater.preload_dictionary(dict)
    None => ()
  }
  deflater
}

///|
/// Preload the match window from a constructor or reset dictionary. The caller
/// has already cleared `pending`, so this copies at most the final 32 KB.
fn Deflater::preload_dictionary(
  self : Deflater,
  dictionary : BytesView,
) -> Unit {
  let start = if dictionary.length() > window_size {
    dictionary.length() - window_size
  } else {
    0
  }
  for i in start..<dictionary.length() {
    self.pending.push(dictionary[i])
  }
  self.window_carry = self.pending.length()
}

///|
/// Reset to the start of a fresh DEFLATE stream, keeping the compression
/// level and reusing allocations across many streams (e.g. ZIP entries).
/// With no `dictionary`, the history is cleared. Supplying one immediately
/// preloads its last 32 KB for the new stream; the decoder must use the same
/// preset dictionary.
pub fn Deflater::reset(self : Deflater, dictionary? : BytesView) -> Unit {
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
  self.step_consumed = 0
  self.step_produced = 0
  match dictionary {
    Some(dict) => self.preload_dictionary(dict)
    None => ()
  }
}

///|
/// Whether the final compressed stream has been fully emitted.
pub fn Deflater::is_finished(self : Deflater) -> Bool {
  self.done
}

///|
/// Number of input bytes accepted by the latest `step` call. This is zero
/// initially, after `reset`, and for the stable `Done` state.
pub fn Deflater::last_consumed(self : Deflater) -> Int {
  self.step_consumed
}

///|
/// Number of output bytes written by the latest `step` call. This is zero
/// initially, after `reset`, and for the stable `Done` state.
pub fn Deflater::last_produced(self : Deflater) -> Int {
  self.step_produced
}

///|
/// Commit the counters for one normally returning public step.
fn Deflater::finish_step(
  self : Deflater,
  status : Status,
  consumed : Int,
  produced : Int,
) -> Status {
  self.step_consumed = consumed
  self.step_produced = produced
  status
}

///|
/// Run one compression step. Accepts as much of `input` as fits in one bounded
/// block window, emits blocks, and drains compressed bytes into `output`.
/// Returns the status; read `last_consumed()` and `last_produced()` immediately
/// afterwards for this call's counts. Drop only `input[:last_consumed()]` and
/// re-present the suffix. With a small output buffer a large input may be
/// consumed only partially, which propagates output backpressure instead of
/// growing internal memory with the caller's input size. Once a final block has
/// been emitted, calls only drain that block and consume no new input; after
/// completion they idempotently return `Done` with both counts zero.
///
/// Use `action=Finish` with the final input view. The action is accepted after
/// that entire view has been consumed, then remains latched across
/// `NeedMoreOutput`; if a call reports partial consumption, re-present the
/// suffix with `action=Finish`. Later input is left unconsumed.
///
/// `action=SyncFlush` similarly requests zlib-style `Z_SYNC_FLUSH`: everything
/// buffered is compressed and the bit stream is padded to a byte boundary with
/// an empty stored block, so all produced bytes are final and transmittable
/// while the stream continues. A sync-flush is sticky across output
/// backpressure once accepted. `Continue` only accepts input. An empty `output`
/// may accept at most one bounded block window before returning
/// `NeedMoreOutput`.
pub fn Deflater::step(
  self : Deflater,
  input : BytesView,
  output : MutArrayView[Byte],
  action? : DeflateAction = Continue,
) -> Status {
  self.step_consumed = 0
  self.step_produced = 0
  // Completion is a stable terminal state. In particular, input presented by
  // a generic driver after it observes EOF remains unconsumed instead of
  // disappearing into a stream that can no longer encode it.
  if self.done {
    return self.finish_step(Done, 0, 0)
  }
  // An empty view is already fully accepted, so its control request can be
  // latched even while older compressed output is still backpressured.
  if input.length() == 0 && !self.end_requested && !self.emitted_final {
    if action is Finish {
      self.end_requested = true
      self.flush_requested = false
    } else if action is SyncFlush && !self.flush_done {
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
      return self.finish_step(NeedMoreOutput, consumed, write_pos)
    }
    // The current block buffer is fully drained; reclaim it.
    if self.w.out.length() > 0 {
      self.w.out.clear()
      self.out_pos = 0
    }
    if self.emitted_final {
      self.done = true
      return self.finish_step(Done, consumed, write_pos)
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
        self.flush_done = false
      }
      // Latch control the instant its complete input view is accepted, before
      // emitting that block can return through output backpressure.
      if consumed == input_end {
        if action is Finish {
          self.end_requested = true
          self.flush_requested = false
        } else if action is SyncFlush && !self.flush_done {
          self.flush_requested = true
        }
      }
      continue
    }
    return self.finish_step(NeedMoreInput, consumed, write_pos)
  }
}
