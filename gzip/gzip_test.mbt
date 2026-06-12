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
    @gzip.GzipError(_) => ()
    _ => fail("expected a GzipError for the corrupted trailer")
  } noraise {
    _ => fail("expected corruption to be rejected")
  }
}
