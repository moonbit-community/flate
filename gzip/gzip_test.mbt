///|
let data : Bytes = b"hello, hello, hello world! the quick brown fox."

///|
/// gzip stream produced by python's zlib (wbits=31).
let py_gzip : Bytes = [
  0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0xCB, 0x48, 0xCD, 0xC9,
  0xC9, 0xD7, 0x51, 0xC8, 0x40, 0xA2, 0x14, 0xCA, 0xF3, 0x8B, 0x72, 0x52, 0x14, 0x15,
  0x4A, 0x32, 0x52, 0x15, 0x0A, 0x4B, 0x33, 0x93, 0xB3, 0x15, 0x92, 0x8A, 0xF2, 0xCB,
  0xF3, 0x14, 0xD2, 0xF2, 0x2B, 0xF4, 0x00, 0xB3, 0x50, 0x37, 0xEC, 0x2F, 0x00, 0x00,
  0x00,
]

///|
test "gunzip decodes a python-produced gzip stream" {
  assert_eq(@gzip.gunzip(py_gzip), data)
}

///|
test "gzip round-trip" {
  assert_eq(@gzip.gunzip(@gzip.gzip_compress(data)), data)
}

///|
test "gzip round-trip: empty" {
  assert_eq(@gzip.gunzip(@gzip.gzip_compress(b"")), b"")
}

///|
/// Complete RFC 1952 golden for a level-0 stored member. Python's
/// `gzip.compress(b"abc", compresslevel=0, mtime=0)` produces the same raw
/// DEFLATE bytes and trailer; its header advertises fast compression with
/// XFL=4, while this encoder deliberately uses the valid neutral XFL=0.
test "gzip_compress level 0 matches a complete standard golden" {
  let golden : Bytes = [
    // Fixed gzip header (MTIME=0, XFL=0, OS=unknown).
    0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF,
    // Final stored DEFLATE block: LEN=3, NLEN=0xFFFC, then "abc".
     0x01, 0x03, 0x00, 0xFC, 0xFF, 0x61, 0x62, 0x63,
    // CRC32("abc")=0x352441C2 (little-endian), ISIZE=3.
     0xC2, 0x41, 0x24, 0x35, 0x03, 0x00, 0x00, 0x00,
  ]
  assert_eq(@gzip.gzip_compress(b"abc", level=0), golden)
}

///|
/// Optimal (zopfli-style) gzip round-trips and is no larger than level 6.
test "gzip_compress_optimal round-trips and is no larger than level 6" {
  let payload = b"the quick brown fox jumps over the lazy dog. the quick brown fox jumps over the lazy dog. pack my box with five dozen liquor jugs."
  let opt = @gzip.gzip_compress_optimal(payload)
  assert_eq(@gzip.gunzip(opt), payload)
  assert_true(opt.length() <= @gzip.gzip_compress(payload, level=6).length())
}

///|
test "gzip_compress_optimal: empty" {
  assert_eq(@gzip.gunzip(@gzip.gzip_compress_optimal(b"")), b"")
}

///|
/// Concatenate byte sequences.
fn concat_bytes(parts : Array[Bytes]) -> Bytes {
  let b = Buffer()
  for part in parts {
    for x in part {
      b.write_byte(x)
    }
  }
  b.to_bytes()
}

///|
/// Copy the first `n` bytes of `data` into an owned value.
fn prefix_bytes(data : Bytes, n : Int) -> Bytes {
  let out = Buffer()
  for i in 0..<n {
    out.write_byte(data[i])
  }
  out.to_bytes()
}

///|
/// Multi-member gzip (RFC 1952 §2.2): concatenated members decode to the joined
/// payloads. The middle member is python's real stream, proving interop.
test "gunzip decodes a multi-member stream" {
  let stream = concat_bytes([
    @gzip.gzip_compress(b"first. "),
    py_gzip,
    @gzip.gzip_compress(b" last."),
  ])
  let want = concat_bytes([b"first. ", data, b" last."])
  assert_eq(@gzip.gunzip(stream), want)
}

///|
/// Trailing bytes that do not begin another member are ignored, like `gzip -d`.
test "gunzip ignores trailing garbage after the last member" {
  let stream = concat_bytes([@gzip.gzip_compress(data), b"\x00\x01\x02\x04\x05"])
  assert_eq(@gzip.gunzip(stream), data)
}

///|
/// Streaming `Decoder` decodes a multi-member stream fed in one pass, draining a
/// tiny output buffer (heavy NeedMoreOutput suspension across member boundaries).
test "streaming gzip Decoder decodes a multi-member stream" {
  let p1 = b"alpha alpha alpha alpha "
  let p2 = b"beta beta beta beta beta "
  let stream = concat_bytes([@gzip.gzip_compress(p1), @gzip.gzip_compress(p2)])
  let dec = @gzip.Decoder::new()
  let obuf = FixedArray::make(8, b'\x00')
  let out = Buffer()
  let mut fed = false
  for ;; {
    let view = if fed { b""[:] } else { stream[:] }
    fed = true
    let (_st, _c, p) = dec.step(view, obuf.mut_view(), end=true)
    for i in 0..<p {
      out.write_byte(obuf[i])
    }
    if dec.is_finished() {
      break
    }
  }
  assert_eq(out.to_bytes(), concat_bytes([p1, p2]))
}

///|
/// Multi-member fed 3 input bytes at a time: with `end` marking true EOF, the
/// decoder never mistakes a chunk boundary that lands on a member boundary for
/// the end of the stream — the case the buffered heuristic alone could not
/// handle. Three members, the middle one python's real stream.
test "streaming gzip Decoder decodes a multi-member stream in tiny chunks" {
  let stream = concat_bytes([
    @gzip.gzip_compress(b"one "),
    py_gzip,
    @gzip.gzip_compress(b" three"),
  ])
  let want = concat_bytes([b"one ", data, b" three"])
  let dec = @gzip.Decoder::new()
  let obuf = FixedArray::make(5, b'\x00')
  let out = Buffer()
  let n = stream.length()
  let mut fed = 0
  for ;; {
    let next = if fed + 3 < n { fed + 3 } else { n }
    let (_st, c, p) = dec.step(stream[fed:next], obuf.mut_view(), end=next == n)
    for i in 0..<p {
      out.write_byte(obuf[i])
    }
    fed = fed + c
    if dec.is_finished() {
      break
    }
  }
  assert_eq(out.to_bytes(), want)
}

///|
/// Stream ~60 KB through the suspendable `gzip.Encoder` in 500-byte input
/// chunks, draining a 50-byte output buffer — exercising multi-block deflate,
/// header/trailer suspension, and incremental CRC-32 — then verify with the
/// one-shot `gunzip`.
test "streaming gzip Encoder round-trips through gunzip" {
  let unit = b"streaming gzip test payload, the quick brown fox. "
  let arr : Array[Byte] = []
  for _r in 0..<1200 {
    for i in 0..<unit.length() {
      arr.push(unit[i])
    }
  }
  let src = Bytes::from_array(arr)
  let enc = @gzip.Encoder::new()
  let obuf = FixedArray::make(50, b'\x00')
  let out = Buffer()
  let n = src.length()
  let mut pos = 0
  let mut sent_end = false
  for ;; {
    let last = sent_end || pos + 500 >= n
    let endi = if pos + 500 < n { pos + 500 } else { n }
    let chunk = if sent_end { src[n:n] } else { src[pos:endi] }
    let (_st, c, p) = enc.step(chunk, obuf.mut_view(), end=last)
    for i in 0..<p {
      out.write_byte(obuf[i])
    }
    pos = pos + c
    if last {
      sent_end = true
    }
    if enc.is_finished() {
      break
    }
  }
  assert_eq(@gzip.gunzip(out.to_bytes()), src)
}

///|
test "streaming gzip Encoder: empty input" {
  let enc = @gzip.Encoder::new()
  let obuf = FixedArray::make(64, b'\x00')
  let out = Buffer()
  for ;; {
    let (_st, _c, p) = enc.step(b""[:], obuf.mut_view(), end=true)
    for i in 0..<p {
      out.write_byte(obuf[i])
    }
    if enc.is_finished() {
      break
    }
  }
  assert_eq(@gzip.gunzip(out.to_bytes()), b"")
}

///|
/// Decode the python-produced gzip vector through the streaming `gzip.Decoder`,
/// revealing 3 input bytes at a time into a 7-byte output buffer — exercising
/// both NeedMoreInput and NeedMoreOutput suspension and the CRC/length verify.
test "streaming gzip Decoder decodes a python gzip stream in tiny chunks" {
  let dec = @gzip.Decoder::new()
  let obuf = FixedArray::make(7, b'\x00')
  let out = Buffer()
  let n = py_gzip.length()
  let mut fed = 0
  for ;; {
    let next = if fed + 3 < n { fed + 3 } else { n }
    let (_st, c, p) = dec.step(
      py_gzip[fed:next],
      obuf.mut_view(),
      end=next == n,
    )
    for i in 0..<p {
      out.write_byte(obuf[i])
    }
    fed = fed + c
    if dec.is_finished() {
      break
    }
  }
  assert_eq(out.to_bytes(), data)
}

///|
/// Stream a ~50 KB gzip blob (built by the one-shot `gzip_compress`) through the
/// streaming `gzip.Decoder` in 64-byte input chunks, draining a 13-byte output
/// buffer.
test "streaming gzip Decoder round-trips a large stream" {
  let unit = b"streaming gzip decode payload, the quick brown fox. "
  let arr : Array[Byte] = []
  for _r in 0..<1000 {
    for i in 0..<unit.length() {
      arr.push(unit[i])
    }
  }
  let src = Bytes::from_array(arr)
  let gz = @gzip.gzip_compress(src)
  let dec = @gzip.Decoder::new()
  let obuf = FixedArray::make(13, b'\x00')
  let out = Buffer()
  let n = gz.length()
  let mut fed = 0
  for ;; {
    let next = if fed + 64 < n { fed + 64 } else { n }
    let (_st, c, p) = dec.step(gz[fed:next], obuf.mut_view(), end=next == n)
    for i in 0..<p {
      out.write_byte(obuf[i])
    }
    fed = fed + c
    if dec.is_finished() {
      break
    }
  }
  assert_eq(out.to_bytes(), src)
}

///|
test "streaming gzip Decoder: empty" {
  let gz = @gzip.gzip_compress(b"")
  let dec = @gzip.Decoder::new()
  let obuf = FixedArray::make(8, b'\x00')
  let out = Buffer()
  let n = gz.length()
  let mut fed = 0
  for ;; {
    let next = if fed + 1 < n { fed + 1 } else { n }
    let (_st, c, p) = dec.step(gz[fed:next], obuf.mut_view(), end=next == n)
    for i in 0..<p {
      out.write_byte(obuf[i])
    }
    fed = fed + c
    if dec.is_finished() {
      break
    }
  }
  assert_eq(out.to_bytes(), b"")
}

///|
/// A gzip stream carrying every optional header field (FEXTRA, FNAME,
/// FCOMMENT, FHCRC), decoded by the streaming Decoder one byte at a time —
/// exercising suspension inside each header field state.
test "streaming gzip Decoder skips optional header fields" {
  let payload = b"optional header fields payload, the quick brown fox."
  let gz = @gzip.gzip_compress(payload)
  let arr : Array[Byte] = []
  // Fixed header with FLG = FHCRC | FEXTRA | FNAME | FCOMMENT = 0x1E.
  for b in [0x1F, 0x8B, 0x08, 0x1E, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF] {
    arr.push(b.to_byte())
  }
  // FEXTRA: XLEN = 4, then 4 payload bytes.
  for b in [0x04, 0x00, 0xDE, 0xAD, 0xBE, 0xEF] {
    arr.push(b.to_byte())
  }
  // FNAME and FCOMMENT, NUL-terminated.
  for b in b"a-rather-long-file-name.txt" {
    arr.push(b)
  }
  arr.push(b'\x00')
  for b in b"a header comment" {
    arr.push(b)
  }
  arr.push(b'\x00')
  // FHCRC: two bytes (skipped, not verified).
  arr.push(b'\x00')
  arr.push(b'\x00')
  // DEFLATE body + trailer, reused from the canonical stream.
  for i in 10..<gz.length() {
    arr.push(gz[i])
  }
  let full = Bytes::from_array(arr)
  let dec = @gzip.Decoder::new()
  let obuf = FixedArray::make(11, b'\x00')
  let out = Buffer()
  let n = full.length()
  let mut fed = 0
  for ;; {
    let next = if fed + 1 < n { fed + 1 } else { n }
    let (_st, c, p) = dec.step(full[fed:next], obuf.mut_view(), end=next == n)
    for i in 0..<p {
      out.write_byte(obuf[i])
    }
    fed = fed + c
    if dec.is_finished() {
      break
    }
  }
  assert_eq(out.to_bytes(), payload)
  // The one-shot path skips the same fields.
  assert_eq(@gzip.gunzip(full), payload)
}

///|
/// A flipped ISIZE byte must be caught by the trailer verification.
test "streaming gzip Decoder rejects a corrupted trailer" {
  let gz = @gzip.gzip_compress(b"corrupt me please, corrupt me please")
  let arr : Array[Byte] = []
  for b in gz {
    arr.push(b)
  }
  let last = arr.length() - 1
  arr[last] = (arr[last].to_int() ^ 0xFF).to_byte()
  let bad = Bytes::from_array(arr)
  let dec = @gzip.Decoder::new()
  let obuf = FixedArray::make(256, b'\x00')
  try {
    let n = bad.length()
    let mut fed = 0
    for ;; {
      let (_st, c, _p) = dec.step(bad[fed:n], obuf.mut_view(), end=true)
      fed = fed + c
      if dec.is_finished() {
        break
      }
    }
  } catch {
    GzipError(kind, _) => assert_true(kind == LengthMismatch)
  } noraise {
    _ => fail("expected corruption to be rejected")
  }
}

///|
/// RFC 1952 reserves the top three FLG bits and requires a decoder to reject a
/// member when any of them is non-zero.
test "gzip decoders reject reserved FLG bits" {
  let gz = @gzip.gzip_compress(b"reserved flag payload")
  let arr : Array[Byte] = []
  for b in gz {
    arr.push(b)
  }
  arr[3] = (arr[3].to_int() | 0x20).to_byte()
  let bad = Bytes::from_array(arr)
  try ignore(@gzip.gunzip(bad)) catch {
    GzipError(kind, _) => assert_true(kind == InvalidHeader)
  } noraise {
    _ => fail("one-shot decoding accepted a reserved FLG bit")
  }
  let dec = @gzip.Decoder::new()
  let out = FixedArray::make(64, b'\x00')
  try ignore(dec.step(bad[:], out.mut_view(), end=true)) catch {
    GzipError(kind, _) => assert_true(kind == InvalidHeader)
  } noraise {
    _ => fail("streaming decoding accepted a reserved FLG bit")
  }
}

///|
/// A magic-prefixed partial member after a valid member is not ignorable
/// trailing garbage. Both entry points must report the second member as
/// truncated, even though the first payload was already complete.
test "gzip decoders reject a truncated subsequent member" {
  let first = @gzip.gzip_compress(b"complete first member")
  let second = @gzip.gzip_compress(b"the second member is deliberately cut")
  let stream = concat_bytes([first, prefix_bytes(second, 17)])
  try ignore(@gzip.gunzip(stream)) catch {
    GzipError(kind, _) => assert_true(kind == Truncated)
  } noraise {
    _ => fail("one-shot decoding ignored a partial second member")
  }
  let dec = @gzip.Decoder::new()
  let out = FixedArray::make(4096, b'\x00')
  try ignore(dec.step(stream[:], out.mut_view(), end=true)) catch {
    GzipError(kind, _) => assert_true(kind == Truncated)
  } noraise {
    _ => fail("streaming decoding ignored a partial second member")
  }
}

///|
/// EOF is an error in every incomplete streaming state, including before the
/// first fixed header and while waiting for the trailer.
test "streaming gzip Decoder rejects truncated input at end" {
  let out = FixedArray::make(256, b'\x00')
  let empty_dec = @gzip.Decoder::new()
  try ignore(empty_dec.step(b""[:], out.mut_view(), end=true)) catch {
    GzipError(kind, _) => assert_true(kind == Truncated)
  } noraise {
    _ => fail("empty EOF was accepted as a complete gzip stream")
  }
  let gz = @gzip.gzip_compress(b"missing trailer byte")
  let truncated = prefix_bytes(gz, gz.length() - 1)
  let dec = @gzip.Decoder::new()
  try ignore(dec.step(truncated[:], out.mut_view(), end=true)) catch {
    GzipError(kind, _) => assert_true(kind == Truncated)
  } noraise {
    _ => fail("truncated trailer was accepted")
  }
}

///|
/// Malformed raw DEFLATE errors are part of the gzip abstraction boundary and
/// must not escape as `@flate.InflateError`.
test "gzip decoders wrap malformed DEFLATE as GzipError" {
  // BFINAL=1, BTYPE=3 is the reserved DEFLATE block type. Trailer bytes are
  // present so failure necessarily comes from the inner inflater.
  let bad : Bytes = [
    0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x07, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  ]
  try ignore(@gzip.gunzip(bad)) catch {
    GzipError(kind, _) => assert_true(kind == InvalidDeflate)
  } noraise {
    _ => fail("one-shot decoding accepted a reserved DEFLATE block")
  }
  let dec = @gzip.Decoder::new()
  let out = FixedArray::make(64, b'\x00')
  try ignore(dec.step(bad[:], out.mut_view(), end=true)) catch {
    GzipError(kind, _) => assert_true(kind == InvalidDeflate)
  } noraise {
    _ => fail("streaming decoding accepted a reserved DEFLATE block")
  }
}

///|
/// Once a streaming decoder reports corruption, later calls must not resume a
/// partially-mutated inflater or accept bytes into that failed stream.
test "streaming gzip Decoder latches its first error" {
  let malformed : Bytes = [
    0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x07, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  ]
  let decoder = @gzip.Decoder::new()
  let output = FixedArray::make(8, b'\xA5')
  let mut first_kind : @gzip.GzipErrorKind = InvalidHeader
  let mut first_error = ""
  try ignore(decoder.step(malformed[:], output.mut_view(), end=true)) catch {
    GzipError(kind, message) => {
      first_kind = kind
      first_error = message
    }
  } noraise {
    _ => fail("expected malformed gzip input to fail")
  }
  let mut repeated_kind : @gzip.GzipErrorKind = InvalidHeader
  let mut repeated_error = ""
  try ignore(decoder.step(b"late input"[:], output.mut_view())) catch {
    GzipError(kind, message) => {
      repeated_kind = kind
      repeated_error = message
    }
  } noraise {
    _ => fail("a failed gzip decoder resumed")
  }
  assert_true(first_kind == InvalidDeflate)
  assert_true(repeated_kind == first_kind)
  assert_eq(repeated_error, first_error)
  for byte in output {
    assert_eq(byte, b'\xA5')
  }
  assert_false(decoder.is_finished())
}

///|
/// The final-input signal survives output backpressure, and terminal calls do
/// not claim to consume bytes that cannot belong to the completed stream.
test "streaming gzip Decoder latches end across one-byte output" {
  let payload = b"end latch with one-byte output and a long repeated repeated repeated tail"
  let gz = @gzip.gzip_compress(payload)
  let dec = @gzip.Decoder::new()
  let obuf = FixedArray::make(1, b'\x00')
  let plain = Buffer()
  let mut first = true
  let mut finished = false
  for _i in 0..<4096 {
    let view = if first { gz[:] } else { b""[:] }
    let (st, c, p) = dec.step(view, obuf.mut_view(), end=first)
    assert_eq(c, if first { gz.length() } else { 0 })
    assert_true(p <= 1)
    if p == 1 {
      plain.write_byte(obuf[0])
    }
    first = false
    if st is Done {
      finished = true
      break
    }
  }
  assert_true(finished)
  assert_eq(plain.to_bytes(), payload)
  let (st, c, p) = dec.step(b"ignored"[:], obuf.mut_view())
  assert_true(st is Done)
  assert_eq(c, 0)
  assert_eq(p, 0)
}

///|
/// Feed and drain one byte at a time through long back-reference copies. This
/// is the minimum-buffer suspend/resume contract used by async adapters.
test "streaming gzip Decoder resumes with one-byte input and output" {
  let unit = b"one-byte streaming contract; "
  let bytes : Array[Byte] = []
  for _r in 0..<80 {
    for b in unit {
      bytes.push(b)
    }
  }
  let payload = Bytes::from_array(bytes)
  let gz = @gzip.gzip_compress(payload)
  let dec = @gzip.Decoder::new()
  let obuf = FixedArray::make(1, b'\x00')
  let plain = Buffer()
  let mut fed = 0
  let mut finished = false
  for _i in 0..<20000 {
    let next = if fed < gz.length() { fed + 1 } else { fed }
    let view = if fed < gz.length() { gz[fed:next] } else { b""[:] }
    let (_st, c, p) = dec.step(view, obuf.mut_view(), end=next == gz.length())
    fed = fed + c
    assert_true(p <= 1)
    if p == 1 {
      plain.write_byte(obuf[0])
    }
    if dec.is_finished() {
      finished = true
      break
    }
  }
  assert_true(finished)
  assert_eq(fed, gz.length())
  assert_eq(plain.to_bytes(), payload)
}

///|
/// Drain a sizeable stored stream one byte at a time. Besides minimum-buffer
/// correctness, this crosses the decoder's compaction threshold and guards the
/// amortized-linear pending-buffer path end to end.
test "streaming gzip Decoder drains a large stored member one byte at a time" {
  let bytes : Array[Byte] = []
  for i in 0..<8192 {
    bytes.push((i & 0xFF).to_byte())
  }
  let payload = Bytes::from_array(bytes)
  let gz = @gzip.gzip_compress(payload, level=0)
  let dec = @gzip.Decoder::new()
  let obuf = FixedArray::make(1, b'\x00')
  let plain = Buffer()
  let mut first = true
  let mut finished = false
  for _i in 0..<20000 {
    let view = if first { gz[:] } else { b""[:] }
    let (_st, c, p) = dec.step(view, obuf.mut_view(), end=first)
    assert_eq(c, if first { gz.length() } else { 0 })
    if p == 1 {
      plain.write_byte(obuf[0])
    }
    first = false
    if dec.is_finished() {
      finished = true
      break
    }
  }
  assert_true(finished)
  assert_eq(plain.to_bytes(), payload)
}

///|
/// A flush requested while the ten-byte wrapper header is still backpressured
/// must reach the inner deflater on a later call. Only the first call carries
/// `flush=true`; all output buffers are one byte.
test "streaming gzip Encoder latches flush across header backpressure" {
  let first = b"data that must be visible at the sync-flush boundary"
  let rest = b" and data after that boundary"
  let enc = @gzip.Encoder::new()
  let obuf = FixedArray::make(1, b'\x00')
  let encoded = Buffer()
  let mut first_call = true
  let mut flushed = false
  for _i in 0..<4096 {
    let view = if first_call { first[:] } else { b""[:] }
    let (st, c, p) = enc.step(view, obuf.mut_view(), flush=first_call)
    assert_eq(c, if first_call { first.length() } else { 0 })
    if p == 1 {
      encoded.write_byte(obuf[0])
    }
    first_call = false
    if st is NeedMoreInput {
      flushed = true
      break
    }
  }
  assert_true(flushed)

  // The non-final prefix must already be independently decodable through the
  // sync-flush point.
  let prefix = encoded.to_bytes()
  let dec = @gzip.Decoder::new()
  let plain = Buffer()
  let mut fed_prefix = false
  let mut reached_boundary = false
  for _i in 0..<4096 {
    let view = if fed_prefix { b""[:] } else { prefix[:] }
    let (st, _c, p) = dec.step(view, obuf.mut_view())
    fed_prefix = true
    if p == 1 {
      plain.write_byte(obuf[0])
    }
    if st is NeedMoreInput {
      reached_boundary = true
      break
    }
  }
  assert_true(reached_boundary)
  assert_eq(plain.to_bytes(), first)

  // Continue the same encoder, signal end once, and drain without repeating
  // either control flag.
  let mut sent_rest = false
  let mut encoder_done = false
  for _i in 0..<4096 {
    let view = if sent_rest { b""[:] } else { rest[:] }
    let (st, c, p) = enc.step(view, obuf.mut_view(), end=!sent_rest)
    assert_eq(c, if sent_rest { 0 } else { rest.length() })
    if p == 1 {
      encoded.write_byte(obuf[0])
    }
    sent_rest = true
    if st is Done {
      encoder_done = true
      break
    }
  }
  assert_true(encoder_done)
  assert_eq(@gzip.gunzip(encoded.to_bytes()), concat_bytes([first, rest]))
  let (st, c, p) = enc.step(b"ignored"[:], obuf.mut_view())
  assert_true(st is Done)
  assert_eq(c, 0)
  assert_eq(p, 0)
}

///|
/// A transport read may cross the final member trailer into the next protocol
/// frame. The gzip decoder must finish without discarding that read-ahead.
test "streaming gzip Decoder preserves input after the final member" {
  let source = b"gzip member followed by another protocol message"
  let next_frame = b"NEXT-FRAME"
  let encoded = @gzip.gzip_compress(source)
  let combined = Buffer()
  for byte in encoded {
    combined.write_byte(byte)
  }
  for byte in next_frame {
    combined.write_byte(byte)
  }
  let decoder = @gzip.Decoder::new()
  let output = FixedArray::make(1, b'\x00')
  let decoded = Buffer()
  let mut first = true
  for _ in 0..<4096 {
    let chunk = if first { combined.to_bytes()[:] } else { b""[:] }
    let (status, consumed, produced) = decoder.step(chunk, output.mut_view())
    assert_eq(consumed, if first { combined.length() } else { 0 })
    if produced == 1 {
      decoded.write_byte(output[0])
    }
    first = false
    if status is Done {
      break
    }
  }
  assert_true(decoder.is_finished())
  assert_eq(decoded.to_bytes(), source)
  assert_eq(decoder.unused_input(), next_frame)
  let (status, consumed, produced) = decoder.step(b"late"[:], output.mut_view())
  assert_true(status is Done)
  assert_eq(consumed, 0)
  assert_eq(produced, 0)
  assert_eq(decoder.unused_input(), next_frame)
}

///|
/// In a framed protocol the next frame may itself begin with gzip magic. The
/// explicit one-member mode makes the first trailer an unambiguous boundary.
test "streaming gzip Decoder can stop after one member" {
  let first_payload = b"first framed member"
  let second_member = @gzip.gzip_compress(b"belongs to the next frame")
  let first_member = @gzip.gzip_compress(first_payload)
  let combined = Buffer()
  for byte in first_member {
    combined.write_byte(byte)
  }
  for byte in second_member {
    combined.write_byte(byte)
  }
  let decoder = @gzip.Decoder::new(multistream=false)
  let output = FixedArray::make(1, b'\x00')
  let decoded = Buffer()
  let mut first = true
  for _ in 0..<4096 {
    let chunk = if first { combined.to_bytes()[:] } else { b""[:] }
    let (status, consumed, produced) = decoder.step(chunk, output.mut_view())
    assert_eq(consumed, if first { combined.length() } else { 0 })
    if produced == 1 {
      decoded.write_byte(output[0])
    }
    first = false
    if status is Done {
      break
    }
  }
  assert_true(decoder.is_finished())
  assert_eq(decoded.to_bytes(), first_payload)
  assert_eq(decoder.unused_input(), second_member)
}
