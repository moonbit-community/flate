///|
/// In-memory DEFLATE decoder. Reads from a `Bytes` and appends to `out`.
priv struct MemDecoder {
  input : Bytes
  mut pos : Int // next input byte
  mut bitbuf : UInt // LSB-first bit accumulator
  mut bit_count : Int // valid bits in `bitbuf`
  out : Array[Byte]
  dyn_litlen : HuffmanDecoder // literal/length (also reused for the code-length tree)
  dyn_dist : HuffmanDecoder // distance
  clbits : Array[Int] // decoded literal+distance code lengths
  codebits : Array[Int] // code-length code lengths
}

///|
fn MemDecoder::new(input : Bytes) -> MemDecoder {
  {
    input,
    pos: 0,
    bitbuf: 0,
    bit_count: 0,
    out: [],
    dyn_litlen: HuffmanDecoder::new(),
    dyn_dist: HuffmanDecoder::new(),
    clbits: Array::make(max_num_lit + max_num_dist, 0),
    codebits: Array::make(num_codes, 0),
  }
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
      raise InflateError("unexpected end of input")
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
        raise InflateError("unexpected end of input")
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
        raise InflateError("corrupt: bad Huffman code")
      }
      self.bitbuf = self.bitbuf >> n
      self.bit_count = self.bit_count - n
      return (chunk >> huffman_value_shift).reinterpret_as_int()
    }
  }
}

///|
fn MemDecoder::distance(
  self : MemDecoder,
  dsym : Int,
) -> Int raise InflateError {
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
fn MemDecoder::decode_block(
  self : MemDecoder,
  hl : HuffmanDecoder,
  hd : HuffmanDecoder?,
) -> Unit raise InflateError {
  for ;; {
    let v = self.huff_sym(hl)
    if v < 256 {
      self.out.push(v.to_byte())
    } else if v == 256 {
      return
    } else if v < 286 {
      let (base, nextra) = length_base_extra(v)
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
      let dist = self.distance(dsym)
      if dist > self.out.length() {
        raise InflateError("corrupt: distance too far back")
      }
      let start = self.out.length() - dist
      for k in 0..<length {
        self.out.push(self.out[start + k])
      }
    } else {
      raise InflateError("corrupt: invalid literal/length code")
    }
  }
}

///|
fn MemDecoder::stored_block(self : MemDecoder) -> Unit raise InflateError {
  // Byte-align by discarding the rest of the current partial byte.
  self.bitbuf = 0
  self.bit_count = 0
  if self.pos + 4 > self.input.length() {
    raise InflateError("unexpected end of input")
  }
  let len = self.input[self.pos].to_int() |
    (self.input[self.pos + 1].to_int() << 8)
  let nlen = self.input[self.pos + 2].to_int() |
    (self.input[self.pos + 3].to_int() << 8)
  self.pos = self.pos + 4
  if len != (nlen ^ 0xFFFF) {
    raise InflateError("stored block length mismatch")
  }
  if self.pos + len > self.input.length() {
    raise InflateError("unexpected end of input")
  }
  for k in 0..<len {
    self.out.push(self.input[self.pos + k])
  }
  self.pos = self.pos + len
}

///|
fn MemDecoder::read_dynamic(self : MemDecoder) -> Unit raise InflateError {
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
fn MemDecoder::run(self : MemDecoder) -> Unit raise InflateError {
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
      raise InflateError("corrupt: reserved block type")
    }
    if bfinal {
      break
    }
  }
}

///|
/// Decompress a complete raw DEFLATE stream held entirely in memory
pub fn inflate_all(input : Bytes) -> Bytes raise InflateError {
  let d = MemDecoder::new(input)
  d.run()
  Bytes::from_array(d.out)
}
