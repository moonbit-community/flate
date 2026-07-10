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
/// with `step`, finalize with `action=Finish`; binds no I/O trait.
pub struct Encoder {
  priv def : @flate.Deflater
  priv adler : @checksum.Adler32
  priv mut mode : EncMode
  priv mut stage : FixedArray[Byte]
  priv mut stage_pos : Int
  // Accepted stream control, latched until the inner deflater drains it.
  // Finish and sync-flush cannot both be pending.
  priv mut pending_action : @flate.DeflateAction
  priv mut step_consumed : Int
  priv mut step_produced : Int
}

///|
/// Create a fresh zlib compressor. `level` 0-9 (clamped) trades speed for
/// ratio; 0 = stored only, 6 = default. A preset `dictionary` (RFC 1950
/// FDICT) preloads the match window and is announced in the header via its
/// Adler-32; the decoder must supply the same dictionary.
pub fn Encoder::new(level? : Int = 6, dictionary? : Bytes) -> Encoder {
  let (def, stage) = match dictionary {
    None => (@flate.Deflater::new(level~), zlib_header_bytes)
    Some(dict) => {
      let def = @flate.Deflater::new(level~, dictionary=dict[:])
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
      (def, h)
    }
  }
  {
    def,
    adler: @checksum.Adler32::new(),
    mode: Header,
    stage,
    stage_pos: 0,
    pending_action: Continue,
    step_consumed: 0,
    step_produced: 0,
  }
}

///|
/// Whether the complete zlib stream has been emitted.
pub fn Encoder::is_finished(self : Encoder) -> Bool {
  self.mode is Finished
}

///|
/// Number of input bytes accepted by the most recent successful `step` call.
/// It is zero before the first call and after a call that reports no progress.
pub fn Encoder::last_consumed(self : Encoder) -> Int {
  self.step_consumed
}

///|
/// Number of output bytes written by the most recent successful `step` call.
/// It is zero before the first call and after a call that reports no progress.
pub fn Encoder::last_produced(self : Encoder) -> Int {
  self.step_produced
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
fn Encoder::finish_step(
  self : Encoder,
  status : @flate.Status,
  consumed : Int,
  produced : Int,
) -> @flate.Status {
  self.step_consumed = consumed
  self.step_produced = produced
  status
}

///|
/// Run one compression step. Accepts a bounded prefix of `input`, folds only
/// that prefix into Adler-32, then drains zlib output into `output`. Read the
/// accepted and produced counts with `last_consumed()` and `last_produced()`,
/// then drop only `input[:last_consumed()]`: a large view may be partially
/// consumed under output backpressure. Re-present its suffix with the same
/// `action`; once the complete view is accepted, `SyncFlush` or `Finish` remains
/// sticky. Later input is left unconsumed while the finished stream is drained.
pub fn Encoder::step(
  self : Encoder,
  input : BytesView,
  output : MutArrayView[Byte],
  action? : @flate.DeflateAction = Continue,
) -> @flate.Status {
  self.step_consumed = 0
  self.step_produced = 0
  // A terminal encoder must not claim or checksum input that cannot become
  // part of the already-finished stream.
  if self.mode is Finished {
    return Done
  }
  let mut consumed = 0
  match self.pending_action {
    Finish => ()
    Continue | SyncFlush => {
      let scratch = FixedArray::make(0, b'\x00').mut_view()
      let _status = self.def.step(input, scratch, action~)
      let accepted = self.def.last_consumed()
      consumed = accepted
      if accepted > 0 {
        self.adler.update(input[:accepted])
      }
      if accepted == input.length() {
        match action {
          Continue => ()
          SyncFlush => self.pending_action = SyncFlush
          Finish => self.pending_action = Finish
        }
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
          return self.finish_step(NeedMoreOutput, consumed, op)
        }
        self.mode = if self.mode is Header { Body } else { Finished }
      }
      Body => {
        let st = self.def.step(
          b""[:],
          output.mut_view(start=op),
          action=self.pending_action,
        )
        let p = self.def.last_produced()
        op = op + p
        if st is NeedMoreInput {
          // Deflater returns NeedMoreInput only after a requested sync flush
          // (including its marker) has been fully emitted.
          if self.pending_action is SyncFlush {
            self.pending_action = Continue
          }
          return self.finish_step(NeedMoreInput, consumed, op)
        }
        if st is NeedMoreOutput {
          return self.finish_step(NeedMoreOutput, consumed, op)
        }
        self.stage = self.build_trailer()
        self.stage_pos = 0
        self.mode = Trailer
      }
      Finished => return self.finish_step(Done, consumed, op)
    }
  }
}
