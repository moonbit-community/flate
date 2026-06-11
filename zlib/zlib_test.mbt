///|
let data : Bytes = b"hello, hello, hello world! the quick brown fox."

///|
/// zlib stream produced by python's zlib (wbits=15).
let py_zlib : Bytes = [
  0x78, 0x9C, 0xCB, 0x48, 0xCD, 0xC9, 0xC9, 0xD7, 0x51, 0xC8, 0x40, 0xA2, 0x14, 0xCA,
  0xF3, 0x8B, 0x72, 0x52, 0x14, 0x15, 0x4A, 0x32, 0x52, 0x15, 0x0A, 0x4B, 0x33, 0x93,
  0xB3, 0x15, 0x92, 0x8A, 0xF2, 0xCB, 0xF3, 0x14, 0xD2, 0xF2, 0x2B, 0xF4, 0x00, 0x91,
  0x66, 0x10, 0xBF,
]

///|
test "zlib_decompress decodes a python-produced zlib stream" {
  assert_eq(@zlib.zlib_decompress(py_zlib), data)
}

///|
test "zlib round-trip" {
  assert_eq(@zlib.zlib_decompress(@zlib.zlib_compress(data)), data)
}

///|
test "zlib round-trip: empty" {
  assert_eq(@zlib.zlib_decompress(@zlib.zlib_compress(b"")), b"")
}

///|
/// Optimal (zopfli-style) zlib round-trips and is no larger than level 6.
test "zlib_compress_optimal round-trips and is no larger than level 6" {
  let payload = b"the quick brown fox jumps over the lazy dog. the quick brown fox jumps over the lazy dog. pack my box with five dozen liquor jugs."
  let opt = @zlib.zlib_compress_optimal(payload)
  assert_eq(@zlib.zlib_decompress(opt), payload)
  assert_true(opt.length() <= @zlib.zlib_compress(payload, level=6).length())
}

///|
test "zlib_compress_optimal: empty" {
  assert_eq(@zlib.zlib_decompress(@zlib.zlib_compress_optimal(b"")), b"")
}

///|
/// Stream ~60 KB through the suspendable `zlib.Encoder` in 500-byte input
/// chunks, draining a 50-byte output buffer — exercising multi-block deflate,
/// header/trailer suspension, and incremental Adler-32 — then verify with the
/// one-shot `zlib_decompress`.
test "streaming zlib Encoder round-trips through zlib_decompress" {
  let unit = b"streaming zlib test payload, the quick brown fox. "
  let arr : Array[Byte] = []
  for _r in 0..<1200 {
    for i in 0..<unit.length() {
      arr.push(unit[i])
    }
  }
  let src = Bytes::from_array(arr)
  let enc = @zlib.Encoder::new()
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
  assert_eq(@zlib.zlib_decompress(out.to_bytes()), src)
}

///|
test "streaming zlib Encoder: empty input" {
  let enc = @zlib.Encoder::new()
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
  assert_eq(@zlib.zlib_decompress(out.to_bytes()), b"")
}

///|
/// Decode the python-produced zlib vector through the streaming `zlib.Decoder`,
/// 3 input bytes at a time into a 7-byte output buffer.
test "streaming zlib Decoder decodes a python zlib stream in tiny chunks" {
  let dec = @zlib.Decoder::new()
  let obuf = FixedArray::make(7, b'\x00')
  let out = Buffer()
  let n = py_zlib.length()
  let mut fed = 0
  for ;; {
    let next = if fed + 3 < n { fed + 3 } else { n }
    let (_st, c, p) = dec.step(py_zlib[fed:next], obuf.mut_view())
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
/// Stream a ~50 KB zlib blob through the streaming `zlib.Decoder` in 64-byte
/// input chunks, draining a 13-byte output buffer.
test "streaming zlib Decoder round-trips a large stream" {
  let unit = b"streaming zlib decode payload, the quick brown fox. "
  let arr : Array[Byte] = []
  for _r in 0..<1000 {
    for i in 0..<unit.length() {
      arr.push(unit[i])
    }
  }
  let src = Bytes::from_array(arr)
  let z = @zlib.zlib_compress(src)
  let dec = @zlib.Decoder::new()
  let obuf = FixedArray::make(13, b'\x00')
  let out = Buffer()
  let n = z.length()
  let mut fed = 0
  for ;; {
    let next = if fed + 64 < n { fed + 64 } else { n }
    let (_st, c, p) = dec.step(z[fed:next], obuf.mut_view())
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
test "streaming zlib Decoder: empty" {
  let z = @zlib.zlib_compress(b"")
  let dec = @zlib.Decoder::new()
  let obuf = FixedArray::make(8, b'\x00')
  let out = Buffer()
  let n = z.length()
  let mut fed = 0
  for ;; {
    let next = if fed + 1 < n { fed + 1 } else { n }
    let (_st, c, p) = dec.step(z[fed:next], obuf.mut_view())
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
/// Preset dictionary (RFC 1950 FDICT): round-trip through the streaming
/// Encoder/Decoder; a missing or wrong dictionary is rejected via DICTID.
test "zlib preset dictionary round-trip" {
  let dict = b"common preamble shared by both sides of the protocol"
  let msg = b"common preamble shared by both sides of the protocol -- payload"
  let enc = @zlib.Encoder::new(dictionary=dict)
  let obuf = FixedArray::make(4096, b'\x00')
  let out = Buffer()
  let mut sent = false
  for ;; {
    let chunk = if sent { b""[:] } else { msg[:] }
    let (st, _c, p) = enc.step(chunk, obuf.mut_view(), end=true)
    sent = true
    for i in 0..<p {
      out.write_byte(obuf[i])
    }
    if st is @flate.Done {
      break
    }
  }
  let z = out.to_bytes()
  // With the right dictionary: decodes and verifies the trailer.
  let dec = @zlib.Decoder::new(dictionary=dict)
  let dbuf = FixedArray::make(4096, b'\x00')
  let got = Buffer()
  let n = z.length()
  let mut fed = 0
  for ;; {
    let (_st, c, p) = dec.step(z[fed:n], dbuf.mut_view())
    fed = fed + c
    for i in 0..<p {
      got.write_byte(dbuf[i])
    }
    if dec.is_finished() {
      break
    }
  }
  assert_eq(got.to_bytes(), msg)
  // Without a dictionary: rejected at the header.
  let dec2 = @zlib.Decoder::new()
  try {
    let _ = dec2.step(z[:], dbuf.mut_view())
  } catch {
    @zlib.ZlibError(_) => ()
    _ => fail("expected a ZlibError")
  } noraise {
    _ => fail("expected the missing dictionary to be rejected")
  }
  // With the wrong dictionary: DICTID mismatch.
  let dec3 = @zlib.Decoder::new(dictionary=b"a completely different dictionary")
  try {
    let _ = dec3.step(z[:], dbuf.mut_view())
  } catch {
    @zlib.ZlibError(_) => ()
    _ => fail("expected a ZlibError")
  } noraise {
    _ => fail("expected the wrong dictionary to be rejected")
  }
}
