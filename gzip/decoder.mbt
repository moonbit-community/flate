// Streaming gzip (RFC 1952) decompressor: a push-based, suspendable state
// machine wrapping the `@flate.Inflater`. The variable-length header is parsed
// zlib-style with one state per field: the unbounded fields (FEXTRA payload,
// FNAME, FCOMMENT) are consumed as they arrive and discarded, never retained,
// so header-phase memory is O(1) even against an adversarial unterminated
// FNAME. It then drives the inflater over the DEFLATE body (folding
// decompressed output into a running CRC-32 and length) and verifies the
// 8-byte trailer. The one-shot `gunzip` remains for in-memory use.

///|
/// Maximum compressed input retained by one active decoder step. A consumed
/// prefix may briefly coexist until compaction, but caller-owned input beyond
/// this window remains unconsumed under output backpressure.
let decoder_input_limit = 65536

///|
priv enum DecMode {
  GzHeader // the fixed 10-byte header (magic, method, FLG, MTIME, XFL, OS)
  GzExtraLen // the 2-byte XLEN of FEXTRA
  GzExtra(Int) // discarding the FEXTRA payload; bytes still to skip
  GzName // discarding the NUL-terminated FNAME
  GzComment // discarding the NUL-terminated FCOMMENT
  GzHcrc // the 2-byte FHCRC (skipped, not verified)
  GzBody // inflating the DEFLATE stream
  GzTrailer // reading + verifying the CRC-32 / ISIZE trailer
  GzFinished
}

///|
/// Streaming gzip decompressor (RFC 1952). Feed compressed input and drain
/// plaintext with `step`; it verifies the CRC-32 and length trailer. Binds no
/// I/O trait.
pub struct Decoder {
  priv inf : @flate.Inflater
  priv mut crc : @checksum.Crc32 // of the current member's decompressed output
  priv mut osize : UInt // current member's decompressed length, mod 2^32
  priv mut pending : Array[Byte] // unconsumed compressed input
  priv mut pending_pos : Int // first unread byte in `pending`
  // `Inflater` requires a BytesView. Cache the immutable snapshot so output
  // backpressure does not copy the whole compressed tail on every call.
  priv mut pending_bytes : Bytes
  priv mut pending_snapshot_end : Int // exclusive Array index in the snapshot
  priv mut unused : Bytes // cached read-ahead suffix after successful completion
  priv mut flg : Int // header FLG byte, gates the optional-field states
  priv mut members : Int // fully verified members
  priv mut ending : Bool // `end=true` is sticky across output suspension
  priv multistream : Bool // decode RFC 1952 concatenated members when true
  priv mut mode : DecMode
  priv mut failure_kind : GzipErrorKind? // stable first terminal error
  priv mut failure_message : String
  priv mut step_consumed : Int
  priv mut step_produced : Int
}

///|
/// Create a fresh gzip decompressor. With the default `multistream=true`,
/// adjacent RFC 1952 members are decoded as one logical stream. Set it to
/// false for a framed transport that must stop after the first member and
/// recover every following byte through `unused_input()`.
pub fn Decoder::new(multistream? : Bool = true) -> Decoder {
  {
    inf: @flate.Inflater::new(),
    crc: @checksum.Crc32::new(),
    osize: 0,
    pending: [],
    pending_pos: 0,
    pending_bytes: b"",
    pending_snapshot_end: 0,
    unused: b"",
    flg: 0,
    members: 0,
    ending: false,
    multistream,
    mode: GzHeader,
    failure_kind: None,
    failure_message: "",
    step_consumed: 0,
    step_produced: 0,
  }
}

///|
/// Whether the whole gzip stream has been decoded and its trailer verified.
pub fn Decoder::is_finished(self : Decoder) -> Bool {
  self.mode is GzFinished
}

///|
/// Number of input bytes accepted by the most recent successful `step` call.
/// It is reset to zero when a call raises `GzipError`.
pub fn Decoder::last_consumed(self : Decoder) -> Int {
  self.step_consumed
}

///|
/// Number of output bytes written by the most recent successful `step` call.
/// It is reset to zero when a call raises `GzipError`.
pub fn Decoder::last_produced(self : Decoder) -> Int {
  self.step_produced
}

///|
/// Bytes accepted by `step` beyond the final completed gzip member.
///
/// A buffered sync reader or async transport can deliver a member trailer and
/// bytes from the next protocol frame in one read. Once `Done` is reached,
/// this method returns that read-ahead suffix. It is empty before completion
/// and when the gzip stream ended exactly at the input boundary.
pub fn Decoder::unused_input(self : Decoder) -> Bytes {
  match self.mode {
    GzFinished => self.unused
    _ => b""
  }
}

///|
/// Number of unread buffered bytes.
fn Decoder::available(self : Decoder) -> Int {
  self.pending.length() - self.pending_pos
}

///|
/// Enter the successful terminal state while retaining only transport
/// read-ahead. The inflater snapshot and consumed prefix are no longer useful
/// once the member trailer has been verified.
fn Decoder::finish_stream(self : Decoder) -> Unit {
  let suffix : Array[Byte] = []
  for i in self.pending_pos..<self.pending.length() {
    suffix.push(self.pending[i])
  }
  self.unused = Bytes::from_array(suffix)
  self.pending = []
  self.pending_pos = 0
  self.pending_bytes = b""
  self.pending_snapshot_end = 0
  self.mode = GzFinished
}

///|
/// Read an unread buffered byte at a relative offset.
fn Decoder::pending_at(self : Decoder, off : Int) -> Byte {
  self.pending[self.pending_pos + off]
}

///|
/// Buffer newly accepted input. An existing immutable body snapshot remains
/// usable: the appended suffix is incorporated only if the inflater actually
/// reaches `NeedMoreInput`, never merely because output is backpressured.
fn Decoder::buffer_input(self : Decoder, input : BytesView) -> Unit {
  if input.length() == 0 {
    return
  }
  for i in 0..<input.length() {
    self.pending.push(input[i])
  }
}

///|
/// Reclaim a consumed prefix before admitting more caller-owned input. This is
/// safe between steps because the raw inflater releases its call-local view.
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
  self.pending_bytes = b""
  self.pending_snapshot_end = 0
}

///|
/// Advance the unread cursor. Reclaim a fully consumed buffer immediately and
/// compact a partial buffer only after a sizeable prefix becomes at least half
/// of the allocation, making total compaction work amortized linear.
fn Decoder::advance(self : Decoder, k : Int) -> Unit {
  if k <= 0 {
    return
  }
  self.pending_pos = self.pending_pos + k
  if self.pending_pos == self.pending.length() {
    self.pending.clear()
    self.pending_pos = 0
    self.pending_bytes = b""
    self.pending_snapshot_end = 0
  } else if self.pending_pos >= 4096 && self.pending_pos >= self.available() {
    let kept : Array[Byte] = []
    for j in self.pending_pos..<self.pending.length() {
      kept.push(self.pending[j])
    }
    self.pending = kept
    self.pending_pos = 0
    self.pending_bytes = b""
    self.pending_snapshot_end = 0
  }
}

///|
/// Compact all unread input and rebuild the immutable inflater snapshot. This
/// is done only when no snapshot exists or the inflater needs bytes appended
/// beyond its current snapshot. At that point the old prefix has either been
/// consumed or is a bounded atomic-unit tail, so each byte is copied only an
/// amortized constant number of times.
fn Decoder::refresh_pending_snapshot(self : Decoder) -> Unit {
  if self.pending_pos > 0 {
    let kept : Array[Byte] = []
    for j in self.pending_pos..<self.pending.length() {
      kept.push(self.pending[j])
    }
    self.pending = kept
    self.pending_pos = 0
  }
  self.pending_bytes = Bytes::from_array(self.pending)
  self.pending_snapshot_end = self.pending.length()
}

///|
/// Return the portion of the cached snapshot not yet offered to the inflater.
/// Newly appended input intentionally stays outside this view until the
/// inflater exhausts the snapshot.
fn Decoder::pending_view(self : Decoder) -> BytesView {
  if self.pending_snapshot_end <= self.pending_pos && self.available() > 0 {
    self.refresh_pending_snapshot()
  }
  self.pending_bytes[self.pending_pos:self.pending_snapshot_end]
}

///|
/// The header state that follows field group `done` (0 = fixed header,
/// 1 = FEXTRA, 2 = FNAME, 3 = FCOMMENT), gated by the FLG bits.
fn Decoder::next_header_mode(self : Decoder, done : Int) -> DecMode {
  if done < 1 && (self.flg & 4) != 0 {
    GzExtraLen
  } else if done < 2 && (self.flg & 8) != 0 {
    GzName
  } else if done < 3 && (self.flg & 16) != 0 {
    GzComment
  } else if done < 4 && (self.flg & 2) != 0 {
    GzHcrc
  } else {
    GzBody
  }
}

///|
/// Drop pending bytes up to and including the NUL that ends the current
/// header field, or discard everything seen so far (these fields have no
/// length bound, so they are never retained). Returns true when the field is
/// complete.
fn Decoder::skip_nul_terminated(self : Decoder) -> Bool {
  let mut nul = -1
  for j in 0..<self.available() {
    if self.pending_at(j) == b'\x00' {
      nul = j
      break
    }
  }
  if nul >= 0 {
    self.advance(nul + 1)
    true
  } else {
    self.advance(self.available())
    false
  }
}

///|
/// Read a little-endian u32 from `pending` at `off`.
fn Decoder::u32_le(self : Decoder, off : Int) -> UInt {
  self.pending_at(off).to_uint() |
  (self.pending_at(off + 1).to_uint() << 8) |
  (self.pending_at(off + 2).to_uint() << 16) |
  (self.pending_at(off + 3).to_uint() << 24)
}

///|
/// Run one decompression step. Buffers a bounded prefix of `input`, then decodes
/// plaintext into `output`. Read the accepted and produced counts with
/// `last_consumed()` and `last_produced()`; drop only
/// `input[:last_consumed()]` and re-present a suffix that was held back by
/// output backpressure. Once `end=true` has been accepted with its complete
/// view (or after `Done`), later input is not accepted and `last_consumed()` is
/// zero. Keep calling until `Done` (then `is_finished()` is true). `end=true`
/// is sticky across `NeedMoreOutput`: gzip members are self-delimiting but the
/// stream is not, so the signal resolves whether another member can follow.
/// Concatenated multi-member streams (RFC 1952 §2.2) decode in full; their
/// payloads are joined. If the final accepted view also contains non-gzip
/// bytes, retrieve that read-ahead after `Done` with `unused_input()`. On
/// failure, the decoder locks the first `GzipError` kind/message and rethrows
/// it on every later call; both progress counters remain zero.
pub fn Decoder::step(
  self : Decoder,
  input : BytesView,
  output : MutArrayView[Byte],
  end? : Bool = false,
) -> @flate.Status raise GzipError {
  self.step_consumed = 0
  self.step_produced = 0
  match self.failure_kind {
    Some(kind) => raise GzipError(kind, self.failure_message)
    None => {
      let status = self.step_active(input, output, end~) catch {
        GzipError(kind, message) => {
          self.failure_kind = Some(kind)
          self.failure_message = message
          raise GzipError(kind, message)
        }
      }
      status
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
) -> @flate.Status raise GzipError {
  if self.mode is GzFinished {
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
  if consumed > 0 {
    self.buffer_input(input[:consumed])
  }
  if end && consumed == input.length() {
    self.ending = true
  }
  let mut op = 0
  for ;; {
    match self.mode {
      GzHeader => {
        let available = self.available()
        if self.members > 0 {
          if available == 0 {
            if self.ending {
              self.finish_stream()
              continue
            }
            return self.finish_step(NeedMoreInput, consumed, op)
          }
          if self.pending_at(0).to_int() != 0x1F {
            // A non-member byte ends the concatenated gzip stream. Preserve
            // it and the rest of the transport read for the caller.
            self.finish_stream()
            continue
          }
          if available < 2 {
            if self.ending {
              raise GzipError(Truncated, "gzip: truncated")
            }
            return self.finish_step(NeedMoreInput, consumed, op)
          }
          if self.pending_at(1).to_int() != 0x8B {
            self.finish_stream()
            continue
          }
        }
        if available < 10 {
          if self.ending {
            raise GzipError(Truncated, "gzip: truncated")
          }
          return self.finish_step(NeedMoreInput, consumed, op)
        }
        if self.pending_at(0).to_int() != 0x1F ||
          self.pending_at(1).to_int() != 0x8B {
          raise GzipError(InvalidHeader, "gzip: bad magic")
        }
        if self.pending_at(2).to_int() != 0x08 {
          raise GzipError(InvalidHeader, "gzip: unsupported compression method")
        }
        self.flg = self.pending_at(3).to_int()
        if (self.flg & 0xE0) != 0 {
          raise GzipError(InvalidHeader, "gzip: reserved flags are set")
        }
        self.advance(10)
        self.mode = self.next_header_mode(0)
      }
      GzExtraLen => {
        if self.available() < 2 {
          if self.ending {
            raise GzipError(Truncated, "gzip: truncated")
          }
          return self.finish_step(NeedMoreInput, consumed, op)
        }
        let xlen = self.pending_at(0).to_int() |
          (self.pending_at(1).to_int() << 8)
        self.advance(2)
        self.mode = GzExtra(xlen)
      }
      GzExtra(remaining) => {
        let k = if remaining < self.available() {
          remaining
        } else {
          self.available()
        }
        self.advance(k)
        if k == remaining {
          self.mode = self.next_header_mode(1)
        } else {
          self.mode = GzExtra(remaining - k)
          if self.ending {
            raise GzipError(Truncated, "gzip: truncated")
          }
          return self.finish_step(NeedMoreInput, consumed, op)
        }
      }
      GzName =>
        if self.skip_nul_terminated() {
          self.mode = self.next_header_mode(2)
        } else {
          if self.ending {
            raise GzipError(Truncated, "gzip: truncated")
          }
          return self.finish_step(NeedMoreInput, consumed, op)
        }
      GzComment =>
        if self.skip_nul_terminated() {
          self.mode = self.next_header_mode(3)
        } else {
          if self.ending {
            raise GzipError(Truncated, "gzip: truncated")
          }
          return self.finish_step(NeedMoreInput, consumed, op)
        }
      GzHcrc => {
        if self.available() < 2 {
          if self.ending {
            raise GzipError(Truncated, "gzip: truncated")
          }
          return self.finish_step(NeedMoreInput, consumed, op)
        }
        // RFC 1952 permits a decoder to skip FHCRC when it does not verify it.
        self.advance(2)
        self.mode = GzBody
      }
      GzBody => {
        let op_before = op
        let st = self.inf.step(self.pending_view(), output.mut_view(start=op)) catch {
          err => raise wrap_inflate_error(err)
        }
        let used = self.inf.last_consumed()
        let produced = self.inf.last_produced()
        if produced > 0 {
          for i in 0..<produced {
            self.crc.update_byte(output.at(op_before + i))
          }
          self.osize = self.osize + produced.reinterpret_as_uint()
        }
        op = op + produced
        self.advance(used)
        if st is Done {
          self.mode = GzTrailer
        } else if st is NeedMoreInput {
          if self.pending_snapshot_end < self.pending.length() {
            // Input accepted while output was backpressured was deliberately
            // left outside the active snapshot. The inflater has now reached
            // that boundary, so fold the unread atomic tail and appended bytes
            // into one new view and retry without exposing a false suspension.
            self.refresh_pending_snapshot()
            continue
          }
          if self.ending {
            raise GzipError(Truncated, "gzip: truncated")
          }
          return self.finish_step(NeedMoreInput, consumed, op)
        } else {
          return self.finish_step(NeedMoreOutput, consumed, op)
        }
      }
      GzTrailer => {
        if self.available() < 8 {
          if self.ending {
            raise GzipError(Truncated, "gzip: truncated")
          }
          return self.finish_step(NeedMoreInput, consumed, op)
        }
        if self.crc.finish() != self.u32_le(0) {
          raise GzipError(ChecksumMismatch, "gzip: CRC-32 mismatch")
        }
        if self.osize != self.u32_le(4) {
          raise GzipError(LengthMismatch, "gzip: length mismatch")
        }
        self.advance(8)
        // Member boundary. Reset the per-member state; the next member, if any,
        // starts fresh (RFC 1952 §2.2 — members are independent, no cross-member
        // back-references).
        self.inf.reset()
        self.crc = @checksum.Crc32::new()
        self.osize = 0
        self.flg = 0
        self.members = self.members + 1
        if !self.multistream {
          // A protocol-framed caller chose one-member mode. The trailer is
          // the exact boundary, even if the next frame itself begins with the
          // gzip magic bytes.
          self.finish_stream()
        } else if self.available() > 0 {
          // Buffered bytes begin the next member; parse it now.
          self.mode = GzHeader
        } else if self.ending {
          // The caller has signalled end-of-input at a clean boundary: done.
          self.finish_stream()
        } else {
          // No more buffered, but the caller has not signalled end: another
          // member may still arrive. Wait in GzHeader for it (or for `end`).
          self.mode = GzHeader
          return self.finish_step(NeedMoreInput, consumed, op)
        }
      }
      GzFinished => return self.finish_step(Done, consumed, op)
    }
  }
}
