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
  priv mut pending : Array[Byte] // unconsumed compressed input
  priv mut mode : DecMode
  priv dict : Bytes? // preset dictionary, if the caller has one
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
    mode: ZHeader,
    dict: dictionary,
  }
}

///|
/// Whether the whole zlib stream has been decoded and its trailer verified.
pub fn Decoder::is_finished(self : Decoder) -> Bool {
  self.mode is ZFinished
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
/// Read a big-endian u32 from `pending` at `off`.
fn Decoder::u32_be(self : Decoder, off : Int) -> UInt {
  (self.pending[off].to_uint() << 24) |
  (self.pending[off + 1].to_uint() << 16) |
  (self.pending[off + 2].to_uint() << 8) |
  self.pending[off + 3].to_uint()
}

///|
/// Run one decompression step. Buffers `input`, then decodes plaintext into
/// the mutable view `output`. Returns `(status, consumed, produced)`;
/// `consumed` is always the whole input view. Keep calling until `Done`.
pub fn Decoder::step(
  self : Decoder,
  input : BytesView,
  output : MutArrayView[Byte],
) -> (@flate.Status, Int, Int) raise {
  for i in 0..<input.length() {
    self.pending.push(input[i])
  }
  let consumed = input.length()
  let mut op = 0
  for ;; {
    match self.mode {
      ZHeader => {
        if self.pending.length() < 2 {
          return (NeedMoreInput, consumed, op)
        }
        let cmf = self.pending[0].to_int()
        let flg = self.pending[1].to_int()
        if (cmf & 0x0F) != 8 {
          raise ZlibError("zlib: unsupported compression method")
        }
        if (cmf * 256 + flg) % 31 != 0 {
          raise ZlibError("zlib: bad header check")
        }
        if (flg & 0x20) != 0 {
          // FDICT: a 4-byte DICTID follows; verify it against the supplied
          // dictionary and preload the inflater's window.
          if self.pending.length() < 6 {
            return (NeedMoreInput, consumed, op)
          }
          let dictid = self.u32_be(2)
          match self.dict {
            None => raise ZlibError("zlib: preset dictionary required")
            Some(dict) => {
              if @checksum.adler32(dict) != dictid {
                raise ZlibError("zlib: dictionary id mismatch")
              }
              self.inf.set_dictionary(dict[:])
            }
          }
          self.drop_prefix(6)
        } else {
          self.drop_prefix(2)
        }
        self.mode = ZBody
      }
      ZBody => {
        let op_before = op
        let data = Bytes::from_array(self.pending)
        let (st, used, produced) = self.inf.step(data[:], output.mut_view(start=op))
        if produced > 0 {
          for i in 0..<produced {
            self.adler.update_byte(output.at(op_before + i))
          }
        }
        op = op + produced
        self.drop_prefix(used)
        if st is Done {
          self.mode = ZTrailer
        } else if st is NeedMoreInput {
          return (NeedMoreInput, consumed, op)
        } else {
          return (NeedMoreOutput, consumed, op)
        }
      }
      ZTrailer => {
        if self.pending.length() < 4 {
          return (NeedMoreInput, consumed, op)
        }
        if self.adler.finish() != self.u32_be(0) {
          raise ZlibError("zlib: Adler-32 mismatch")
        }
        self.drop_prefix(4)
        self.mode = ZFinished
      }
      ZFinished => return (Done, consumed, op)
    }
  }
}
