// Huffman decode tables for the decode pipeline: per-symbol code lengths in,
// a zlib-style chunked lookup table out. Shared by the streaming `Inflater`
// and the in-memory `MemDecoder`.

///|
let max_code_len = 16

///|
let huffman_chunk_bits = 9

///|
let huffman_value_shift = 4

///|
/// zlib-style chunked Huffman decode table. `chunk & 0xF` is the code length,
/// `chunk >> 4` is the value (or a link-table index for codes wider than 9 bits).
priv struct HuffmanDecoder {
  mut min : Int
  mut chunks : Array[UInt]
  mut links : Array[Array[UInt]]
  mut link_mask : UInt
}

///|
fn HuffmanDecoder::new() -> HuffmanDecoder {
  { min: 0, chunks: Array::make(512, 0U), links: [], link_mask: 0 }
}

///|
/// Build the decode table from per-symbol code lengths. Returns false if the
/// lengths do not form a complete (or valid degenerate) Huffman tree.
fn HuffmanDecoder::initialize(
  self : HuffmanDecoder,
  lengths : ArrayView[Int],
) -> Bool {
  if self.min != 0 {
    self.min = 0
    self.chunks = Array::make(512, 0U)
    self.links = []
    self.link_mask = 0
  }
  let count = Array::make(max_code_len, 0)
  let mut min = 0
  let mut max = 0
  for n in lengths {
    if n == 0 {
      continue
    }
    if min == 0 || n < min {
      min = n
    }
    if n > max {
      max = n
    }
    count[n] = count[n] + 1
  }
  if max == 0 {
    return true
  }
  let mut code = 0
  let nextcode = Array::make(max_code_len, 0)
  for i in min..<=max {
    code = code << 1
    nextcode[i] = code
    code = code + count[i]
  }
  if code != 1 << max && !(code == 1 && max == 1) {
    return false
  }
  self.min = min
  if max > huffman_chunk_bits {
    let num_links = 1 << (max - huffman_chunk_bits)
    self.link_mask = (num_links - 1).reinterpret_as_uint()
    let link = nextcode[huffman_chunk_bits + 1] >> 1
    self.links = Array::make(512 - link, ([] : Array[UInt]))
    for j in link..<512 {
      let mut reverse = reverse16((j & 0xffff).reinterpret_as_uint()).reinterpret_as_int()
      reverse = reverse >> (16 - huffman_chunk_bits)
      let off = j - link
      self.chunks[reverse] = (off.reinterpret_as_uint() << huffman_value_shift) |
        (huffman_chunk_bits + 1).reinterpret_as_uint()
      self.links[off] = Array::make(num_links, 0U)
    }
  }
  for idx, n in lengths {
    if n == 0 {
      continue
    }
    let code = nextcode[n]
    nextcode[n] = nextcode[n] + 1
    let chunk = (idx << huffman_value_shift).reinterpret_as_uint() |
      n.reinterpret_as_uint()
    let mut reverse = reverse16((code & 0xffff).reinterpret_as_uint()).reinterpret_as_int()
    reverse = reverse >> (16 - n)
    if n <= huffman_chunk_bits {
      for off = reverse; off < self.chunks.length(); off = off + (1 << n) {
        self.chunks[off] = chunk
      }
    } else {
      let j = reverse & 0x1FF
      let value = (self.chunks[j] >> huffman_value_shift).reinterpret_as_int()
      let linktab = self.links[value]
      reverse = reverse >> huffman_chunk_bits
      for off = reverse
          off < linktab.length()
          off = off + (1 << (n - huffman_chunk_bits)) {
        linktab[off] = chunk
      }
    }
  }
  true
}

///|
/// The fixed literal/length Huffman table (RFC 1951 §3.2.6), built from its
/// canonical code lengths so we never transcribe a precomputed table.
fn make_fixed_huffman_decoder() -> HuffmanDecoder {
  let lengths = Array::make(288, 0)
  for i in 0..<144 {
    lengths[i] = 8
  }
  for i in 144..<256 {
    lengths[i] = 9
  }
  for i in 256..<280 {
    lengths[i] = 7
  }
  for i in 280..<288 {
    lengths[i] = 8
  }
  let h = HuffmanDecoder::new()
  let _ = h.initialize(lengths[:])
  h
}

///|
let fixed_huffman_decoder : HuffmanDecoder = make_fixed_huffman_decoder()
