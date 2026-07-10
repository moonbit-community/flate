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
  priv mut flushing : Bool // latched until the inner sync flush is drained
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
    flushing: false,
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
/// Run one compression step. Accepts a bounded prefix of `input`, folds only
/// that prefix into Adler-32, then drains zlib output into `output`. Drop only
/// `input[:consumed]`: a large view may be partially consumed under output
/// backpressure. Re-present its suffix with the same `end=true` or `flush=true`
/// request; once the complete view is accepted, the request remains sticky.
/// Later input is left unconsumed while the finished stream is drained.
pub fn Encoder::step(
  self : Encoder,
  input : BytesView,
  output : MutArrayView[Byte],
  end? : Bool = false,
  flush? : Bool = false,
) -> (@flate.Status, Int, Int) {
  // A terminal encoder must not claim or checksum input that cannot become
  // part of the already-finished stream.
  if self.mode is Finished {
    return (Done, 0, 0)
  }
  let mut consumed = 0
  if !self.ending {
    let scratch = FixedArray::make(0, b'\x00').mut_view()
    let (_, accepted, _) = self.def.step(input, scratch, end~, flush~)
    consumed = accepted
    if accepted > 0 {
      self.adler.update(input[:accepted])
    }
    if accepted == input.length() {
      if end {
        self.ending = true
      }
      if flush {
        // Header/trailer backpressure may postpone entry into Body to a later
        // call, so the request must outlive this call's optional argument.
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
          // Deflater returns NeedMoreInput only after a requested sync flush
          // (including its marker) has been fully emitted.
          self.flushing = false
          return (NeedMoreInput, consumed, op)
        }
        if st is NeedMoreOutput {
          return (NeedMoreOutput, consumed, op)
        }
        self.flushing = false
        self.stage = self.build_trailer()
        self.stage_pos = 0
        self.mode = Trailer
      }
      Finished => return (Done, consumed, op)
    }
  }
}
