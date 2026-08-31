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
pub extend GzipErrorKind with Eq::{not_equal, equal}

///|
pub extend GzipErrorKind with Debug::{to_repr}

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
    @flate.InflateError(_, message) =>
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
/// Inflate the raw DEFLATE member starting at `input[q:]`; write the compressed
/// byte count (where the 8-byte trailer begins) to `consumed[0]`. The caller
/// reuses that scalar cell across members instead of allocating a return tuple.
/// The streaming inflater's reported consumption lands exactly on the
/// byte-aligned end of the member's final block.
fn inflate_member(
  input : Bytes,
  q : Int,
  consumed : FixedArray[Int],
) -> Bytes raise GzipError {
  let inf = @flate.Inflater()
  let out = Buffer()
  let buf = FixedArray::make(65536, b'\x00')
  let mut used = 0
  for ;; {
    let st = inf.step(input[q + used:], buf.mut_view()) catch {
      err => raise wrap_inflate_error(err)
    }
    let c = inf.last_consumed()
    let produced = inf.last_produced()
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
  consumed[0] = used
  out.to_bytes()
}

///|
/// Whether the bytes at `p` begin a gzip member: the magic pair, with a
/// truncated second byte treated as a (still-to-be-validated) member start so
/// the caller reports `Truncated` rather than ending the stream.
fn gunzip_member_magic(input : Bytes, p : Int, n : Int) -> Bool {
  input[p].to_int() == 0x1F && (p + 1 >= n || input[p + 1].to_int() == 0x8B)
}

///|
/// Skip a NUL-terminated header field, returning the offset one past the NUL.
/// An unterminated field (bounded by the input end) still consumes its bytes;
/// the caller's truncated-input check rejects it.
fn gunzip_skip_nul_terminated(input : Bytes, q : Int) -> Int {
  let mut q = q
  while q < input.length() && input[q].to_int() != 0 {
    q = q + 1
  }
  q + 1
}

///|
/// Offset one past the optional header fields (FEXTRA, FNAME, FCOMMENT, FHCRC)
/// gated by the FLG bits.
fn gunzip_optional_fields_end(input : Bytes, q : Int, flg : Int) -> Int {
  let mut q = q
  if (flg & 4) != 0 { // FEXTRA
    let xlen = input[q].to_int() | (input[q + 1].to_int() << 8)
    q = q + 2 + xlen
  }
  if (flg & 8) != 0 { // FNAME (NUL-terminated)
    q = gunzip_skip_nul_terminated(input, q)
  }
  if (flg & 16) != 0 { // FCOMMENT (NUL-terminated)
    q = gunzip_skip_nul_terminated(input, q)
  }
  if (flg & 2) != 0 { // FHCRC
    q = q + 2
  }
  q
}

///|
/// Decode one member at `p`: fixed header, optional fields, DEFLATE payload,
/// and trailer verification. Returns the payload and the offset of the next
/// member (one past the trailer).
fn gunzip_decode_member(
  input : Bytes,
  p : Int,
  n : Int,
  member_consumed : FixedArray[Int],
) -> (Bytes, Int) raise GzipError {
  guard n - p >= 18 else { raise GzipError(Truncated, "gzip: truncated") }
  guard input[p + 2].to_int() == 0x08 else {
    raise GzipError(InvalidHeader, "gzip: unsupported compression method")
  }
  let flg = input[p + 3].to_int()
  guard (flg & 0xE0) == 0 else {
    raise GzipError(InvalidHeader, "gzip: reserved flags are set")
  }
  let q = gunzip_optional_fields_end(input, p + 10, flg)
  guard q <= n - 8 else { raise GzipError(Truncated, "gzip: truncated") }
  let payload = inflate_member(input, q, member_consumed)
  let trailer = q + member_consumed[0]
  guard trailer <= n - 8 else { raise GzipError(Truncated, "gzip: truncated") }
  guard @checksum.crc32(payload) == u32_le(input, trailer) else {
    raise GzipError(ChecksumMismatch, "gzip: CRC-32 mismatch")
  }
  guard payload.length().reinterpret_as_uint() == u32_le(input, trailer + 4) else {
    raise GzipError(LengthMismatch, "gzip: length mismatch")
  }
  (payload, trailer + 8)
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
  guard n >= 18 else { raise GzipError(Truncated, "gzip: input too short") }
  let out = Buffer()
  let member_consumed = FixedArray::make(1, 0)
  let mut p = 0
  for ;; {
    // Stop once no further member begins: clean end or trailing garbage. A
    // complete magic prefix does begin another member, however, so it must be
    // decoded or reported as truncated rather than silently discarded.
    guard p < n else { break }
    guard gunzip_member_magic(input, p, n) else {
      guard p == 0 else { break }
      raise GzipError(InvalidHeader, "gzip: bad magic")
    }
    let (payload, next_p) = gunzip_decode_member(input, p, n, member_consumed)
    for b in payload {
      out.write_byte(b)
    }
    p = next_p
  }
  out.to_bytes()
}
