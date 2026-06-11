// Streaming zlib (RFC 1950) compressor: a push-based, suspendable state machine
// wrapping the `@flate.Deflater`. It emits the 2-byte header, then the raw
// DEFLATE stream block-by-block, then the 4-byte big-endian Adler-32 trailer,
// accumulating the checksum incrementally. The one-shot `zlib_compress` remains
// for in-memory use.

///|
// CMF=0x78 (deflate, 32K window); FLG=0x01 makes the header a multiple of 31
// with FLEVEL=0 and no preset dictionary.
let zlib_header_bytes : FixedArray[Byte] = [0x78, 0x01]

///|
priv enum EncMode {
  Header
  Body
  Trailer
  Finished
}

///|
/// Streaming zlib compressor (RFC 1950). Feed input and drain compressed output
/// with `step`, finalize with `end=true`; binds no I/O trait.
pub struct Encoder {
  priv def : @flate.Deflater
  priv adler : @checksum.Adler32
  priv mut mode : EncMode
  priv mut stage : FixedArray[Byte]
  priv mut stage_pos : Int
  priv mut ending : Bool
}

///|
/// Create a fresh zlib compressor. `level` 0-9 (clamped) trades speed for
/// ratio; 0 = stored only, 6 = default. A preset `dictionary` (RFC 1950
/// FDICT) preloads the match window and is announced in the header via its
/// Adler-32; the decoder must supply the same dictionary.
pub fn Encoder::new(level? : Int = 6, dictionary? : Bytes) -> Encoder {
  let def = @flate.Deflater::new(level~)
  let stage = match dictionary {
    None => zlib_header_bytes
    Some(dict) => {
      def.set_dictionary(dict[:])
      let id = @checksum.adler32(dict)
      let h = FixedArray::make(6, b'\x00')
      // CMF=0x78; FLG=0x20 sets FDICT (0x7820 is a multiple of 31, FCHECK ok),
      // followed by the 4-byte big-endian DICTID.
      h[0] = b'\x78'
      h[1] = b'\x20'
      h[2] = ((id >> 24) & 0xFF).reinterpret_as_int().to_byte()
      h[3] = ((id >> 16) & 0xFF).reinterpret_as_int().to_byte()
      h[4] = ((id >> 8) & 0xFF).reinterpret_as_int().to_byte()
      h[5] = (id & 0xFF).reinterpret_as_int().to_byte()
      h
    }
  }
  {
    def,
    adler: @checksum.Adler32::new(),
    mode: Header,
    stage,
    stage_pos: 0,
    ending: false,
  }
}

///|
/// Whether the complete zlib stream has been emitted.
pub fn Encoder::is_finished(self : Encoder) -> Bool {
  self.mode is Finished
}

///|
/// The 4-byte zlib trailer: Adler-32, big-endian.
fn Encoder::build_trailer(self : Encoder) -> FixedArray[Byte] {
  let adler = self.adler.finish()
  let t = FixedArray::make(4, b'\x00')
  t[0] = ((adler >> 24) & 0xFF).reinterpret_as_int().to_byte()
  t[1] = ((adler >> 16) & 0xFF).reinterpret_as_int().to_byte()
  t[2] = ((adler >> 8) & 0xFF).reinterpret_as_int().to_byte()
  t[3] = (adler & 0xFF).reinterpret_as_int().to_byte()
  t
}

///|
/// Run one compression step. Buffers `input` (folding it into the running
/// Adler-32), then drains zlib output into `output` over
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
  if input.length() > 0 {
    self.adler.update(input)
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
        self.stage = self.build_trailer()
        self.stage_pos = 0
        self.mode = Trailer
      }
      Finished => return (Done, consumed, op - out_off)
    }
  }
}
