///|
/// In-memory DEFLATE decoder. Reads from a `Bytes` and appends to `out`.
priv struct MemDecoder {
  input : Bytes
  mut pos : Int // next input byte
  mut bitbuf : UInt // LSB-first bit accumulator
  mut bit_count : Int // valid bits in `bitbuf`
  out : Array[Byte]
  cancelled : () -> Bool // polled every `cancel_granularity` produced bytes
  mut next_cancel : Int // poll `cancelled` once `out` reaches this length
  dyn_litlen : HuffmanDecoder // literal/length (also reused for the code-length tree)
  dyn_dist : HuffmanDecoder // distance
  clbits : Array[Int] // decoded literal+distance code lengths
  codebits : Array[Int] // code-length code lengths
}

///|
let cancel_granularity = 4096

///|
/// Output chunk size for the streaming one-shot drivers: each `step` call
/// writes into this scratch, so cancellation is polled at this granularity.
let inflate_scratch_size = 8192

///|
fn MemDecoder::new(input : Bytes, cancelled : () -> Bool) -> MemDecoder {
  {
    input,
    pos: 0,
    bitbuf: 0,
    bit_count: 0,
    out: [],
    cancelled,
    next_cancel: 0,
    dyn_litlen: HuffmanDecoder::new(),
    dyn_dist: HuffmanDecoder::new(),
    clbits: Array::make(max_num_lit + max_num_dist, 0),
    codebits: Array::make(num_codes, 0),
  }
}

///|
fn MemDecoder::check_cancel(self : MemDecoder) -> Unit raise InflateError {
  if self.out.length() >= self.next_cancel {
    if (self.cancelled)() {
      raise InflateError(Cancelled, "cancelled by caller")
    }
    self.next_cancel = self.out.length() + cancel_granularity
  }
}

///|
fn MemDecoder::push(self : MemDecoder, b : Byte) -> Unit raise InflateError {
  self.out.push(b)
  self.check_cancel()
}

///|
fn MemDecoder::pull_byte(self : MemDecoder) -> Bool {
  if self.pos >= self.input.length() {
    return false
  }
  self.bitbuf = self.bitbuf | (self.input[self.pos].to_uint() << self.bit_count)
  self.bit_count = self.bit_count + 8
  self.pos = self.pos + 1
  true
}

///|
fn MemDecoder::need(self : MemDecoder, n : Int) -> Unit raise InflateError {
  while self.bit_count < n {
    if !self.pull_byte() {
      raise InflateError(Truncated, "unexpected end of input")
    }
  }
}

///|
fn MemDecoder::read_bits(self : MemDecoder, n : Int) -> Int raise InflateError {
  self.need(n)
  let v = (self.bitbuf & ((1U << n) - 1)).reinterpret_as_int()
  self.bitbuf = self.bitbuf >> n
  self.bit_count = self.bit_count - n
  v
}

///|
fn MemDecoder::huff_sym(
  self : MemDecoder,
  h : HuffmanDecoder,
) -> Int raise InflateError {
  let mut n = h.min
  for ;; {
    while self.bit_count < n {
      if !self.pull_byte() {
        raise InflateError(Truncated, "unexpected end of input")
      }
    }
    let mut chunk = h.chunks[(self.bitbuf & 0x1FF).reinterpret_as_int()]
    n = (chunk & 0xF).reinterpret_as_int()
    if n > huffman_chunk_bits {
      chunk = h.links[(chunk >> huffman_value_shift).reinterpret_as_int()][((
          self.bitbuf >> huffman_chunk_bits
        ) &
        h.link_mask).reinterpret_as_int()]
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

///|
fn MemDecoder::decode_block(
  self : MemDecoder,
  hl : HuffmanDecoder,
  hd : HuffmanDecoder?,
) -> Unit raise InflateError {
  for ;; {
    let v = self.huff_sym(hl)
    if v < 256 {
      self.push(v.to_byte())
    } else if v == 256 {
      return
    } else if v < 286 {
      let length_info = length_code_info_table[v - 257]
      let base = length_info >> 3
      let nextra = length_info & 0x7
      let length = if nextra > 0 { base + self.read_bits(nextra) } else { base }
      let dsym = match hd {
        Some(h) => self.huff_sym(h)
        None => {
          self.need(5)
          let low5 = self.bitbuf & 0x1F
          self.bitbuf = self.bitbuf >> 5
          self.bit_count = self.bit_count - 5
          reverse8(((low5 << 3) & 0xFF).reinterpret_as_int().to_byte()).to_int()
        }
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
      let available_history = self.out.length()
      if available_history < window_size &&
        !back_reference_distance_is_valid(dist, available_history) {
        raise InflateError(Corrupt, "corrupt: distance too far back")
      }
      let start = available_history - dist
      for k in 0..<length {
        self.push(self.out[start + k])
      }
    } else {
      raise InflateError(Corrupt, "corrupt: invalid literal/length code")
    }
  }
}

///|
fn MemDecoder::stored_block(self : MemDecoder) -> Unit raise InflateError {
  // Byte-align by discarding the rest of the current partial byte.
  self.bitbuf = 0
  self.bit_count = 0
  if self.pos + 4 > self.input.length() {
    raise InflateError(Truncated, "unexpected end of input")
  }
  let len = self.input[self.pos].to_int() |
    (self.input[self.pos + 1].to_int() << 8)
  let nlen = self.input[self.pos + 2].to_int() |
    (self.input[self.pos + 3].to_int() << 8)
  self.pos = self.pos + 4
  validate_stored_length(len, nlen)
  if self.pos + len > self.input.length() {
    raise InflateError(Truncated, "unexpected end of input")
  }
  for k in 0..<len {
    self.push(self.input[self.pos + k])
  }
  self.pos = self.pos + len
}

///|
fn MemDecoder::read_dynamic(self : MemDecoder) -> Unit raise InflateError {
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
fn MemDecoder::run(self : MemDecoder) -> Unit raise InflateError {
  self.check_cancel()
  for ;; {
    self.need(3)
    let bfinal = (self.bitbuf & 1) == 1
    let btype = ((self.bitbuf >> 1) & 3).reinterpret_as_int()
    self.bitbuf = self.bitbuf >> 3
    self.bit_count = self.bit_count - 3
    if btype == 0 {
      self.stored_block()
    } else if btype == 1 {
      self.decode_block(fixed_huffman_decoder, None)
    } else if btype == 2 {
      self.read_dynamic()
      self.decode_block(self.dyn_litlen, Some(self.dyn_dist))
    } else {
      raise InflateError(Corrupt, "corrupt: reserved block type")
    }
    if bfinal {
      break
    }
  }
}

///|
/// Decompress a raw DEFLATE stream held entirely in memory. Bytes after the
/// final block are ignored; use `inflate_exact` when an exact framing boundary
/// is required. The output grows without bound; for untrusted input use
/// `inflate_all_limited` or drive `Inflater` with caller-sized output buffers.
/// If supplied, `cancelled` is polled at entry and then every 4096 produced
/// bytes; returning `true` raises `InflateError(Cancelled, _)`.
pub fn inflate_all(
  input : Bytes,
  cancelled? : () -> Bool = () => false,
) -> Bytes raise InflateError {
  let d = MemDecoder::new(input, cancelled)
  d.run()
  Bytes::from_array(d.out)
}

///|
/// Drive the streaming inflater over an in-memory input. If `exact` is true,
/// reject bytes after the final DEFLATE block. If `max_output` is present, one
/// fixed scratch buffer may be filled past that boundary internally, but no
/// oversized result is returned. `cancelled` is polled at entry and once per
/// step (every 8192 produced bytes); returning `true` raises
/// `InflateError(Cancelled, _)`.
fn inflate_streaming_all(
  input : Bytes,
  max_output : Int?,
  exact : Bool,
  cancelled : () -> Bool,
) -> Bytes raise InflateError {
  guard !cancelled() else {
    raise InflateError(Cancelled, "cancelled by caller")
  }
  let inflater = Inflater::new()
  let scratch = FixedArray::make(inflate_scratch_size, b'\x00')
  let decoded : Array[Byte] = []
  let mut input_pos = 0
  for ;; {
    let status = inflater.step(input[input_pos:], scratch.mut_view())
    let consumed = inflater.last_consumed()
    let produced = inflater.last_produced()
    input_pos = input_pos + consumed
    guard !cancelled() else {
      raise InflateError(Cancelled, "cancelled by caller")
    }
    guard max_output.map_or(true, limit => produced <= limit - decoded.length()) else {
      raise InflateError(
        OutputLimitExceeded,
        "decoded output exceeds max_output",
      )
    }
    for i in 0..<produced {
      decoded.push(scratch[i])
    }
    match status {
      Done => {
        if exact && input_pos != input.length() {
          raise InflateError(TrailingData, "trailing data after DEFLATE stream")
        }
        return Bytes::from_array(decoded)
      }
      NeedMoreOutput => ()
      NeedMoreInput => raise InflateError(Truncated, "unexpected end of input")
    }
  }
}

///|
/// Decompress exactly one raw DEFLATE stream. Unlike `inflate_all`, this rejects
/// any bytes after the final block.
///
/// Optional controls:
///  - `max_output`: decoded output beyond this size raises
///    `InflateError(OutputLimitExceeded, _)`. A negative value is rejected the
///    same way.
///  - `cancelled`: polled at entry and then once per internal step (every 8192
///    produced bytes); returning `true` raises `InflateError(Cancelled, _)`.
///  - `preallocated`: when `true`, decode runs twice — a counting pass that
///    validates the whole stream, then a second pass filling one exactly sized
///    allocation. Peak memory stays at roughly one decoded output, at the cost
///    of roughly double the decode work; the default `false` grows one buffer
///    in a single pass, trading transient memory for one decode pass.
pub fn inflate_exact(
  input : Bytes,
  max_output? : Int? = None,
  cancelled? : () -> Bool = () => false,
  preallocated? : Bool = false,
) -> Bytes raise InflateError {
  let limit = match max_output {
    Some(limit) if limit < 0 =>
      raise InflateError(OutputLimitExceeded, "max_output must be non-negative")
    _ => max_output
  }
  if preallocated {
    inflate_preallocated(input, limit, cancelled)
  } else {
    inflate_streaming_all(input, limit, true, cancelled)
  }
}

///|
/// Drive one inflater over the whole in-memory input, delivering produced
/// chunks to `emit` (called once per step with the scratch contents). Returns
/// the total number of bytes produced. `max_output` raises once the total
/// exceeds it; `exact` rejects bytes after the final block; `cancelled` is
/// polled once per step and raises `InflateError(Cancelled, _)`.
fn inflate_drive(
  inflater : Inflater,
  input : Bytes,
  max_output : Int?,
  exact : Bool,
  cancelled : () -> Bool,
  emit : (FixedArray[Byte], Int) -> Unit,
) -> Int raise InflateError {
  let scratch = FixedArray::make(inflate_scratch_size, b'\x00')
  let mut total = 0
  let mut input_pos = 0
  for ;; {
    let status = inflater.step(input[input_pos:], scratch.mut_view(), end=true)
    let consumed = inflater.last_consumed()
    let produced = inflater.last_produced()
    input_pos = input_pos + consumed
    total = total + produced
    guard !cancelled() else {
      raise InflateError(Cancelled, "cancelled by caller")
    }
    guard max_output.map_or(true, limit => total <= limit) else {
      raise InflateError(
        OutputLimitExceeded,
        "decoded output exceeds max_output",
      )
    }
    emit(scratch, produced)
    // `Inflater::step(end=true)` raises `Truncated` on exhausted input, so
    // only `Done` and `NeedMoreOutput` can be returned here.
    guard status is Done else { continue }
    if exact && input_pos != input.length() {
      raise InflateError(TrailingData, "trailing data after DEFLATE stream")
    }
    return total
  }
}

///|
/// The replay pass must produce exactly the size measured by the counting pass.
/// A mismatch indicates an internal decoder invariant failure rather than bad
/// caller input, so this defensive branch is excluded from behavior coverage.
#coverage.skip
fn validate_preallocation_size(
  size : Int,
  filled : Int,
) -> Unit raise InflateError {
  if filled != size {
    raise InflateError(Corrupt, "corrupt: preallocation size mismatch")
  }
}

///|
/// `inflate_exact` with `preallocated=true`: validate and count in one pass
/// over an 8 KiB scratch, then replay the deterministic decode into one exact
/// allocation (the same `Inflater` is reused via `reset`).
fn inflate_preallocated(
  input : Bytes,
  max_output : Int?,
  cancelled : () -> Bool,
) -> Bytes raise InflateError {
  guard !cancelled() else {
    raise InflateError(Cancelled, "cancelled by caller")
  }
  let inflater = Inflater::new()
  let size = inflate_drive(inflater, input, max_output, true, cancelled, (
    _scratch,
    _produced,
  ) => ())
  inflater.reset()
  let buf = Array::make(size, b'\x00')
  let mut filled = 0
  ignore(
    inflate_drive(inflater, input, None, true, cancelled, (scratch, produced) => {
      for i in 0..<produced {
        buf[filled + i] = scratch[i]
      }
      filled = filled + produced
    }),
  )
  validate_preallocation_size(size, filled)
  Bytes::from_array(buf)
}

///|
/// Decompress one raw DEFLATE stream without allowing the returned output to
/// exceed `max_output`. Bytes after the final block retain `inflate_all`'s
/// prefix semantics and are ignored. `cancelled` follows `inflate_all`'s
/// polling contract.
pub fn inflate_all_limited(
  input : Bytes,
  max_output~ : Int,
  cancelled? : () -> Bool = () => false,
) -> Bytes raise InflateError {
  guard max_output >= 0 else {
    raise InflateError(OutputLimitExceeded, "max_output must be non-negative")
  }
  inflate_streaming_all(input, Some(max_output), false, cancelled)
}
