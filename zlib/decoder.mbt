///|
/// Maximum compressed input retained while output is backpressured.
let decoder_input_limit = 65536

///|
priv enum DecMode {
  ZHeader
  ZBody
  ZTrailer
  ZFinished
}

///|
/// Streaming zlib decompressor
pub struct Decoder {
  priv inf : @flate.Inflater
  priv adler : @checksum.Adler32 // of the decompressed output
  priv mut pending : Array[Byte] // buffered input; consumed prefix kept until compacted
  priv mut pending_pos : Int // first unconsumed byte in `pending`
  // Stable snapshot passed to Inflater. It is retained across output
  // backpressure, so draining one output byte never recopies all pending input.
  priv mut body_input : Bytes
  priv mut body_pos : Int
  priv mut unused : Bytes // cached read-ahead suffix after successful completion
  priv mut ending : Bool // `end=true` is sticky across output suspension
  priv mut mode : DecMode
  priv dict : Bytes? // preset dictionary, if the caller has one
  priv mut failure_kind : ZlibErrorKind? // stable first terminal error
  priv mut failure_message : String
  priv mut step_consumed : Int
  priv mut step_produced : Int
}

///|
/// Create a fresh zlib decompressor. Supply `dictionary` when the stream was
/// compressed with a preset dictionary : the header's DICTID
/// is verified against it before use.
pub fn Decoder::new(dictionary? : Bytes) -> Decoder {
  {
    inf: @flate.Inflater::new(),
    adler: @checksum.Adler32::new(),
    pending: [],
    pending_pos: 0,
    body_input: b"",
    body_pos: 0,
    unused: b"",
    ending: false,
    mode: ZHeader,
    dict: dictionary,
    failure_kind: None,
    failure_message: "",
    step_consumed: 0,
    step_produced: 0,
  }
}

///|
/// Whether the whole zlib stream has been decoded and its trailer verified.
pub fn Decoder::is_finished(self : Decoder) -> Bool {
  self.mode is ZFinished
}

///|
/// Number of input bytes accepted by the most recent successful `step` call.
/// It is reset to zero when a call raises `ZlibError`.
pub fn Decoder::last_consumed(self : Decoder) -> Int {
  self.step_consumed
}

///|
/// Number of output bytes written by the most recent successful `step` call.
/// It is reset to zero when a call raises `ZlibError`.
pub fn Decoder::last_produced(self : Decoder) -> Int {
  self.step_produced
}

///|
/// Bytes accepted by `step` beyond the end of the completed zlib stream.
///
/// A buffered sync reader or async transport commonly delivers the zlib
/// trailer and bytes from the next protocol frame in one read. `step` accepts
/// that whole view so it can preserve its streaming/backpressure contract;
/// after `Done`, this method returns the read-ahead suffix instead of losing
/// it. It is empty before completion and when no suffix was buffered.
pub fn Decoder::unused_input(self : Decoder) -> Bytes {
  match self.mode {
    ZFinished => self.unused
    _ => b""
  }
}

///|
/// Number of bytes not yet consumed from `pending`.
fn Decoder::pending_length(self : Decoder) -> Int {
  self.pending.length() - self.pending_pos
}

///|
/// Enter the successful terminal state while retaining only transport
/// read-ahead. All consumed compressed storage and the inflater snapshot can
/// be released after the Adler-32 trailer has been verified.
fn Decoder::finish_stream(self : Decoder) -> Unit {
  let suffix : Array[Byte] = []
  for i in self.pending_pos..<self.pending.length() {
    suffix.push(self.pending[i])
  }
  self.unused = Bytes::from_array(suffix)
  self.pending = []
  self.pending_pos = 0
  self.body_input = b""
  self.body_pos = 0
  self.mode = ZFinished
}

///|
/// Reclaim a consumed prefix only when doing so is free (the buffer is empty)
/// or removes at least half a non-trivial buffer. This makes prefix removal
/// amortized linear rather than copying the remaining suffix on every step.
fn Decoder::compact_pending(self : Decoder) -> Unit {
  if self.pending_pos == self.pending.length() {
    self.pending.clear()
    self.pending_pos = 0
  } else if self.pending_pos >= 4096 &&
    self.pending_pos * 2 >= self.pending.length() {
    let kept : Array[Byte] = []
    for j in self.pending_pos..<self.pending.length() {
      kept.push(self.pending[j])
    }
    self.pending = kept
    self.pending_pos = 0
  }
}

///|
/// Force prefix reclamation before admitting another bounded input window.
fn Decoder::compact_for_input(self : Decoder) -> Unit {
  if self.pending_pos == 0 {
    return
  }
  let kept : Array[Byte] = []
  for i in self.pending_pos..<self.pending.length() {
    kept.push(self.pending[i])
  }
  self.pending = kept
  self.pending_pos = 0
}

///|
/// Consume bytes parsed by the zlib wrapper itself.
fn Decoder::consume_pending(self : Decoder, count : Int) -> Unit {
  self.pending_pos = self.pending_pos + count
  self.compact_pending()
}

///|
/// Snapshot every currently available body byte. New input may be appended to
/// `pending` without invalidating this immutable prefix; it is incorporated
/// only if Inflater actually asks for more input.
fn Decoder::stage_body_input(self : Decoder) -> Unit {
  let staged : Array[Byte] = []
  for j in self.pending_pos..<self.pending.length() {
    staged.push(self.pending[j])
  }
  self.body_input = Bytes::from_array(staged)
  self.body_pos = 0
}

///|
/// Read a big-endian u32 from `pending` at `off`.
fn Decoder::u32_be(self : Decoder, off : Int) -> UInt {
  let pos = self.pending_pos + off
  (self.pending[pos].to_uint() << 24) |
  (self.pending[pos + 1].to_uint() << 16) |
  (self.pending[pos + 2].to_uint() << 8) |
  self.pending[pos + 3].to_uint()
}

///|
/// Run one decompression step. Buffers a bounded prefix of `input`, then decodes
/// plaintext into `output`. Read the accepted and produced counts with
/// `last_consumed()` and `last_produced()`; drop only
/// `input[:last_consumed()]`. Output backpressure may leave a suffix unaccepted.
/// `end=true` becomes sticky after its complete view is consumed and turns
/// incomplete headers, DEFLATE bodies, and trailers into `ZlibError` instead of
/// another `NeedMoreInput`. If the final accepted view also contains bytes after
/// the zlib trailer, retrieve that read-ahead with `unused_input()`. On failure,
/// the decoder locks the first `ZlibError` kind/message and rethrows it on every
/// later call; both progress counters remain zero.
pub fn Decoder::step(
  self : Decoder,
  input : BytesView,
  output : MutArrayView[Byte],
  end? : Bool = false,
) -> @flate.Status raise ZlibError {
  self.step_consumed = 0
  self.step_produced = 0
  match self.failure_kind {
    Some(kind) => raise ZlibError(kind, self.failure_message)
    None =>
      self.step_active(input, output, end~) catch {
        ZlibError(kind, message) => {
          self.failure_kind = Some(kind)
          self.failure_message = message
          raise ZlibError(kind, message)
        }
      }
  }
}

///|
fn Decoder::finish_step(
  self : Decoder,
  status : @flate.Status,
  consumed : Int,
  produced : Int,
) -> @flate.Status {
  self.step_consumed = consumed
  self.step_produced = produced
  status
}

///|
fn Decoder::step_active(
  self : Decoder,
  input : BytesView,
  output : MutArrayView[Byte],
  end~ : Bool,
) -> @flate.Status raise ZlibError {
  // A terminal decoder must not claim input that it can no longer decode.
  if self.mode is ZFinished {
    return self.finish_step(Done, 0, 0)
  }
  if !self.ending && self.pending.length() >= decoder_input_limit {
    self.compact_for_input()
  }
  let capacity = decoder_input_limit - self.pending.length()
  let consumed = if self.ending || capacity <= 0 {
    0
  } else if input.length() < capacity {
    input.length()
  } else {
    capacity
  }
  for i in 0..<consumed {
    self.pending.push(input[i])
  }
  if end && consumed == input.length() {
    self.ending = true
  }
  let mut op = 0
  for ;; {
    match self.mode {
      ZHeader => {
        if self.pending_length() < 2 {
          if self.ending {
            raise ZlibError(Truncated, "zlib: truncated header")
          }
          return self.finish_step(NeedMoreInput, consumed, op)
        }
        let cmf = self.pending[self.pending_pos].to_int()
        let flg = self.pending[self.pending_pos + 1].to_int()
        if (cmf & 0x0F) != 8 {
          raise ZlibError(InvalidHeader, "zlib: unsupported compression method")
        }
        if cmf >> 4 > 7 {
          raise ZlibError(InvalidHeader, "zlib: invalid window size")
        }
        if (cmf * 256 + flg) % 31 != 0 {
          raise ZlibError(InvalidHeader, "zlib: bad header check")
        }
        if (flg & 0x20) != 0 {
          // FDICT: a 4-byte DICTID follows; verify it against the supplied
          // dictionary and preload the inflater's window.
          if self.pending_length() < 6 {
            if self.ending {
              raise ZlibError(Truncated, "zlib: truncated dictionary id")
            }
            return self.finish_step(NeedMoreInput, consumed, op)
          }
          let dictid = self.u32_be(2)
          match self.dict {
            None =>
              raise ZlibError(
                DictionaryRequired,
                "zlib: preset dictionary required",
              )
            Some(dict) => {
              if @checksum.adler32(dict) != dictid {
                raise ZlibError(
                  DictionaryMismatch,
                  "zlib: dictionary id mismatch",
                )
              }
              // Configure the raw inflater only after FDICT and DICTID have
              // been validated. Preloading it in `new` would incorrectly let
              // a stream without FDICT refer to caller-supplied history.
              self.inf.reset(dictionary=dict[:])
            }
          }
          self.consume_pending(6)
        } else {
          self.consume_pending(2)
        }
        self.mode = ZBody
      }
      ZBody => {
        if self.body_pos == self.body_input.length() {
          self.body_input = b""
          self.body_pos = 0
          self.compact_pending()
          if self.pending_length() > 0 {
            self.stage_body_input()
          }
        }
        let op_before = op
        let st = self.inf.step(
          self.body_input[self.body_pos:],
          output.mut_view(start=op),
        ) catch {
          InflateError(_, message) =>
            raise ZlibError(
              InvalidDeflate,
              "zlib: invalid DEFLATE stream: \{message}",
            )
        }
        let used = self.inf.last_consumed()
        let produced = self.inf.last_produced()
        if produced > 0 {
          for i in 0..<produced {
            self.adler.update_byte(output.at(op_before + i))
          }
        }
        op = op + produced
        self.pending_pos = self.pending_pos + used
        self.body_pos = self.body_pos + used
        if st is Done {
          // The unconsumed part of the body snapshot starts with the zlib
          // trailer and remains in `pending` at `pending_pos`.
          self.body_input = b""
          self.body_pos = 0
          self.compact_pending()
          self.mode = ZTrailer
        } else if st is NeedMoreInput {
          let cached = self.body_input.length() - self.body_pos
          if self.pending_length() > cached {
            // Input appended while an older snapshot was being drained is now
            // needed to complete an atomic Inflater unit. Rebuild once with
            // the unconsumed suffix plus all newly available bytes.
            self.stage_body_input()
          } else {
            if self.ending {
              raise ZlibError(Truncated, "zlib: truncated DEFLATE stream")
            }
            return self.finish_step(NeedMoreInput, consumed, op)
          }
        } else {
          return self.finish_step(NeedMoreOutput, consumed, op)
        }
      }
      ZTrailer => {
        if self.pending_length() < 4 {
          if self.ending {
            raise ZlibError(Truncated, "zlib: truncated trailer")
          }
          return self.finish_step(NeedMoreInput, consumed, op)
        }
        if self.adler.finish() != self.u32_be(0) {
          raise ZlibError(ChecksumMismatch, "zlib: Adler-32 mismatch")
        }
        self.consume_pending(4)
        self.finish_stream()
      }
      ZFinished => return self.finish_step(Done, consumed, op)
    }
  }
}
