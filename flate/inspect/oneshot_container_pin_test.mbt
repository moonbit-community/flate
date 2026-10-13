// What `@zlib.decompress` and `@gzip.decompress` answer, pinned like the raw
// decoders in `oneshot_pin_test.mbt`: the expectation is the streaming
// `Inflater` over the body of the container (what it decoded, where the
// stream ended, or its error) with the trailer checked on top.

///|
/// `@zlib.decompress` on a stream with the header `78 01`.
fn pin_zlib_case(label : String, input : BytesView) -> Unit raise {
  let n = input.length()
  let expected = if n < 6 {
    Err("Truncated: zlib: input too short")
  } else {
    match pin_streaming(input[2:n - 4]) {
      Err(("Truncated", _)) => Err("Truncated: zlib: truncated DEFLATE stream")
      Err((_, message)) => Err("InvalidDeflate: \{message}")
      Ok((bytes, used)) =>
        if used != n - 6 {
          Err("TrailingData: zlib: data between DEFLATE stream and trailer")
        } else if @checksum.adler32(bytes) != pin_u32(input, n - 4, false) {
          Err("ChecksumMismatch: zlib: Adler-32 mismatch")
        } else {
          Ok(bytes)
        }
    }
  }
  pin_check("\{label} zlib", pin_zlib(input), expected)
}

///|
fn pin_zlib(input : BytesView) -> Result[Bytes, String] {
  try @zlib.decompress(input) catch {
    ZlibError(kind, message) => pin_failure(kind, message)
  } noraise {
    bytes => Ok(bytes)
  }
}

///|
fn pin_u32(data : BytesView, offset : Int32, little : Bool) -> UInt32 {
  let mut value = 0U
  for i in 0..<4 {
    let shift = if little { 8 * i } else { 24 - 8 * i }
    value = value | (data[offset + i].to_uint() << shift)
  }
  value
}

///|
/// What `@gzip.decompress` answers for members with the plain ten-byte header.
fn pin_gzip_expected(input : BytesView) -> Result[Bytes, String] {
  let n = input.length()
  guard n >= 18 else { return Err("Truncated: gzip: input too short") }
  let joined = @buffer.Buffer()
  let mut p = 0
  while p < n && input[p] == 0x1F && (p + 1 >= n || input[p + 1] == 0x8B) {
    guard n - p >= 18 else { return Err("Truncated: gzip: truncated") }
    match pin_streaming(input[p + 10:]) {
      Err(("Truncated", _)) => return Err("Truncated: gzip: truncated")
      Err((_, message)) => return Err("InvalidDeflate: \{message}")
      Ok((bytes, used)) => {
        let trailer = p + 10 + used
        guard trailer <= n - 8 else { return Err("Truncated: gzip: truncated") }
        guard @checksum.crc32(bytes) == pin_u32(input, trailer, true) else {
          return Err("ChecksumMismatch: gzip: CRC-32 mismatch")
        }
        guard bytes.length().reinterpret_as_uint() ==
          pin_u32(input, trailer + 4, true) else {
          return Err("LengthMismatch: gzip: length mismatch")
        }
        joined.write_bytes(bytes)
        p = trailer + 8
      }
    }
  }
  if p == 0 {
    Err("InvalidHeader: gzip: bad magic")
  } else {
    Ok(joined.to_bytes())
  }
}

///|
fn pin_gzip_case(label : String, input : BytesView) -> Unit raise {
  pin_check("\{label} gzip", pin_gzip(input), pin_gzip_expected(input))
}

///|
fn pin_gzip(input : BytesView) -> Result[Bytes, String] {
  try @gzip.decompress(input) catch {
    GzipError(kind, message) => pin_failure(kind, message)
  } noraise {
    bytes => Ok(bytes)
  }
}

///|
fn pin_zlib_frame(raw : Bytes, plain : Bytes) -> Bytes {
  let out = @buffer.Buffer()
  out.write_bytes(b"\x78\x01")
  out.write_bytes(raw)
  out.write_uint_be(@checksum.adler32(plain))
  out.to_bytes()
}

///|
fn pin_gzip_frame(raw : Bytes, plain : Bytes) -> Bytes {
  let out = @buffer.Buffer()
  out.write_bytes(b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\xff")
  out.write_bytes(raw)
  out.write_uint_le(@checksum.crc32(plain))
  out.write_uint_le(plain.length().reinterpret_as_uint())
  out.to_bytes()
}

///|
/// The containers are cut and damaged around every small stream, and around
/// two shapes of each large one: the raw decoders have been through them all.
fn pin_container_stream(name : String, raw : Bytes) -> Bool {
  raw.length() <= 4096 || name.has_suffix(" L6") || name.has_suffix(" flushed")
}

///|
test "zlib.decompress answers as the streaming inflater" {
  for stream in pin_streams() {
    let (name, plain, raw) = stream
    let framed = pin_zlib_frame(raw, plain)
    @test.assert_eq(@zlib.decompress(framed), plain)
    guard pin_container_stream(name, raw) else { continue }
    // The header is not what changes: damage from the body on.
    pin_mutations(name, framed, pin_zlib_case, spread=6, flip_from=2)
  }
}

///|
test "gzip.decompress answers as the streaming inflater" {
  let streams = pin_streams()
  for stream in streams {
    let (name, plain, raw) = stream
    let framed = pin_gzip_frame(raw, plain)
    @test.assert_eq(@gzip.decompress(framed), plain)
    guard pin_container_stream(name, raw) else { continue }
    pin_mutations(name, framed, pin_gzip_case, spread=6, flip_from=10)
  }
  // Files of two and three members: every stream behind its neighbour, and
  // around an empty member.
  let empty = pin_gzip_frame(@flate.deflate_all(b""), b"")
  for i in 1..<streams.length() {
    let (first_name, first_plain, first_raw) = streams[i - 1]
    let (name, plain, raw) = streams[i]
    let first = pin_gzip_frame(first_raw, first_plain)
    let second = pin_gzip_frame(raw, plain)
    @test.assert_eq(@gzip.decompress(first + second), first_plain + plain)
    @test.assert_eq(
      @gzip.decompress(first + empty + second),
      first_plain + plain,
    )
    // Cut the small files at every position, extend them by 1 to 9 bytes and
    // damage each bit position of the first trailer once; no bit is flipped
    // behind it, since the expectation does not parse a damaged header.
    guard first.length() + second.length() <= 600 else { continue }
    for file in [first + second, first + empty + second] {
      pin_mutations(
        "\{first_name} + \{name}, \{file.length()} bytes",
        file,
        pin_gzip_case,
        spread=6,
        small=file.length(),
        flip_from=first.length() - 8,
        flip_to=first.length(),
      )
    }
  }
}

///|
/// The errors of the two containers around one stream, word for word.
test "zlib and gzip report a cut, an extended and a damaged file" {
  let plain = b"what follows the stream"
  let raw = @flate.deflate_all(plain)
  let flipped = (file : Bytes, from_end : Int32) => {
    let damaged = file.to_fixedarray()
    damaged[file.length() - from_end] = damaged[file.length() - from_end] ^ 1
    Bytes::from_array(damaged)
  }
  let zlib = pin_zlib_frame(raw, plain)
  let zlib_answer = (file : Bytes) => pin_show(pin_zlib(file))
  @test.assert_eq(zlib_answer(zlib), "23 bytes")
  @test.assert_eq(
    zlib_answer(zlib[:5].to_owned()),
    "Truncated: zlib: input too short",
  )
  @test.assert_eq(
    zlib_answer(zlib[:zlib.length() - 1].to_owned()),
    "Truncated: zlib: truncated DEFLATE stream",
  )
  @test.assert_eq(
    zlib_answer(zlib + b"\x00"),
    "TrailingData: zlib: data between DEFLATE stream and trailer",
  )
  @test.assert_eq(
    zlib_answer(flipped(zlib, 1)),
    "ChecksumMismatch: zlib: Adler-32 mismatch",
  )
  // A body whose only block holds the reserved literal/length code 286.
  @test.assert_eq(
    zlib_answer(pin_zlib_frame(b"\x1B\x03", b"")),
    "InvalidDeflate: corrupt: invalid literal/length code",
  )
  let gzip = pin_gzip_frame(raw, plain)
  let gzip_answer = (file : Bytes) => pin_show(pin_gzip(file))
  @test.assert_eq(gzip_answer(gzip), "23 bytes")
  @test.assert_eq(gzip_answer(gzip + gzip), "46 bytes")
  @test.assert_eq(gzip_answer(gzip + b"\x00"), "23 bytes")
  @test.assert_eq(
    gzip_answer(gzip[:17].to_owned()),
    "Truncated: gzip: input too short",
  )
  @test.assert_eq(
    gzip_answer(gzip[:gzip.length() - 1].to_owned()),
    "Truncated: gzip: truncated",
  )
  @test.assert_eq(gzip_answer(gzip + b"\x1f"), "Truncated: gzip: truncated")
  @test.assert_eq(
    gzip_answer(flipped(gzip, 5)),
    "ChecksumMismatch: gzip: CRC-32 mismatch",
  )
  @test.assert_eq(
    gzip_answer(flipped(gzip, 1)),
    "LengthMismatch: gzip: length mismatch",
  )
  @test.assert_eq(
    gzip_answer(pin_gzip_frame(b"\x1B\x03", b"")),
    "InvalidDeflate: corrupt: invalid literal/length code",
  )
}

///|
/// A block-gzipped file is thousands of small members, each handed the rest of
/// the file: one decoder serves them all.
test "gzip.decompress decodes a file of thousands of members" {
  let plain = Bytes::makei(300, i => (i * 7).to_byte())
  let framed = pin_gzip_frame(@flate.deflate_all(plain), plain)
  let file = @buffer.Buffer()
  let joined = @buffer.Buffer()
  for _ in 0..<3000 {
    file.write_bytes(framed)
    joined.write_bytes(plain)
  }
  assert_true(@gzip.decompress(file.to_bytes()) == joined.to_bytes())
}
