// Huffman decode tables for the decode pipeline: per-symbol code lengths in,
// a zlib-style chunked lookup table out. Shared by the streaming `Inflater`
// and the in-memory `MemDecoder`.

///|
const MAX_CODE_LEN : Int = 16

///|
pub const HUFFMAN_CHUNK_BITS : Int = 9

///|
pub const HUFFMAN_VALUE_SHIFT : Int = 4

///|
/// zlib-style chunked Huffman decode table. `chunk & 0xF` is the code length,
/// For plain tables `chunk >> 4` is the symbol. Native data tables keep the
/// symbol in bits 4..12 and length/distance metadata in bits 13..31. Primary
/// links are never decorated: their value remains a flat link-table offset.
/// Keeping all link tables contiguous removes one pointer
/// chase from the decode hot path.
priv struct HuffmanDecoder {
  mut min : Int
  chunks : FixedArray[UInt]
  mut links : FixedArray[UInt]
  mut link_mask : UInt
}

///|
fn HuffmanDecoder::HuffmanDecoder() -> HuffmanDecoder {
  { min: 0, chunks: FixedArray::make(512, 0U), links: [], link_mask: 0, }
}

///|
/// Build the decode table from per-symbol code lengths. Returns false if the
/// lengths do not form a complete (or valid degenerate) Huffman tree.
/// Optional metadata has one entry per symbol and only uses bits 13..31.
/// Callers supplying it must mask the nine-bit symbol on terminal entries.
fn HuffmanDecoder::initialize(
  self : HuffmanDecoder,
  lengths : ArrayView[Int],
  metadata? : FixedArray[UInt]? = None,
  length_totals? : Bool = false,
) -> Bool {
  if self.min != 0 {
    self.min = 0
    self.links = []
    self.link_mask = 0
  }
  let count = FixedArray::make(MAX_CODE_LEN, 0)
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
  guard max != 0 else {
    self.chunks.fill(0U)
    return true
  }
  let mut code = 0
  let nextcode = FixedArray::make(MAX_CODE_LEN, 0)
  for i in min..<=max {
    code = code << 1
    nextcode[i] = code
    code = code + count[i]
  }
  // Complete trees overwrite every primary entry with a terminal or link.
  // Empty/degenerate/invalid trees must not retain entries from the old tree.
  let complete = code == 1 << max
  if !complete {
    self.chunks.fill(0U)
  }
  guard complete || (code == 1 && max == 1) else { return false }
  self.min = min
  if max > HUFFMAN_CHUNK_BITS {
    let num_links = 1 << (max - HUFFMAN_CHUNK_BITS)
    self.link_mask = (num_links - 1).reinterpret_as_uint()
    let link = nextcode[HUFFMAN_CHUNK_BITS + 1] >> 1
    self.links = FixedArray::make((512 - link) * num_links, 0U)
    for j in link..<512 {
      let mut reverse = reverse16((j & 0xffff).reinterpret_as_uint()).reinterpret_as_int()
      reverse = reverse >> (16 - HUFFMAN_CHUNK_BITS)
      let off = (j - link) * num_links
      self.chunks[reverse] = (off.reinterpret_as_uint() << HUFFMAN_VALUE_SHIFT) |
        (HUFFMAN_CHUNK_BITS + 1).reinterpret_as_uint()
    }
  }
  for idx, n in lengths {
    if n == 0 {
      continue
    }
    let code = nextcode[n]
    nextcode[n] = nextcode[n] + 1
    let extra = if metadata is Some(values) { values[idx] } else { 0U }
    // Length metadata uses only bits 13..24. Store code + extra-bit count
    // above it so the native loop can advance directly to the distance code.
    let extra = if length_totals && extra != 0U {
      extra | ((n.reinterpret_as_uint() + ((extra >> 13) & 7U)) << 25)
    } else {
      extra
    }
    let chunk = (idx << HUFFMAN_VALUE_SHIFT).reinterpret_as_uint() |
      n.reinterpret_as_uint() |
      extra
    let mut reverse = reverse16((code & 0xffff).reinterpret_as_uint()).reinterpret_as_int()
    reverse = reverse >> (16 - n)
    if n <= HUFFMAN_CHUNK_BITS {
      for off = reverse; off < self.chunks.length(); off = off + (1 << n) {
        self.chunks[off] = chunk
      }
    } else {
      let j = reverse & 0x1FF
      let value = (self.chunks[j] >> HUFFMAN_VALUE_SHIFT).reinterpret_as_int()
      let num_links = 1 << (max - HUFFMAN_CHUNK_BITS)
      reverse = reverse >> HUFFMAN_CHUNK_BITS
      for off = reverse
          off < num_links
          off = off + (1 << (n - HUFFMAN_CHUNK_BITS)) {
        self.links[value + off] = chunk
      }
    }
  }
  true
}

///|
/// The fixed literal/length Huffman table (RFC 1951 §3.2.6), built from its
/// canonical code lengths so we never transcribe a precomputed table.
fn make_fixed_huffman_decoder() -> HuffmanDecoder {
  let lengths = FixedArray::make(288, 0)
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
  let h = HuffmanDecoder()
  let _ = h.initialize(lengths[:])
  h
}

///|
let fixed_huffman_decoder : HuffmanDecoder = make_fixed_huffman_decoder()

///|
#cfg(target="native")
priv enum InflateAlphabet {
  LiteralLength
  Distance
}

///|
#cfg(target="native")
let native_length_metadata : FixedArray[UInt] = FixedArray::makei(288, symbol => {
  if symbol >= 257 && symbol < 286 {
    length_code_info_table[symbol - 257].reinterpret_as_uint() << 13
  } else {
    0U
  }
})

///|
#cfg(target="native")
let native_distance_metadata : FixedArray[UInt] = FixedArray::makei(32, symbol => {
  if symbol < MAX_NUM_DIST {
    distance_code_info_table[symbol].reinterpret_as_uint() << 13
  } else {
    0U
  }
})

///|
#cfg(target="native")
fn HuffmanDecoder::initialize_data(
  self : HuffmanDecoder,
  lengths : ArrayView[Int],
  alphabet : InflateAlphabet,
) -> Bool {
  let metadata = match alphabet {
    LiteralLength => native_length_metadata
    Distance => native_distance_metadata
  }
  self.initialize(
    lengths,
    metadata=Some(metadata),
    length_totals=alphabet is LiteralLength,
  )
}

///|
// The entry points are separate so other backends keep plain tables without
// constructing native-only alphabet tags or metadata arrays.
#cfg(target="native")
fn HuffmanDecoder::initialize_litlen(
  self : HuffmanDecoder,
  lengths : ArrayView[Int],
) -> Bool {
  self.initialize_data(lengths, LiteralLength)
}

///|
#cfg(target="native")
fn HuffmanDecoder::initialize_distance(
  self : HuffmanDecoder,
  lengths : ArrayView[Int],
) -> Bool {
  self.initialize_data(lengths, Distance)
}

///|
#cfg(not(target="native"))
fn HuffmanDecoder::initialize_litlen(
  self : HuffmanDecoder,
  lengths : ArrayView[Int],
) -> Bool {
  self.initialize(lengths)
}

///|
#cfg(not(target="native"))
fn HuffmanDecoder::initialize_distance(
  self : HuffmanDecoder,
  lengths : ArrayView[Int],
) -> Bool {
  self.initialize(lengths)
}
