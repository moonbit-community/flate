// LSB-first bit sink for the encode pipeline. DEFLATE packs bits LSB-first
// into bytes, but Huffman codes are written MSB-first.

///|
priv struct BitWriter {
  out : Array[Byte]
  mut bitbuf : Int
  mut bit_count : Int // bits currently held in `bitbuf`, not yet flushed to a byte
  direct_output : FixedArray[Byte]?
  mut direct_pos : Int
  mut overflowed : Bool
}

///|
fn BitWriter::BitWriter() -> BitWriter {
  {
    out: [],
    bitbuf: 0,
    bit_count: 0,
    direct_output: None,
    direct_pos: 0,
    overflowed: false,
  }
}

///|
/// Create a bit writer that emits directly into `output`. Writes past its end
/// are recorded so the caller can report capacity exhaustion after encoding.
fn BitWriter::into(output : FixedArray[Byte]) -> BitWriter {
  {
    out: [],
    bitbuf: 0,
    bit_count: 0,
    direct_output: Some(output),
    direct_pos: 0,
    overflowed: false,
  }
}

///|
/// Emit one whole byte to the configured destination. The normal writer grows
/// `out`; a direct writer keeps counting after capacity exhaustion so all block
/// planning code can remain allocation-free and branch-free at call sites.
#inline
fn BitWriter::write_byte(self : BitWriter, byte : Byte) -> Unit {
  if self.direct_output is Some(output) {
    if self.direct_pos < output.length() {
      output[self.direct_pos] = byte
    } else {
      self.overflowed = true
    }
    self.direct_pos = self.direct_pos + 1
  } else {
    self.out.push(byte)
  }
}

///|
fn BitWriter::write_bit(self : BitWriter, bit : Int) -> Unit {
  self.bitbuf = self.bitbuf | (bit << self.bit_count)
  self.bit_count = self.bit_count + 1
  if self.bit_count == 8 {
    self.write_byte((self.bitbuf & 0xFF).to_byte())
    self.bitbuf = 0
    self.bit_count = 0
  }
}

///|
/// Write the low `n` bits of `value`, LSB-first. Batched: the bits are shifted
/// into the accumulator in one step and complete bytes flushed whole, instead
/// of looping one bit at a time.
fn BitWriter::write_bits(self : BitWriter, value : Int, n : Int) -> Unit {
  self.bitbuf = self.bitbuf | ((value & ((1 << n) - 1)) << self.bit_count)
  self.bit_count = self.bit_count + n
  while self.bit_count >= 8 {
    self.write_byte((self.bitbuf & 0xFF).to_byte())
    self.bitbuf = self.bitbuf >> 8
    self.bit_count = self.bit_count - 8
  }
}

///|
/// Write an already-bit-reversed Huffman code, LSB-first.
fn BitWriter::write_rcode(self : BitWriter, code : UInt, n : Int) -> Unit {
  self.write_bits(code.reinterpret_as_int(), n)
}

///|
/// Pad any sub-byte remainder in `bitbuf` out to a whole byte (zero-filling the
/// high bits) and emit it. Required before a byte-aligned stored block and at
/// the very end of a stream
fn BitWriter::flush(self : BitWriter) -> Unit {
  if self.bit_count > 0 {
    self.write_byte((self.bitbuf & 0xFF).to_byte())
    self.bitbuf = 0
    self.bit_count = 0
  }
}
