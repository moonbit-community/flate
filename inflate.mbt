// Streaming, suspendable DEFLATE decoder (RFC 1951)
//
// Suspension model:
//  - Input: each block header and each literal/match "unit" is decoded
//    atomically. A bit read past the end of the current input raises the
//    internal `NeedInput`; the decoder rewinds that unit and owns its bounded
//    byte tail, so `step` can accept non-overlapping chunks and resume once more
//    input arrives.
//  - Output: a unit needs room for only its first byte; a match longer than the
//    remaining output is copied in pieces, with `copy_remaining`/`copy_dist`
//    carrying the rest to the next `step`. Stored blocks copy byte-by-byte and
//    suspend on either side as needed.
//  - Back-references read from a 32 KB circular history window.

///|
/// Stable classification for failures raised by the raw DEFLATE APIs.
pub(all) enum InflateErrorKind {
  /// Physical input ended before a complete raw DEFLATE stream.
  Truncated
  /// The raw stream violates RFC 1951 structure or coding rules.
  Corrupt
  /// Exact decoding reached a valid final block before the input boundary.
  TrailingData
  /// Decoded output would exceed the caller-supplied safety limit.
  OutputLimitExceeded
} derive(Eq, Debug)

///|
/// Error raised while decoding a raw DEFLATE stream.
pub suberror InflateError {
  InflateError(InflateErrorKind, String)
}

///|
/// Internal control-flow signal: the current input view was exhausted mid-unit.
priv suberror NeedInput

///|
/// Static interpretation of one dynamic-header repeat symbol. Keeping this
/// independent of either bit reader makes the streaming and in-memory decoders
/// agree on the symbol's base count, extra-bit width, and repeated value.
priv struct CodeLengthRepeat {
  base : Int
  extra_bits : Int
  value : Int
}

///|
fn interpret_code_length_repeat(
  symbol : Int,
  previous : Int?,
) -> CodeLengthRepeat raise InflateError {
  match symbol {
    16 =>
      match previous {
        Some(value) => { base: 3, extra_bits: 2, value }
        None =>
          raise InflateError(Corrupt, "corrupt: repeat with no previous length")
      }
    17 => { base: 3, extra_bits: 3, value: 0 }
    18 => { base: 11, extra_bits: 7, value: 0 }
    _ => raise InflateError(Corrupt, "corrupt: bad code-length symbol")
  }
}

///|
/// Total classification of every error that can cross one atomic streaming
/// decode boundary. Unknown future error kinds become the stable public
/// corruption diagnostic instead of leaking through `Inflater::step`.
priv enum DecoderErrorClass {
  DecoderInputExhausted
  DecoderFailure(InflateErrorKind, String)
}

///|
fn classify_decoder_error(err : Error) -> DecoderErrorClass {
  match err {
    NeedInput => DecoderInputExhausted
    InflateError(kind, message) => DecoderFailure(kind, message)
    _ => DecoderFailure(Corrupt, "corrupt: unexpected decoder error")
  }
}

///|
priv enum Mode {
  AtBlock // about to read the next block header
  InStored // copying a stored block (stored_remaining bytes left)
  InHuffman // decoding literal/match units with hl/hd
  Done
}

///|
/// Streaming DEFLATE decompressor (RFC 1951): a push-based, suspendable state
/// machine. All cross-call state lives here, so it pauses on
/// `NeedMoreInput`/`NeedMoreOutput` and resumes on the next `step`.  Supports stored, fixed- and dynamic-Huffman
/// blocks. `step` makes progress with as little as one byte of output room
/// (the `output` view): a match too large for the buffer is copied in
/// pieces across calls.
pub struct Inflater {
  priv mut mode : Mode
  priv mut bitbuf : Int // LSB-first bit accumulator
  priv mut bit_count : Int
  priv mut final_block : Bool
  priv mut stored_remaining : Int
  priv mut hl : HuffmanDecoder? // literal/length table (None until a block sets it)
  priv mut hd : HuffmanDecoder? // distance table (None => fixed 5-bit distances)
  priv mut hd_fixed : Bool
  priv window : FixedArray[Byte] // 32 KB circular history
  priv mut wpos : Int // total bytes ever written; window index = wpos & 32767
  priv mut filled : Bool // window has held >= 32 KB, so any distance <= 32768 is valid
  priv dyn_litlen : HuffmanDecoder // dynamic literal/length (and code-length) table
  priv dyn_dist : HuffmanDecoder // dynamic distance table
  priv clbits : Array[Int]
  priv codebits : Array[Int]
  // A match copy in progress, suspended because the output filled mid-copy.
  // `copy_remaining` bytes are still owed at back-distance `copy_dist`; the
  // next `step` drains them before decoding any new unit. This is what lets
  // the decoder make progress into an output buffer as small as one byte.
  priv mut copy_remaining : Int
  priv mut copy_dist : Int
  // Bytes belonging to one incomplete atomic unit. Owning this bounded tail
  // lets callers drop every byte reported as consumed instead of re-presenting
  // a growing view on NeedMoreInput.
  priv mut staged_input : Array[Byte]
  priv mut staged_pos : Int
  priv mut ending : Bool // physical EOF has been declared by the caller
  priv mut failure_kind : InflateErrorKind? // stable terminal error
  priv mut failure_message : String
  priv mut step_consumed : Int // input accepted by the latest successful step
  priv mut step_produced : Int // output written by the latest successful step
  // Step-local cursors (reset on each `step`).
  priv mut view : BytesView
  priv mut in_pos : Int
  priv mut out_pos : Int
  priv mut out : MutArrayView[Byte]
  priv mut out_end : Int // one past the last writable index in `out`
  priv empty_out : FixedArray[Byte]
}

///|
/// Create a fresh decompressor positioned at the start of a DEFLATE stream.
/// If supplied, `dictionary` preloads the history window with its final 32 KiB.
pub fn Inflater::new(dictionary? : BytesView) -> Inflater {
  let empty_out = FixedArray::make(0, b'\x00')
  let inflater : Inflater = {
    mode: AtBlock,
    bitbuf: 0,
    bit_count: 0,
    final_block: false,
    stored_remaining: 0,
    hl: None,
    hd: None,
    hd_fixed: false,
    window: FixedArray::make(window_size, b'\x00'),
    wpos: 0,
    filled: false,
    dyn_litlen: HuffmanDecoder::new(),
    dyn_dist: HuffmanDecoder::new(),
    clbits: Array::make(max_num_lit + max_num_dist, 0),
    codebits: Array::make(num_codes, 0),
    copy_remaining: 0,
    copy_dist: 0,
    staged_input: [],
    staged_pos: 0,
    ending: false,
    failure_kind: None,
    failure_message: "",
    step_consumed: 0,
    step_produced: 0,
    view: b""[:],
    in_pos: 0,
    out_pos: 0,
    out: empty_out.mut_view(),
    out_end: 0,
    empty_out,
  }
  match dictionary {
    Some(dict) => inflater.preload_dictionary(dict)
    None => ()
  }
  inflater
}

///|
/// Whether the end of the DEFLATE stream has been reached.
pub fn Inflater::is_finished(self : Inflater) -> Bool {
  self.mode is Done
}

///|
/// Number of input bytes accepted by the latest `step` call. This is zero
/// initially, after `reset`, after a call raises, and in the stable `Done`
/// state.
pub fn Inflater::last_consumed(self : Inflater) -> Int {
  self.step_consumed
}

///|
/// Number of output bytes written by the latest `step` call. This is zero
/// initially, after `reset`, after a call raises, and in the stable `Done`
/// state.
pub fn Inflater::last_produced(self : Inflater) -> Int {
  self.step_produced
}

///|
/// Preload the history window with the final 32 KiB of a preset dictionary.
fn Inflater::preload_dictionary(self : Inflater, dict : BytesView) -> Unit {
  let start = if dict.length() > window_size {
    dict.length() - window_size
  } else {
    0
  }
  for i in start..<dict.length() {
    self.window[self.wpos & (window_size - 1)] = dict[i]
    self.wpos = self.wpos + 1
  }
  if self.wpos >= window_size {
    self.filled = true
  }
}

///|
/// Reset to the start of a fresh DEFLATE stream, reusing allocations (the
/// 32 KB window and Huffman table storage) across many streams (e.g. ZIP
/// entries). The stale window contents are unreachable afterwards: any
/// distance reaching past the new stream's start is rejected (`dist > wpos`).
/// Pass `dictionary` to preload the fresh stream's history window.
pub fn Inflater::reset(self : Inflater, dictionary? : BytesView) -> Unit {
  self.mode = AtBlock
  self.bitbuf = 0
  self.bit_count = 0
  self.final_block = false
  self.stored_remaining = 0
  self.hl = None
  self.hd = None
  self.hd_fixed = false
  self.wpos = 0
  self.filled = false
  self.copy_remaining = 0
  self.copy_dist = 0
  self.staged_input.clear()
  self.staged_pos = 0
  self.ending = false
  self.failure_kind = None
  self.failure_message = ""
  self.step_consumed = 0
  self.step_produced = 0
  self.view = b""[:]
  self.in_pos = 0
  self.out_pos = 0
  self.out = self.empty_out.mut_view()
  self.out_end = 0
  match dictionary {
    Some(dict) => self.preload_dictionary(dict)
    None => ()
  }
}

// ---- bit reader (raises NeedInput when the current view is exhausted) ----

///|
fn Inflater::fill(self : Inflater, n : Int) -> Unit raise NeedInput {
  while self.bit_count < n {
    let b = if self.staged_pos < self.staged_input.length() {
      let byte = self.staged_input[self.staged_pos]
      self.staged_pos = self.staged_pos + 1
      byte
    } else if self.in_pos < self.view.length() {
      let byte = self.view[self.in_pos]
      self.in_pos = self.in_pos + 1
      byte
    } else {
      raise NeedInput
    }
    self.bitbuf = self.bitbuf | (b.to_int() << self.bit_count)
    self.bit_count = self.bit_count + 8
  }
}

///|
fn Inflater::read_bits(self : Inflater, n : Int) -> Int raise NeedInput {
  self.fill(n)
  let v = self.bitbuf & ((1 << n) - 1)
  self.bitbuf = self.bitbuf >> n
  self.bit_count = self.bit_count - n
  v
}

///|
fn Inflater::huff_sym(self : Inflater, h : HuffmanDecoder) -> Int raise {
  let mut n = h.min
  for ;; {
    self.fill(n)
    let mut chunk = h.chunks[self.bitbuf & 0x1FF]
    n = (chunk & 0xF).reinterpret_as_int()
    if n > huffman_chunk_bits {
      let link = ((self.bitbuf >> huffman_chunk_bits).reinterpret_as_uint() &
      h.link_mask).reinterpret_as_int()
      chunk = h.links[(chunk >> huffman_value_shift).reinterpret_as_int()][link]
      n = (chunk & 0xF).reinterpret_as_int()
    }
    if n <= self.bit_count {
      if n == 0 {
        raise InflateError(Corrupt, "corrupt: bad Huffman code")
      }
      self.bitbuf = self.bitbuf >> n
      self.bit_count = self.bit_count - n
      return (chunk >> huffman_value_shift).reinterpret_as_int()
    }
  }
}

// ---- output + window ----

///|
/// Emit one decoded byte to the output buffer and the history window. The
/// caller guarantees output room before starting a unit / each stored byte.
fn Inflater::emit(self : Inflater, b : Byte) -> Unit {
  self.out.set(self.out_pos, b)
  self.out_pos = self.out_pos + 1
  self.window[self.wpos & (window_size - 1)] = b
  self.wpos = self.wpos + 1
  if !self.filled && self.wpos >= window_size {
    self.filled = true
  }
}

// ---- block handling ----

///|
fn Inflater::read_dynamic(self : Inflater) -> Unit raise {
  let nlit = dynamic_literal_count(self.read_bits(5))
  let ndist = dynamic_distance_count(self.read_bits(5))
  let nclen = self.read_bits(4) + 4
  for i in 0..<nclen {
    self.codebits[code_order[i]] = self.read_bits(3)
  }
  for i in nclen..<code_order.length() {
    self.codebits[code_order[i]] = 0
  }
  if !self.dyn_litlen.initialize(self.codebits[:]) {
    raise InflateError(Corrupt, "corrupt: bad code-length tree")
  }
  let n = nlit + ndist
  let mut i = 0
  while i < n {
    let x = self.huff_sym(self.dyn_litlen)
    if x < 16 {
      self.clbits[i] = x
      i = i + 1
    } else {
      let previous = if i == 0 { None } else { Some(self.clbits[i - 1]) }
      let repeat = interpret_code_length_repeat(x, previous)
      let rep = repeat.base + self.read_bits(repeat.extra_bits)
      if i + rep > n {
        raise InflateError(Corrupt, "corrupt: code-length repeat overflow")
      }
      for _j in 0..<rep {
        self.clbits[i] = repeat.value
        i = i + 1
      }
    }
  }
  if !self.dyn_litlen.initialize(self.clbits[0:nlit]) {
    raise InflateError(Corrupt, "corrupt: bad literal/length tree")
  }
  if !self.dyn_dist.initialize(self.clbits[nlit:nlit + ndist]) {
    raise InflateError(Corrupt, "corrupt: bad distance tree")
  }
}

///|
/// Read the next block's header (and, for dynamic blocks, its Huffman tables).
/// Atomic w.r.t. input: raises `NeedInput` to be retried from the block start.
fn Inflater::parse_block_header(self : Inflater) -> Unit raise {
  self.fill(3)
  self.final_block = (self.bitbuf & 1) == 1
  let btype = (self.bitbuf >> 1) & 3
  self.bitbuf = self.bitbuf >> 3
  self.bit_count = self.bit_count - 3
  if btype == 0 {
    let drop = self.bit_count & 7
    self.bitbuf = self.bitbuf >> drop
    self.bit_count = self.bit_count - drop
    let len = self.read_bits(16)
    let nlen = self.read_bits(16)
    validate_stored_length(len, nlen)
    self.stored_remaining = len
    self.mode = InStored
  } else if btype == 1 {
    self.hl = Some(fixed_huffman_decoder)
    self.hd = None
    self.hd_fixed = true
    self.mode = InHuffman
  } else if btype == 2 {
    self.read_dynamic()
    self.hl = Some(self.dyn_litlen)
    self.hd = Some(self.dyn_dist)
    self.hd_fixed = false
    self.mode = InHuffman
  } else {
    raise InflateError(Corrupt, "corrupt: reserved block type")
  }
}

///|
/// Take the next stored-block byte once byte-aligned: drain the accumulator
/// first, then the input view. Returns None when input is exhausted.
fn Inflater::next_stored_byte(self : Inflater) -> Byte? {
  if self.bit_count >= 8 {
    let b = (self.bitbuf & 0xFF).to_byte()
    self.bitbuf = self.bitbuf >> 8
    self.bit_count = self.bit_count - 8
    Some(b)
  } else if self.staged_pos < self.staged_input.length() {
    let b = self.staged_input[self.staged_pos]
    self.staged_pos = self.staged_pos + 1
    Some(b)
  } else if self.in_pos < self.view.length() {
    let b = self.view[self.in_pos]
    self.in_pos = self.in_pos + 1
    Some(b)
  } else {
    None
  }
}

///|
/// Preserve the unconsumed tail of an incomplete atomic unit. Every byte from
/// the external view is then either permanently decoded or owned here, so the
/// public call may report that complete view as consumed.
fn Inflater::stage_incomplete_input(self : Inflater) -> Unit {
  let kept : Array[Byte] = []
  for i in self.staged_pos..<self.staged_input.length() {
    kept.push(self.staged_input[i])
  }
  for i in self.in_pos..<self.view.length() {
    kept.push(self.view[i])
  }
  self.staged_input = kept
  self.staged_pos = 0
}

///|
/// Drop bytes permanently consumed from the staged atomic tail while retaining
/// an unconsumed suffix across output backpressure.
fn Inflater::compact_staged_input(self : Inflater) -> Unit {
  if self.staged_pos == 0 {
    return
  }
  if self.staged_pos == self.staged_input.length() {
    self.staged_input.clear()
  } else {
    let kept : Array[Byte] = []
    for i in self.staged_pos..<self.staged_input.length() {
      kept.push(self.staged_input[i])
    }
    self.staged_input = kept
  }
  self.staged_pos = 0
}

///|
/// Release call-owned views after every success or error so a suspended engine
/// never pins the caller's network input or mutable output buffer.
fn Inflater::release_step_views(self : Inflater) -> Unit {
  self.view = b""[:]
  self.in_pos = 0
  self.out_pos = 0
  self.out = self.empty_out.mut_view()
  self.out_end = 0
}

///|
/// Copy as many bytes of the in-progress match as fit before `out_end`, leaving
/// the remainder in `copy_remaining` for the next `step`. Reads no input, so it
/// never suspends on `NeedInput`; the window index is recomputed per byte so
/// overlapping copies (run-length expansion) work correctly.
fn Inflater::drain_match(self : Inflater) -> Unit {
  while self.copy_remaining > 0 && self.out_pos < self.out_end {
    let src = (self.wpos - self.copy_dist) & (window_size - 1)
    self.emit(self.window[src])
    self.copy_remaining = self.copy_remaining - 1
  }
}

///|
/// Decode one literal or match into output + window. Returns true at end-of-block.
/// Atomic w.r.t. input via `NeedInput`; the caller guarantees room for at least
/// one byte before calling, and a match too large for the output suspends with
/// `copy_remaining` set (drained by `drain_match` on the next `step`).
fn Inflater::decode_unit(self : Inflater) -> Bool raise {
  let v = self.huff_sym(self.hl.unwrap())
  if v < 256 {
    self.emit(v.to_byte())
    return false
  }
  if v == 256 {
    return true
  }
  if v >= 286 {
    raise InflateError(Corrupt, "corrupt: invalid literal/length code")
  }
  let length_info = length_code_info_table[v - 257]
  let base = length_info >> 3
  let nextra = length_info & 0x7
  let length = if nextra > 0 { base + self.read_bits(nextra) } else { base }
  let dsym = if self.hd_fixed {
    self.fill(5)
    let low5 = self.bitbuf & 0x1F
    self.bitbuf = self.bitbuf >> 5
    self.bit_count = self.bit_count - 5
    reverse8(((low5 << 3) & 0xFF).to_byte()).to_int()
  } else {
    self.huff_sym(self.hd.unwrap())
  }
  if dsym.reinterpret_as_uint() >= max_num_dist.reinterpret_as_uint() {
    raise InflateError(Corrupt, "corrupt: invalid distance code")
  }
  let distance_info = distance_code_info_table[dsym]
  let distance_base = distance_info >> 4
  let distance_extra_bits = distance_info & 0xF
  let dist = if distance_extra_bits == 0 {
    distance_base
  } else {
    distance_base + self.read_bits(distance_extra_bits)
  }
  if !self.filled && !back_reference_distance_is_valid(dist, self.wpos) {
    raise InflateError(Corrupt, "corrupt: distance too far back")
  }
  // All input reads are done; set up the (possibly suspendable) copy. Because
  // copy state is established only here, a `NeedInput` raised above leaves
  // `copy_remaining == 0` and the unit re-runs cleanly.
  self.copy_remaining = length
  self.copy_dist = dist
  self.drain_match()
  false
}

///|
/// Drive the decoder over the currently installed step-local views.
/// The step-local input/output cursors already live on `self`, so returning
/// only `Status` avoids allocating an internal three-tuple that `step` would
/// immediately unpack and discard.
fn Inflater::run_step(self : Inflater) -> Status raise InflateError {
  for ;; {
    match self.mode {
      Done => return Done
      AtBlock => {
        let cb = self.bitbuf
        let cn = self.bit_count
        let staged_pos_mark = self.staged_pos
        let in_pos_mark = self.in_pos
        self.parse_block_header() catch {
          err =>
            match classify_decoder_error(err) {
              DecoderInputExhausted => {
                self.bitbuf = cb
                self.bit_count = cn
                self.staged_pos = staged_pos_mark
                self.in_pos = in_pos_mark
                return NeedMoreInput
              }
              DecoderFailure(kind, message) => raise InflateError(kind, message)
            }
        }
      }
      InStored => {
        while self.stored_remaining > 0 {
          if self.out_pos >= self.out_end {
            return NeedMoreOutput
          }
          match self.next_stored_byte() {
            Some(b) => {
              self.emit(b)
              self.stored_remaining = self.stored_remaining - 1
            }
            None => return NeedMoreInput
          }
        }
        self.mode = if self.final_block { Done } else { AtBlock }
      }
      InHuffman => {
        // Finish any match copy suspended by a full output buffer last step.
        if self.copy_remaining > 0 {
          self.drain_match()
          if self.copy_remaining > 0 {
            return NeedMoreOutput
          }
        }
        // A unit needs room for at least its first byte; the rest of a match
        // suspends via `copy_remaining` rather than requiring 258 bytes upfront.
        if self.out_pos >= self.out_end {
          return NeedMoreOutput
        }
        let cb = self.bitbuf
        let cn = self.bit_count
        let staged_pos_mark = self.staged_pos
        let in_pos_mark = self.in_pos
        let eob = self.decode_unit() catch {
          err =>
            match classify_decoder_error(err) {
              DecoderInputExhausted => {
                self.bitbuf = cb
                self.bit_count = cn
                self.staged_pos = staged_pos_mark
                self.in_pos = in_pos_mark
                return NeedMoreInput
              }
              DecoderFailure(kind, message) => raise InflateError(kind, message)
            }
        }
        if eob {
          self.mode = if self.final_block { Done } else { AtBlock }
        }
      }
    }
  }
}

///|
/// Commit the counters for one normally returning public step.
fn Inflater::finish_step(
  self : Inflater,
  status : Status,
  consumed : Int,
  produced : Int,
) -> Status {
  self.step_consumed = consumed
  self.step_produced = produced
  status
}

///|
/// Run one decompression step. Reads from `input`, writes into `output`, and
/// returns the status. After a normal return, read `last_consumed()` and
/// `last_produced()` for this call's counts, and drop exactly
/// `input[:last_consumed()]`. An empty output makes no progress
/// (`NeedMoreOutput`, zero produced); one output byte always suffices to
/// advance. Both counts are cleared before every call and remain zero if the
/// call raises.
///
/// Headers and Huffman symbols remain atomic internally, but an incomplete
/// unit's small tail is retained by the engine. Therefore callers may feed
/// ordinary non-overlapping chunks: on `NeedMoreInput` the complete supplied
/// view has been accepted and need not be re-presented. Pass `end=true` with
/// the physical final input view; the signal is sticky across output
/// backpressure, and an incomplete stream then raises `InflateError` instead of
/// returning `NeedMoreInput` forever. Once any error is raised, later calls
/// stably raise the same error until `reset()`.
pub fn Inflater::step(
  self : Inflater,
  input : BytesView,
  output : MutArrayView[Byte],
  end? : Bool = false,
) -> Status raise InflateError {
  self.step_consumed = 0
  self.step_produced = 0
  match self.failure_kind {
    Some(kind) => raise InflateError(kind, self.failure_message)
    None => ()
  }
  if end {
    self.ending = true
  }
  self.view = input
  self.in_pos = 0
  self.out_pos = 0
  self.out = output
  self.out_end = output.length()
  let status = self.run_step() catch {
    InflateError(kind, message) => {
      self.failure_kind = Some(kind)
      self.failure_message = message
      self.staged_input.clear()
      self.staged_pos = 0
      self.release_step_views()
      raise InflateError(kind, message)
    }
  }
  let decoded_input = self.in_pos
  let produced = self.out_pos
  let consumed = if status is NeedMoreInput {
    self.stage_incomplete_input()
    if self.ending {
      let message = "unexpected end of input"
      self.failure_kind = Some(Truncated)
      self.failure_message = message
      self.staged_input.clear()
      self.staged_pos = 0
      self.release_step_views()
      raise InflateError(Truncated, message)
    }
    input.length()
  } else {
    self.compact_staged_input()
    decoded_input
  }
  self.release_step_views()
  self.finish_step(status, consumed, produced)
}
