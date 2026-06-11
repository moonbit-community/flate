// Streaming gzip compressor: a push-based, suspendable state machine
// wrapping the `@flate.Deflater`. It emits the 10-byte header, then the raw
// DEFLATE stream block-by-block, then the 8-byte trailer (CRC-32 and ISIZE,
// little-endian), accumulating the checksum incrementally so it never holds the
// whole input. The one-shot `gzip_compress` remains for in-memory use.

///|
let gzip_header_bytes : FixedArray[Byte] = [
  0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF,
]

///|
priv enum EncMode {
  Header // draining the gzip header
  Body // draining DEFLATE blocks from the inner Deflater
  Trailer // draining the CRC-32 + ISIZE trailer
  Finished
}

///|
/// Streaming gzip compressor . 
pub struct Encoder {
  priv def : @flate.Deflater
  priv crc : @checksum.Crc32
  priv mut isize : UInt // total input length, mod 2^32 (gzip ISIZE)
  priv mut mode : EncMode
  priv mut stage : FixedArray[Byte] // header or trailer bytes being drained
  priv mut stage_pos : Int
  priv mut ending : Bool
}

///|
/// Create a fresh gzip compressor. 
pub fn Encoder::new(level? : Int = 6) -> Encoder {
  {
    def: @flate.Deflater::new(level~),
    crc: @checksum.Crc32::new(),
    isize: 0,
    mode: Header,
    stage: gzip_header_bytes,
    stage_pos: 0,
    ending: false,
  }
}

///|
/// Whether the complete gzip stream has been emitted.
pub fn Encoder::is_finished(self : Encoder) -> Bool {
  self.mode is Finished
}

///|
/// The 8-byte gzip trailer: CRC-32 then ISIZE, each little-endian.
fn Encoder::build_trailer(self : Encoder) -> FixedArray[Byte] {
  let crc = self.crc.finish()
  let isize = self.isize
  let t = FixedArray::make(8, b'\x00')
  t[0] = (crc & 0xFF).reinterpret_as_int().to_byte()
  t[1] = ((crc >> 8) & 0xFF).reinterpret_as_int().to_byte()
  t[2] = ((crc >> 16) & 0xFF).reinterpret_as_int().to_byte()
  t[3] = ((crc >> 24) & 0xFF).reinterpret_as_int().to_byte()
  t[4] = (isize & 0xFF).reinterpret_as_int().to_byte()
  t[5] = ((isize >> 8) & 0xFF).reinterpret_as_int().to_byte()
  t[6] = ((isize >> 16) & 0xFF).reinterpret_as_int().to_byte()
  t[7] = ((isize >> 24) & 0xFF).reinterpret_as_int().to_byte()
  t
}

///|
/// Run one compression step. Buffers `input` (folding it into the running
/// CRC-32 and ISIZE), then drains gzip output into `output` over
/// `out_off..<out_off+out_len`. Returns `(status, consumed, produced)`;
/// `consumed` is always the whole input view. Pass `end=true` to finalize and
/// keep calling while it returns `NeedMoreOutput` to drain the rest.
pub fn Encoder::step(
  self : Encoder,
  input : BytesView,
  output : FixedArray[Byte],
  out_off~ : Int,
  out_len? : Int = output.length() - out_off,
  end? : Bool = false,
  flush? : Bool = false,
) -> (@flate.Status, Int, Int) {
  // Fold this call's input into the checksum and buffer it in the Deflater
  // exactly once. A zero-length output makes `Deflater::step` only accumulate.
  if input.length() > 0 {
    self.crc.update(input)
    self.isize = self.isize + input.length().reinterpret_as_uint()
    let scratch : FixedArray[Byte] = FixedArray::make(0, b'\x00')
    let _ = self.def.step(input, scratch, out_off=0, out_len=0)
  }
  if end {
    self.ending = true
  }
  let out_end = out_off + out_len
  let mut op = out_off
  let consumed = input.length()
  for ;; {
    match self.mode {
      Header | Trailer => {
        while self.stage_pos < self.stage.length() && op < out_end {
          output[op] = self.stage[self.stage_pos]
          op = op + 1
          self.stage_pos = self.stage_pos + 1
        }
        if self.stage_pos < self.stage.length() {
          return (NeedMoreOutput, consumed, op - out_off)
        }
        self.mode = if self.mode is Header { Body } else { Finished }
      }
      Body => {
        let (st, _c, p) = self.def.step(
          b""[:],
          output,
          out_off=op,
          out_len=out_end - op,
          end=self.ending,
          flush~,
        )
        op = op + p
        if st is NeedMoreInput {
          return (NeedMoreInput, consumed, op - out_off)
        }
        if st is NeedMoreOutput {
          return (NeedMoreOutput, consumed, op - out_off)
        }
        // The DEFLATE stream is complete; stage the trailer.
        self.stage = self.build_trailer()
        self.stage_pos = 0
        self.mode = Trailer
      }
      Finished => return (Done, consumed, op - out_off)
    }
  }
}
