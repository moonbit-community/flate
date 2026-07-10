// zlib (RFC 1950) = a 2-byte header + raw DEFLATE + a 4-byte big-endian
// Adler-32 trailer. Thin wrapper over the `@flate` engine.

///|
/// Machine-readable category for a zlib decoding failure. The accompanying
/// `ZlibError` message remains intended for diagnostics rather than branching.
pub(all) enum ZlibErrorKind {
  /// The input ended before the header, body, DICTID, or trailer completed.
  Truncated
  /// CMF/FLG contains an unsupported method, window size, or bad header check.
  InvalidHeader
  /// The stream announces FDICT but the caller supplied no dictionary.
  DictionaryRequired
  /// The supplied dictionary does not match the stream's DICTID.
  DictionaryMismatch
  /// The wrapped raw DEFLATE payload is malformed.
  InvalidDeflate
  /// The Adler-32 trailer does not match the decompressed payload.
  ChecksumMismatch
  /// Bytes occur after the raw DEFLATE end and before the expected trailer.
  TrailingData
} derive(Eq, Debug)

///|
/// Structured zlib decoding failure: a stable category plus a human-readable
/// diagnostic.
pub suberror ZlibError {
  ZlibError(ZlibErrorKind, String)
}

///|
fn u32_be(data : Bytes, off : Int) -> UInt {
  (data[off].to_uint() << 24) |
  (data[off + 1].to_uint() << 16) |
  (data[off + 2].to_uint() << 8) |
  data[off + 3].to_uint()
}

///|
/// Inflate a complete raw DEFLATE payload and require the inflater to consume
/// every byte. `inflate_all` intentionally accepts a DEFLATE prefix, which is
/// useful to some callers but would let bytes hide between a zlib body and its
/// Adler-32 trailer.
fn inflate_exact(input : BytesView) -> Bytes raise ZlibError {
  let inf = @flate.Inflater::new()
  let scratch = FixedArray::make(32768, b'\x00')
  let out = Buffer()
  let mut pos = 0
  for ;; {
    let status = inf.step(input[pos:], scratch.mut_view()) catch {
      InflateError(_, message) =>
        raise ZlibError(
          InvalidDeflate,
          "zlib: invalid DEFLATE stream: \{message}",
        )
    }
    let consumed = inf.last_consumed()
    let produced = inf.last_produced()
    pos = pos + consumed
    for i in 0..<produced {
      out.write_byte(scratch[i])
    }
    match status {
      Done => {
        if pos != input.length() {
          raise ZlibError(
            TrailingData,
            "zlib: data between DEFLATE stream and trailer",
          )
        }
        return out.to_bytes()
      }
      NeedMoreOutput => continue
      NeedMoreInput =>
        // The complete payload is already visible. Retrying the same suffix
        // cannot make progress because Inflater rewinds an incomplete unit.
        raise ZlibError(Truncated, "zlib: truncated DEFLATE stream")
    }
  }
}

///|
/// Wrap a raw DEFLATE stream `deflated` of `input` in the zlib header/trailer.
fn zlib_frame(input : Bytes, deflated : Bytes) -> Bytes {
  let out = Buffer()
  // CMF=0x78 (CM=8 deflate, CINFO=7 -> 32K window); FLG=0x01 makes the
  // 16-bit header a multiple of 31 with FLEVEL=0 and no preset dictionary.
  out.write_byte(b'\x78')
  out.write_byte(b'\x01')
  for b in deflated {
    out.write_byte(b)
  }
  let adler = @checksum.adler32(input)
  out.write_byte(((adler >> 24) & 0xFF).reinterpret_as_int().to_byte())
  out.write_byte(((adler >> 16) & 0xFF).reinterpret_as_int().to_byte())
  out.write_byte(((adler >> 8) & 0xFF).reinterpret_as_int().to_byte())
  out.write_byte((adler & 0xFF).reinterpret_as_int().to_byte())
  out.to_bytes()
}

///|
/// Compress `input` into the zlib format. `level` 0-9 (clamped) trades speed
/// for ratio; 0 = stored only, 6 = default.
pub fn zlib_compress(input : Bytes, level? : Int = 6) -> Bytes {
  zlib_frame(input, @flate.deflate_all(input, level~))
}

///|
/// Compress `input` into the zlib format with zopfli-style optimal parsing:
/// far slower (offline, whole input in memory) for a few percent smaller
/// output. For compress-once, serve-forever artifacts (e.g. a PNG's zlib
/// stream). `iterations` is the squeeze count per block (zopfli's default 15).
pub fn zlib_compress_optimal(input : Bytes, iterations? : Int = 15) -> Bytes {
  zlib_frame(input, @flate.deflate_all_optimal(input, iterations~))
}

///|
/// Decompress zlib-format `input`, verifying its Adler-32 trailer. The output
/// grows without bound — a convenience for trusted input; for untrusted input
/// use the streaming `Decoder` with caller-sized output buffers. Failures carry
/// a stable `ZlibErrorKind` suitable for programmatic handling plus a
/// human-readable diagnostic.
pub fn zlib_decompress(input : Bytes) -> Bytes raise ZlibError {
  let n = input.length()
  if n < 6 {
    raise ZlibError(Truncated, "zlib: input too short")
  }
  let cmf = input[0].to_int()
  let flg = input[1].to_int()
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
    raise ZlibError(
      DictionaryRequired,
      "zlib: preset dictionary required (use the streaming Decoder)",
    )
  }
  let out = inflate_exact(input[2:n - 4])
  if @checksum.adler32(out) != u32_be(input, n - 4) {
    raise ZlibError(ChecksumMismatch, "zlib: Adler-32 mismatch")
  }
  out
}
