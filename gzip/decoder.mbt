// Streaming gzip (RFC 1952) decompressor: a push-based, suspendable state
// machine wrapping the `@flate.Inflater`. The variable-length header is parsed
// zlib-style with one state per field: the unbounded fields (FEXTRA payload,
// FNAME, FCOMMENT) are consumed as they arrive and discarded, never retained,
// so header-phase memory is O(1) even against an adversarial unterminated
// FNAME. It then drives the inflater over the DEFLATE body (folding
// decompressed output into a running CRC-32 and length) and verifies the
// 8-byte trailer. The one-shot `gunzip` remains for in-memory use.

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
  priv mut flg : Int // header FLG byte, gates the optional-field states
  priv mut mode : DecMode
}

///|
/// Create a fresh gzip decompressor.
pub fn Decoder::new() -> Decoder {
  {
    inf: @flate.Inflater::new(),
    crc: @checksum.Crc32::new(),
    osize: 0,
    pending: [],
    flg: 0,
    mode: GzHeader,
  }
}

///|
/// Whether the whole gzip stream has been decoded and its trailer verified.
pub fn Decoder::is_finished(self : Decoder) -> Bool {
  self.mode is GzFinished
}

///|
/// Drop the first `k` consumed bytes of `pending`.
fn Decoder::drop_prefix(self : Decoder, k : Int) -> Unit {
  if k <= 0 {
    return
  }
  let kept : Array[Byte] = []
  for j in k..<self.pending.length() {
    kept.push(self.pending[j])
  }
  self.pending = kept
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
  for j in 0..<self.pending.length() {
    if self.pending[j] == b'\x00' {
      nul = j
      break
    }
  }
  if nul >= 0 {
    self.drop_prefix(nul + 1)
    true
  } else {
    self.pending.clear()
    false
  }
}

///|
/// Read a little-endian u32 from `pending` at `off`.
fn Decoder::u32_le(self : Decoder, off : Int) -> UInt {
  self.pending[off].to_uint() |
  (self.pending[off + 1].to_uint() << 8) |
  (self.pending[off + 2].to_uint() << 16) |
  (self.pending[off + 3].to_uint() << 24)
}

///|
/// Run one decompression step. Buffers `input`, then decodes plaintext into
/// the mutable view `output`. Returns `(status, consumed,
/// produced)`; `consumed` is always the whole input view. Keep calling until
/// `Done` (then `is_finished()` is true). Pass `end=true` once no more input is
/// coming: gzip members are self-delimiting but the stream is not — after a
/// member's trailer the decoder cannot tell end-of-stream from a not-yet-arrived
/// next member, so `end` resolves that boundary (mirrors `Deflater::step` /
/// zlib `Z_FINISH`). Concatenated multi-member streams (RFC 1952 §2.2) decode in
/// full; their payloads are joined.
pub fn Decoder::step(
  self : Decoder,
  input : BytesView,
  output : MutArrayView[Byte],
  end? : Bool = false,
) -> (@flate.Status, Int, Int) raise {
  for i in 0..<input.length() {
    self.pending.push(input[i])
  }
  let consumed = input.length()
  let mut op = 0
  for ;; {
    match self.mode {
      GzHeader => {
        if self.pending.length() < 10 {
          // Too few bytes for a header. At end-of-input this is a clean stop:
          // either nothing follows the last member, or a sub-header trailing
          // remnant that is not another member — ignored, as `gunzip` does.
          if end {
            self.mode = GzFinished
            continue
          } else {
            return (NeedMoreInput, consumed, op)
          }
        }
        if self.pending[0].to_int() != 0x1F || self.pending[1].to_int() != 0x8B {
          raise GzipError("gzip: bad magic")
        }
        if self.pending[2].to_int() != 0x08 {
          raise GzipError("gzip: unsupported compression method")
        }
        self.flg = self.pending[3].to_int()
        self.drop_prefix(10)
        self.mode = self.next_header_mode(0)
      }
      GzExtraLen => {
        if self.pending.length() < 2 {
          return (NeedMoreInput, consumed, op)
        }
        let xlen = self.pending[0].to_int() | (self.pending[1].to_int() << 8)
        self.drop_prefix(2)
        self.mode = GzExtra(xlen)
      }
      GzExtra(remaining) => {
        let k = if remaining < self.pending.length() {
          remaining
        } else {
          self.pending.length()
        }
        self.drop_prefix(k)
        if k == remaining {
          self.mode = self.next_header_mode(1)
        } else {
          self.mode = GzExtra(remaining - k)
          return (NeedMoreInput, consumed, op)
        }
      }
      GzName =>
        if self.skip_nul_terminated() {
          self.mode = self.next_header_mode(2)
        } else {
          return (NeedMoreInput, consumed, op)
        }
      GzComment =>
        if self.skip_nul_terminated() {
          self.mode = self.next_header_mode(3)
        } else {
          return (NeedMoreInput, consumed, op)
        }
      GzHcrc => {
        if self.pending.length() < 2 {
          return (NeedMoreInput, consumed, op)
        }
        self.drop_prefix(2)
        self.mode = GzBody
      }
      GzBody => {
        let op_before = op
        let data = Bytes::from_array(self.pending)
        let (st, used, produced) = self.inf.step(data[:], output.mut_view(start=op))
        if produced > 0 {
          for i in 0..<produced {
            self.crc.update_byte(output.at(op_before + i))
          }
          self.osize = self.osize + produced.reinterpret_as_uint()
        }
        op = op + produced
        self.drop_prefix(used)
        if st is Done {
          self.mode = GzTrailer
        } else if st is NeedMoreInput {
          return (NeedMoreInput, consumed, op)
        } else {
          return (NeedMoreOutput, consumed, op)
        }
      }
      GzTrailer => {
        if self.pending.length() < 8 {
          return (NeedMoreInput, consumed, op)
        }
        if self.crc.finish() != self.u32_le(0) {
          raise GzipError("gzip: CRC-32 mismatch")
        }
        if self.osize != self.u32_le(4) {
          raise GzipError("gzip: length mismatch")
        }
        self.drop_prefix(8)
        // Member boundary. Reset the per-member state; the next member, if any,
        // starts fresh (RFC 1952 §2.2 — members are independent, no cross-member
        // back-references).
        self.inf.reset()
        self.crc = @checksum.Crc32::new()
        self.osize = 0
        self.flg = 0
        if self.pending.length() > 0 {
          // Buffered bytes begin the next member; parse it now.
          self.mode = GzHeader
        } else if end {
          // The caller has signalled end-of-input at a clean boundary: done.
          self.mode = GzFinished
        } else {
          // No more buffered, but the caller has not signalled end: another
          // member may still arrive. Wait in GzHeader for it (or for `end`).
          self.mode = GzHeader
          return (NeedMoreInput, consumed, op)
        }
      }
      GzFinished => return (Done, consumed, op)
    }
  }
}
