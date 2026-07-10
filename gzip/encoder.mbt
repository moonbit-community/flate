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
/// Streaming gzip compressor.
pub struct Encoder {
  priv def : @flate.Deflater
  priv crc : @checksum.Crc32
  priv mut isize : UInt // total input length, mod 2^32 (gzip ISIZE)
  priv mut mode : EncMode
  priv mut stage : FixedArray[Byte] // header or trailer bytes being drained
  priv mut stage_pos : Int
  priv mut ending : Bool
  priv mut flushing : Bool // sticky until the inner sync-flush is drained
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
    flushing: false,
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
/// Run one compression step. Accepts a bounded prefix of `input` (folding only
/// that prefix into CRC-32 and ISIZE), then drains gzip output into `output`.
/// Drop only `input[:consumed]`: output backpressure may make a large input
/// partially consumed. Re-present its suffix with the same `end=true` or
/// `flush=true` request; once the complete view is accepted, that request is
/// sticky across header and body backpressure. After finalization, later input
/// is not accepted and `consumed` is zero.
pub fn Encoder::step(
  self : Encoder,
  input : BytesView,
  output : MutArrayView[Byte],
  end? : Bool = false,
  flush? : Bool = false,
) -> (@flate.Status, Int, Int) {
  if self.mode is Finished {
    return (Done, 0, 0)
  }
  let mut consumed = 0
  if !self.ending {
    // Feed through the bounded inner state machine even while the wrapper
    // header is backpressured. Its zero-sized sink caps accepted input at one
    // block window and reports the exact prefix whose checksum we may commit.
    let scratch = FixedArray::make(0, b'\x00').mut_view()
    let (_, accepted, _) = self.def.step(input, scratch, end~, flush~)
    consumed = accepted
    if accepted > 0 {
      self.crc.update(input[:accepted])
      self.isize = self.isize + accepted.reinterpret_as_uint()
    }
    if accepted == input.length() {
      if end {
        self.ending = true
      }
      if flush {
        self.flushing = true
      }
    }
  }
  let out_end = output.length()
  let mut op = 0
  for ;; {
    match self.mode {
      Header | Trailer => {
        while self.stage_pos < self.stage.length() && op < out_end {
          output.set(op, self.stage[self.stage_pos])
          op = op + 1
          self.stage_pos = self.stage_pos + 1
        }
        if self.stage_pos < self.stage.length() {
          return (NeedMoreOutput, consumed, op)
        }
        self.mode = if self.mode is Header { Body } else { Finished }
      }
      Body => {
        let (st, _c, p) = self.def.step(
          b""[:],
          output.mut_view(start=op),
          end=self.ending,
          flush=self.flushing,
        )
        op = op + p
        if st is NeedMoreInput {
          // The inner deflater returns NeedMoreInput only after the sync-flush
          // marker (if requested) and all preceding compressed bytes drained.
          self.flushing = false
          return (NeedMoreInput, consumed, op)
        }
        if st is NeedMoreOutput {
          return (NeedMoreOutput, consumed, op)
        }
        // The DEFLATE stream is complete; stage the trailer.
        self.flushing = false
        self.stage = self.build_trailer()
        self.stage_pos = 0
        self.mode = Trailer
      }
      Finished => return (Done, consumed, op)
    }
  }
}
