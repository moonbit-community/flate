// LSB-first bit sink for the encode pipeline. DEFLATE packs bits LSB-first
// into bytes, but Huffman codes are written MSB-first.

///|
priv struct BitWriter {
  out : Array[Byte]
  mut bitbuf : Int
  mut bit_count : Int // bits currently held in `bitbuf`, not yet flushed to a byte
}

///|
fn BitWriter::new() -> BitWriter {
  { out: [], bitbuf: 0, bit_count: 0 }
}

///|
fn BitWriter::write_bit(self : BitWriter, bit : Int) -> Unit {
  self.bitbuf = self.bitbuf | (bit << self.bit_count)
  self.bit_count = self.bit_count + 1
  if self.bit_count == 8 {
    self.out.push((self.bitbuf & 0xFF).to_byte())
    self.bitbuf = 0
    self.bit_count = 0
  }
}

///|
/// Write the low `n` bits of `value`, LSB-first.
fn BitWriter::write_bits(self : BitWriter, value : Int, n : Int) -> Unit {
  for i in 0..<n {
    self.write_bit((value >> i) & 1)
  }
}

///|
/// Write an `n`-bit Huffman code, MSB-first.
fn BitWriter::write_code(self : BitWriter, code : Int, n : Int) -> Unit {
  for i = n - 1; i >= 0; i = i - 1 {
    self.write_bit((code >> i) & 1)
  }
}

///|
/// Write an already-bit-reversed Huffman code, LSB-first.
fn BitWriter::write_rcode(self : BitWriter, code : UInt, n : Int) -> Unit {
  self.write_bits(code.reinterpret_as_int(), n)
}

///|
/// Pad any sub-byte remainder in `bitbuf` out to a whole byte (zero-filling the
/// high bits) and emit it, it is only valid at the very end of a stream
fn BitWriter::flush(self : BitWriter) -> Unit {
  if self.bit_count > 0 {
    self.out.push((self.bitbuf & 0xFF).to_byte())
    self.bitbuf = 0
    self.bit_count = 0
  }
}
