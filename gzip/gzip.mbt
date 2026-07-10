// gzip (RFC 1952) = a 10-byte header + raw DEFLATE + an 8-byte trailer
// (CRC-32 then ISIZE, both little-endian). Thin wrapper over the `@flate` engine.

///|
/// Machine-readable category for a gzip decoding failure. The accompanying
/// `GzipError` message remains intended for diagnostics rather than branching.
pub(all) enum GzipErrorKind {
  /// The input ended before a complete member, header field, body, or trailer.
  Truncated
  /// The fixed header, magic bytes, method, or reserved flags are invalid.
  InvalidHeader
  /// The member's raw DEFLATE payload is malformed.
  InvalidDeflate
  /// The trailer CRC-32 does not match the decompressed payload.
  ChecksumMismatch
  /// The trailer ISIZE does not match the decompressed payload length.
  LengthMismatch
} derive(Eq, Debug)

///|
/// Structured gzip decoding failure: a stable category plus a human-readable
/// diagnostic.
pub suberror GzipError {
  GzipError(GzipErrorKind, String)
}

///|
/// Translate every inner inflater failure at the gzip package boundary. Keep
/// the known DEFLATE diagnostic while retaining a total fallback if the inner
/// implementation gains another error kind in the future.
fn wrap_inflate_error(err : Error) -> GzipError {
  match err {
    @flate.InflateError(message) =>
      GzipError(InvalidDeflate, "gzip: invalid DEFLATE stream: \{message}")
    _ => GzipError(InvalidDeflate, "gzip: invalid DEFLATE stream")
  }
}

///|
fn put_u32_le(out : Buffer, v : UInt) -> Unit {
  out.write_byte((v & 0xFF).reinterpret_as_int().to_byte())
  out.write_byte(((v >> 8) & 0xFF).reinterpret_as_int().to_byte())
  out.write_byte(((v >> 16) & 0xFF).reinterpret_as_int().to_byte())
  out.write_byte(((v >> 24) & 0xFF).reinterpret_as_int().to_byte())
}

///|
fn u32_le(data : Bytes, off : Int) -> UInt {
  data[off].to_uint() |
  (data[off + 1].to_uint() << 8) |
  (data[off + 2].to_uint() << 16) |
  (data[off + 3].to_uint() << 24)
}

///|
/// Wrap a raw DEFLATE stream `deflated` of `input` in the gzip header/trailer.
fn gzip_frame(input : Bytes, deflated : Bytes) -> Bytes {
  let out = Buffer()
  // Header: magic, CM=8 (deflate), FLG=0, MTIME=0, XFL=0, OS=255 (unknown).
  for b in [0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF] {
    out.write_byte(b.to_byte())
  }
  for b in deflated {
    out.write_byte(b)
  }
  put_u32_le(out, @checksum.crc32(input))
  put_u32_le(out, input.length().reinterpret_as_uint())
  out.to_bytes()
}

///|
/// Compress `input` into the gzip file format. `level` 0-9 (clamped) trades
/// speed for ratio; 0 = stored only, 6 = default.
pub fn gzip_compress(input : Bytes, level? : Int = 6) -> Bytes {
  gzip_frame(input, @flate.deflate_all(input, level~))
}

///|
/// Compress `input` into the gzip file format with zopfli-style optimal
/// parsing: far slower (offline, whole input in memory) for a few percent
/// smaller output. For compress-once, serve-forever artifacts (e.g. a
/// precompressed `.gz` asset). `iterations` is the squeeze count per block
/// (zopfli's default 15).
pub fn gzip_compress_optimal(input : Bytes, iterations? : Int = 15) -> Bytes {
  gzip_frame(input, @flate.deflate_all_optimal(input, iterations~))
}

///|
/// Inflate the raw DEFLATE member starting at `input[q:]`, returning the
/// decompressed bytes and the number of compressed bytes consumed (where the
/// 8-byte trailer begins). Driven over the streaming `@flate.Inflater`, whose
/// reported consumption lands exactly on the byte-aligned end of the member's
/// final block, so the caller can locate the trailer and any next member.
fn inflate_member(input : Bytes, q : Int) -> (Bytes, Int) raise GzipError {
  let inf = @flate.Inflater::new()
  let out = Buffer()
  let buf = FixedArray::make(65536, b'\x00')
  let mut used = 0
  for ;; {
    let (st, c, produced) = inf.step(input[q + used:], buf.mut_view()) catch {
      err => raise wrap_inflate_error(err)
    }
    used = used + c
    for i in 0..<produced {
      out.write_byte(buf[i])
    }
    if st is Done {
      break
    }
    if st is NeedMoreInput {
      // All remaining input was handed over, yet the stream did not end.
      raise GzipError(Truncated, "gzip: truncated")
    }
    // NeedMoreOutput: drain `buf` and continue over the unconsumed tail.
  }
  (out.to_bytes(), used)
}

///|
/// Decompress gzip-format `input`, verifying each member's CRC-32 and length
/// trailer. Concatenated multi-member streams (RFC 1952 §2.2 — e.g. from `pigz`
/// or appended `.gz` logs) are decoded in full, their payloads joined; trailing
/// bytes after the last member that do not begin another are ignored, as `gzip
/// -d` does. The output grows without bound — a convenience for trusted input;
/// for untrusted input use the streaming `Decoder` with caller-sized output
/// buffers. Failures carry a stable `GzipErrorKind` suitable for programmatic
/// handling plus a human-readable diagnostic.
pub fn gunzip(input : Bytes) -> Bytes raise GzipError {
  let n = input.length()
  if n < 18 {
    raise GzipError(Truncated, "gzip: input too short")
  }
  let out = Buffer()
  let mut p = 0
  for ;; {
    // Stop once no further member begins: clean end or trailing garbage. A
    // complete magic prefix does begin another member, however, so it must be
    // decoded or reported as truncated rather than silently discarded.
    if p == n {
      break
    }
    if input[p].to_int() != 0x1F {
      if p == 0 {
        raise GzipError(InvalidHeader, "gzip: bad magic")
      }
      break
    }
    if n - p < 2 {
      raise GzipError(Truncated, "gzip: truncated")
    }
    if input[p + 1].to_int() != 0x8B {
      if p == 0 {
        raise GzipError(InvalidHeader, "gzip: bad magic")
      }
      break
    }
    if n - p < 18 {
      raise GzipError(Truncated, "gzip: truncated")
    }
    if input[p + 2].to_int() != 0x08 {
      raise GzipError(InvalidHeader, "gzip: unsupported compression method")
    }
    let flg = input[p + 3].to_int()
    if (flg & 0xE0) != 0 {
      raise GzipError(InvalidHeader, "gzip: reserved flags are set")
    }
    let mut q = p + 10
    if (flg & 4) != 0 { // FEXTRA
      let xlen = input[q].to_int() | (input[q + 1].to_int() << 8)
      q = q + 2 + xlen
    }
    if (flg & 8) != 0 { // FNAME (NUL-terminated)
      while q < n && input[q].to_int() != 0 {
        q = q + 1
      }
      q = q + 1
    }
    if (flg & 16) != 0 { // FCOMMENT (NUL-terminated)
      while q < n && input[q].to_int() != 0 {
        q = q + 1
      }
      q = q + 1
    }
    if (flg & 2) != 0 { // FHCRC
      q = q + 2
    }
    if q > n - 8 {
      raise GzipError(Truncated, "gzip: truncated")
    }
    let (payload, deflate_len) = inflate_member(input, q)
    let trailer = q + deflate_len
    if trailer > n - 8 {
      raise GzipError(Truncated, "gzip: truncated")
    }
    if @checksum.crc32(payload) != u32_le(input, trailer) {
      raise GzipError(ChecksumMismatch, "gzip: CRC-32 mismatch")
    }
    if payload.length().reinterpret_as_uint() != u32_le(input, trailer + 4) {
      raise GzipError(LengthMismatch, "gzip: length mismatch")
    }
    for b in payload {
      out.write_byte(b)
    }
    p = trailer + 8
  }
  out.to_bytes()
}
