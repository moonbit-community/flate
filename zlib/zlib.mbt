// zlib (RFC 1950) = a 2-byte header + raw DEFLATE + a 4-byte big-endian
// Adler-32 trailer. Thin wrapper over the `@flate` engine.

///|
pub suberror ZlibError {
  ZlibError(String)
}

///|
fn u32_be(data : Bytes, off : Int) -> UInt {
  (data[off].to_uint() << 24) |
  (data[off + 1].to_uint() << 16) |
  (data[off + 2].to_uint() << 8) |
  data[off + 3].to_uint()
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
/// use the streaming `Decoder` with caller-sized output buffers.
pub fn zlib_decompress(input : Bytes) -> Bytes raise {
  let n = input.length()
  if n < 6 {
    raise ZlibError("zlib: input too short")
  }
  let cmf = input[0].to_int()
  let flg = input[1].to_int()
  if (cmf & 0x0F) != 8 {
    raise ZlibError("zlib: unsupported compression method")
  }
  if (cmf * 256 + flg) % 31 != 0 {
    raise ZlibError("zlib: bad header check")
  }
  if (flg & 0x20) != 0 {
    raise ZlibError(
      "zlib: preset dictionary required (use the streaming Decoder)",
    )
  }
  let out = @flate.inflate_all(input[2:n - 4].to_owned())
  if @checksum.adler32(out) != u32_be(input, n - 4) {
    raise ZlibError("zlib: Adler-32 mismatch")
  }
  out
}
