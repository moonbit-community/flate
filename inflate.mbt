// Streaming, suspendable DEFLATE decoder (RFC 1951)
//
// Suspension model:
//  - Input: each block header and each literal/match "unit" is decoded
//    atomically. A bit read past the end of the current input raises the
//    internal `NeedInput`; `step` rewinds (bitbuf, bit_count, in_pos) and returns
//    `NeedMoreInput`, so the unit re-runs unchanged once more input arrives.
//  - Output: a unit needs room for only its first byte; a match longer than the
//    remaining output is copied in pieces, with `copy_remaining`/`copy_dist`
//    carrying the rest to the next `step`. Stored blocks copy byte-by-byte and
//    suspend on either side as needed.
//  - Back-references read from a 32 KB circular history window.

///|
/// Error raised when a DEFLATE stream is malformed.
pub suberror InflateError {
  InflateError(String)
}

///|
/// Internal control-flow signal: the current input view was exhausted mid-unit.
priv suberror NeedInput

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
/// (`out_off..<out_off+out_len`): a match too large for the buffer is copied in
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
  // Step-local cursors (reset on each `step`).
  priv mut view : BytesView
  priv mut in_pos : Int
  priv mut out_pos : Int
  priv mut out : FixedArray[Byte]
  priv mut out_end : Int // one past the last writable index in `out`
}

///|
/// Create a fresh decompressor positioned at the start of a DEFLATE stream.
pub fn Inflater::new() -> Inflater {
  {
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
    dyn_litlen: HuffmanDecoder::new(),
    dyn_dist: HuffmanDecoder::new(),
    clbits: Array::make(max_num_lit + max_num_dist, 0),
    codebits: Array::make(num_codes, 0),
    copy_remaining: 0,
    copy_dist: 0,
    view: b""[:],
    in_pos: 0,
    out_pos: 0,
    out: FixedArray::make(0, b'\x00'),
    out_end: 0,
  }
}

///|
/// Whether the end of the DEFLATE stream has been reached.
pub fn Inflater::is_finished(self : Inflater) -> Bool {
  self.mode is Done
}

///|
/// Preload the history window with a preset dictionary (the last 32 KB of
/// `dict`), so the stream's back-references may reach into it (zlib
/// `inflateSetDictionary`). Must be called on a fresh stream — right after
/// `new()` or `reset()`, before any input.
pub fn Inflater::set_dictionary(self : Inflater, dict : BytesView) -> Unit {
  guard self.wpos == 0 && self.bit_count == 0 && self.mode is AtBlock else {
    abort("Inflater::set_dictionary: stream already started")
  }
  let start = if dict.length() > window_size {
    dict.length() - window_size
  } else {
    0
  }
  for i in start..<dict.length() {
    self.window[self.wpos & (window_size - 1)] = dict[i]
    self.wpos = self.wpos + 1
  }
}

///|
/// Reset to the start of a fresh DEFLATE stream, reusing allocations (the
/// 32 KB window and Huffman table storage) across many streams (e.g. ZIP
/// entries). The stale window contents are unreachable afterwards: any
/// distance reaching past the new stream's start is rejected (`dist > wpos`).
/// A preset dictionary, if any, must be set again.
pub fn Inflater::reset(self : Inflater) -> Unit {
  self.mode = AtBlock
  self.bitbuf = 0
  self.bit_count = 0
  self.final_block = false
  self.stored_remaining = 0
  self.hl = None
  self.hd = None
  self.hd_fixed = false
  self.wpos = 0
  self.copy_remaining = 0
  self.copy_dist = 0
}

// ---- bit reader (raises NeedInput when the current view is exhausted) ----

///|
fn Inflater::fill(self : Inflater, n : Int) -> Unit raise NeedInput {
  while self.bit_count < n {
    if self.in_pos >= self.view.length() {
      raise NeedInput
    }
    self.bitbuf = self.bitbuf |
      (self.view[self.in_pos].to_int() << self.bit_count)
    self.bit_count = self.bit_count + 8
    self.in_pos = self.in_pos + 1
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
        raise InflateError("corrupt: bad Huffman code")
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
  self.out[self.out_pos] = b
  self.out_pos = self.out_pos + 1
  self.window[self.wpos & (window_size - 1)] = b
  self.wpos = self.wpos + 1
}

// ---- block handling ----

///|
fn Inflater::distance(self : Inflater, dsym : Int) -> Int raise {
  if dsym < 4 {
    dsym + 1
  } else if dsym < max_num_dist {
    let extra_bits = (dsym - 2) >> 1
    let extra = ((dsym & 1) << extra_bits) | self.read_bits(extra_bits)
    (1 << (extra_bits + 1)) + 1 + extra
  } else {
    raise InflateError("corrupt: invalid distance code")
  }
}

///|
fn Inflater::read_dynamic(self : Inflater) -> Unit raise {
  let nlit = self.read_bits(5) + 257
  if nlit > max_num_lit {
    raise InflateError("corrupt: too many literal codes")
  }
  let ndist = self.read_bits(5) + 1
  if ndist > max_num_dist {
    raise InflateError("corrupt: too many distance codes")
  }
  let nclen = self.read_bits(4) + 4
  for i in 0..<nclen {
    self.codebits[code_order[i]] = self.read_bits(3)
  }
  for i in nclen..<code_order.length() {
    self.codebits[code_order[i]] = 0
  }
  if !self.dyn_litlen.initialize(self.codebits[:]) {
    raise InflateError("corrupt: bad code-length tree")
  }
  let n = nlit + ndist
  let mut i = 0
  while i < n {
    let x = self.huff_sym(self.dyn_litlen)
    if x < 16 {
      self.clbits[i] = x
      i = i + 1
    } else {
      let mut rep = 0
      let mut extra_bits = 0
      let mut repeat_val = 0
      if x == 16 {
        if i == 0 {
          raise InflateError("corrupt: repeat with no previous length")
        }
        rep = 3
        extra_bits = 2
        repeat_val = self.clbits[i - 1]
      } else if x == 17 {
        rep = 3
        extra_bits = 3
      } else if x == 18 {
        rep = 11
        extra_bits = 7
      } else {
        raise InflateError("corrupt: bad code-length symbol")
      }
      rep = rep + self.read_bits(extra_bits)
      if i + rep > n {
        raise InflateError("corrupt: code-length repeat overflow")
      }
      for _j in 0..<rep {
        self.clbits[i] = repeat_val
        i = i + 1
      }
    }
  }
  if !self.dyn_litlen.initialize(self.clbits[0:nlit]) {
    raise InflateError("corrupt: bad literal/length tree")
  }
  if !self.dyn_dist.initialize(self.clbits[nlit:nlit + ndist]) {
    raise InflateError("corrupt: bad distance tree")
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
    if len != (nlen ^ 0xFFFF) {
      raise InflateError("stored block length mismatch")
    }
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
    raise InflateError("corrupt: reserved block type")
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
  } else if self.in_pos < self.view.length() {
    let b = self.view[self.in_pos]
    self.in_pos = self.in_pos + 1
    Some(b)
  } else {
    None
  }
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
    raise InflateError("corrupt: invalid literal/length code")
  }
  let (base, nextra) = length_base_extra(v)
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
  let dist = self.distance(dsym)
  if dist > self.wpos {
    raise InflateError("corrupt: distance too far back")
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
/// Run one decompression step. Reads from `input`, writes into `output` from
/// `out_off`. Returns `(status, consumed, produced)`.
pub fn Inflater::step(
  self : Inflater,
  input : BytesView,
  output : FixedArray[Byte],
  out_off~ : Int,
  out_len? : Int = output.length() - out_off,
) -> (Status, Int, Int) raise {
  self.view = input
  self.in_pos = 0
  self.out_pos = out_off
  self.out = output
  self.out_end = out_off + out_len
  for ;; {
    match self.mode {
      Done => return (Done, self.in_pos, self.out_pos - out_off)
      AtBlock => {
        let cb = self.bitbuf
        let cn = self.bit_count
        let in_pos_mark = self.in_pos
        self.parse_block_header() catch {
          NeedInput => {
            self.bitbuf = cb
            self.bit_count = cn
            self.in_pos = in_pos_mark
            return (NeedMoreInput, in_pos_mark, self.out_pos - out_off)
          }
          err => raise err
        }
      }
      InStored => {
        while self.stored_remaining > 0 {
          if self.out_pos >= self.out_end {
            return (NeedMoreOutput, self.in_pos, self.out_pos - out_off)
          }
          match self.next_stored_byte() {
            Some(b) => {
              self.emit(b)
              self.stored_remaining = self.stored_remaining - 1
            }
            None => return (NeedMoreInput, self.in_pos, self.out_pos - out_off)
          }
        }
        self.mode = if self.final_block { Done } else { AtBlock }
      }
      InHuffman => {
        // Finish any match copy suspended by a full output buffer last step.
        if self.copy_remaining > 0 {
          self.drain_match()
          if self.copy_remaining > 0 {
            return (NeedMoreOutput, self.in_pos, self.out_pos - out_off)
          }
        }
        // A unit needs room for at least its first byte; the rest of a match
        // suspends via `copy_remaining` rather than requiring 258 bytes upfront.
        if self.out_pos >= self.out_end {
          return (NeedMoreOutput, self.in_pos, self.out_pos - out_off)
        }
        let cb = self.bitbuf
        let cn = self.bit_count
        let in_pos_mark = self.in_pos
        let eob = self.decode_unit() catch {
          NeedInput => {
            self.bitbuf = cb
            self.bit_count = cn
            self.in_pos = in_pos_mark
            return (NeedMoreInput, in_pos_mark, self.out_pos - out_off)
          }
          err => raise err
        }
        if eob {
          self.mode = if self.final_block { Done } else { AtBlock }
        }
      }
    }
  }
}
