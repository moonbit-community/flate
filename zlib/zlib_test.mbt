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
    let action : @flate.DeflateAction = if last { Finish } else { Continue }
    let _status = enc.step(chunk, obuf.mut_view(), action~)
    let c = enc.last_consumed()
    let p = enc.last_produced()
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
    let _status = enc.step(b""[:], obuf.mut_view(), action=Finish)
    let p = enc.last_produced()
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
    let _status = dec.step(py_zlib[fed:next], obuf.mut_view())
    let c = dec.last_consumed()
    let p = dec.last_produced()
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
    let _status = dec.step(z[fed:next], obuf.mut_view())
    let c = dec.last_consumed()
    let p = dec.last_produced()
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
    let _status = dec.step(z[fed:next], obuf.mut_view())
    let c = dec.last_consumed()
    let p = dec.last_produced()
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
    let st = enc.step(chunk, obuf.mut_view(), action=Finish)
    let p = enc.last_produced()
    sent = true
    for i in 0..<p {
      out.write_byte(obuf[i])
    }
    if st is Done {
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
    let _status = dec.step(z[fed:n], dbuf.mut_view())
    let c = dec.last_consumed()
    let p = dec.last_produced()
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
    ZlibError(kind, _) => assert_true(kind == DictionaryRequired)
  } noraise {
    _ => fail("expected the missing dictionary to be rejected")
  }
  // With the wrong dictionary: DICTID mismatch.
  let dec3 = @zlib.Decoder::new(dictionary=b"a completely different dictionary")
  try {
    let _ = dec3.step(z[:], dbuf.mut_view())
  } catch {
    ZlibError(kind, _) => assert_true(kind == DictionaryMismatch)
  } noraise {
    _ => fail("expected the wrong dictionary to be rejected")
  }
}

///|
test "zlib rejects CINFO values above seven" {
  let valid = @zlib.zlib_compress(b"invalid window header")
  let bytes = valid.to_array()
  // 0x881c has CM=8, CINFO=8, and a valid FCHECK, but RFC 1950 permits
  // CINFO only through 7 for DEFLATE.
  bytes[0] = b'\x88'
  bytes[1] = b'\x1C'
  let invalid = Bytes::from_array(bytes)
  try @zlib.zlib_decompress(invalid) catch {
    ZlibError(kind, _) => assert_true(kind == InvalidHeader)
  } noraise {
    _ => fail("one-shot decoder accepted CINFO=8")
  }
  let dec = @zlib.Decoder::new()
  let output = FixedArray::make(64, b'\x00')
  try dec.step(invalid[:], output.mut_view()) catch {
    ZlibError(kind, _) => assert_true(kind == InvalidHeader)
  } noraise {
    _ => fail("streaming decoder accepted CINFO=8")
  }
}

///|
test "zlib_decompress rejects bytes before the Adler trailer" {
  let valid = @zlib.zlib_compress(b"exact DEFLATE extent")
  let malformed : Array[Byte] = []
  for i in 0..<(valid.length() - 4) {
    malformed.push(valid[i])
  }
  malformed.push(b'\x00')
  for i in (valid.length() - 4)..<valid.length() {
    malformed.push(valid[i])
  }
  try @zlib.zlib_decompress(Bytes::from_array(malformed)) catch {
    ZlibError(kind, _) => assert_true(kind == TrailingData)
  } noraise {
    _ => fail("accepted a byte between DEFLATE and Adler-32")
  }
}

///|
test "malformed DEFLATE errors are wrapped as ZlibError" {
  // BFINAL=1, BTYPE=3 is the reserved DEFLATE block type. The remaining four
  // bytes are the Adler-32 of an empty output and are never reached.
  let malformed : Bytes = [0x78, 0x01, 0x07, 0x00, 0x00, 0x00, 0x01]
  try @zlib.zlib_decompress(malformed) catch {
    ZlibError(kind, _) => assert_true(kind == InvalidDeflate)
  } noraise {
    _ => fail("one-shot decoder accepted reserved DEFLATE block type")
  }
  let dec = @zlib.Decoder::new()
  let output = FixedArray::make(1, b'\x00')
  try dec.step(malformed[:], output.mut_view()) catch {
    ZlibError(kind, _) => assert_true(kind == InvalidDeflate)
  } noraise {
    _ => fail("streaming decoder accepted reserved DEFLATE block type")
  }
}

///|
/// Once corruption is reported, the decoder is a stable failed terminal state:
/// later input is not accepted and the original diagnostic is rethrown.
test "streaming zlib Decoder latches its first error" {
  let malformed : Bytes = [0x78, 0x01, 0x07, 0x00, 0x00, 0x00, 0x01]
  let decoder = @zlib.Decoder::new()
  let output = FixedArray::make(8, b'\xA5')
  let mut first_kind : @zlib.ZlibErrorKind = InvalidHeader
  let mut first_error = ""
  try ignore(decoder.step(malformed[:], output.mut_view(), end=true)) catch {
    ZlibError(kind, message) => {
      first_kind = kind
      first_error = message
    }
  } noraise {
    _ => fail("expected malformed zlib input to fail")
  }
  assert_eq(decoder.last_consumed(), 0)
  assert_eq(decoder.last_produced(), 0)
  let mut repeated_kind : @zlib.ZlibErrorKind = InvalidHeader
  let mut repeated_error = ""
  try ignore(decoder.step(b"late input"[:], output.mut_view())) catch {
    ZlibError(kind, message) => {
      repeated_kind = kind
      repeated_error = message
    }
  } noraise {
    _ => fail("a failed zlib decoder resumed")
  }
  assert_true(first_kind == InvalidDeflate)
  assert_true(repeated_kind == first_kind)
  assert_eq(repeated_error, first_error)
  assert_eq(decoder.last_consumed(), 0)
  assert_eq(decoder.last_produced(), 0)
  for byte in output {
    assert_eq(byte, b'\xA5')
  }
  assert_false(decoder.is_finished())
}

///|
/// Physical EOF is distinct from temporary input starvation in every zlib
/// wrapper state, including the optional DICTID and checksum trailer.
test "streaming zlib Decoder reports truncation at end" {
  let output = FixedArray::make(256, b'\x00')
  let header = @zlib.Decoder::new()
  try ignore(header.step(b"\x78"[:], output.mut_view(), end=true)) catch {
    ZlibError(kind, message) => {
      assert_true(kind == Truncated)
      assert_eq(message, "zlib: truncated header")
    }
  } noraise {
    _ => fail("truncated zlib header was accepted")
  }

  let dictid = @zlib.Decoder::new()
  try
    ignore(dictid.step(b"\x78\x20\x00\x00"[:], output.mut_view(), end=true))
  catch {
    ZlibError(kind, message) => {
      assert_true(kind == Truncated)
      assert_eq(message, "zlib: truncated dictionary id")
    }
  } noraise {
    _ => fail("truncated zlib DICTID was accepted")
  }

  let body = @zlib.Decoder::new()
  try ignore(body.step(b"\x78\x01\x03"[:], output.mut_view(), end=true)) catch {
    ZlibError(kind, message) => {
      assert_true(kind == Truncated)
      assert_eq(message, "zlib: truncated DEFLATE stream")
    }
  } noraise {
    _ => fail("truncated zlib body was accepted")
  }

  let encoded = @zlib.zlib_compress(b"truncated checksum trailer")
  let trailer = @zlib.Decoder::new()
  try
    ignore(
      trailer.step(encoded[:encoded.length() - 1], output.mut_view(), end=true),
    )
  catch {
    ZlibError(kind, message) => {
      assert_true(kind == Truncated)
      assert_eq(message, "zlib: truncated trailer")
    }
  } noraise {
    _ => fail("truncated zlib trailer was accepted")
  }
}

///|
/// The EOF request survives output suspension and prevents later bytes from
/// being appended to the already-finalized input sequence.
test "streaming zlib Decoder latches end across output backpressure" {
  let source = b"sticky zlib end with one-byte output and repeated repeated data"
  let encoded = @zlib.zlib_compress(source)
  let decoder = @zlib.Decoder::new()
  let no_output = FixedArray::make(0, b'\x00')
  let initial_status = decoder.step(encoded[:], no_output.mut_view(), end=true)
  let initial_consumed = decoder.last_consumed()
  let initial_produced = decoder.last_produced()
  assert_true(initial_status is NeedMoreOutput)
  assert_eq(initial_consumed, encoded.length())
  assert_eq(initial_produced, 0)
  let output = FixedArray::make(1, b'\x00')
  let decoded = Buffer()
  let mut first_resume = true
  for _ in 0..<4096 {
    let input = if first_resume { b"late input"[:] } else { b""[:] }
    let status = decoder.step(input, output.mut_view())
    let consumed = decoder.last_consumed()
    let produced = decoder.last_produced()
    assert_eq(consumed, 0)
    if produced == 1 {
      decoded.write_byte(output[0])
    }
    first_resume = false
    if status is Done {
      break
    }
  }
  assert_true(decoder.is_finished())
  assert_eq(decoded.to_bytes(), source)
  assert_eq(decoder.unused_input(), b"")
}

///|
test "streaming zlib Encoder latches flush across header backpressure" {
  let first = b"flush me before the two-byte header has drained"
  let second = b" and then continue the same stream"
  let enc = @zlib.Encoder::new()
  let output = FixedArray::make(1, b'\x00')
  let compressed = Buffer()
  let initial_status = enc.step(first[:], output.mut_view(), action=SyncFlush)
  let initial_consumed = enc.last_consumed()
  let initial_produced = enc.last_produced()
  assert_true(initial_status is NeedMoreOutput)
  assert_eq(initial_consumed, first.length())
  assert_eq(initial_produced, 1)
  compressed.write_byte(output[0])
  let mut flushed = false
  for _ in 0..<4096 {
    let status = enc.step(b""[:], output.mut_view())
    let consumed = enc.last_consumed()
    let produced = enc.last_produced()
    assert_eq(consumed, 0)
    assert_true(produced >= 0 && produced <= 1)
    if produced == 1 {
      compressed.write_byte(output[0])
    }
    if status is NeedMoreInput {
      flushed = true
      break
    }
  }
  assert_true(flushed)
  // More than just CMF/FLG proves that the latched request reached Deflater.
  assert_true(compressed.length() > 2)
  let mut sent_second = false
  for _ in 0..<4096 {
    let chunk = if sent_second { b""[:] } else { second[:] }
    let status = enc.step(chunk, output.mut_view(), action=Finish)
    let consumed = enc.last_consumed()
    let produced = enc.last_produced()
    assert_eq(consumed, chunk.length())
    assert_true(produced >= 0 && produced <= 1)
    if produced == 1 {
      compressed.write_byte(output[0])
    }
    sent_second = true
    if status is Done {
      break
    }
  }
  assert_true(enc.is_finished())
  let expected = Buffer()
  for byte in first {
    expected.write_byte(byte)
  }
  for byte in second {
    expected.write_byte(byte)
  }
  assert_eq(@zlib.zlib_decompress(compressed.to_bytes()), expected.to_bytes())
  let terminal_status = enc.step(
    b"not part of the stream"[:],
    output.mut_view(),
  )
  let terminal_consumed = enc.last_consumed()
  let terminal_produced = enc.last_produced()
  assert_true(terminal_status is Done)
  assert_eq(terminal_consumed, 0)
  assert_eq(terminal_produced, 0)
}

///|
test "streaming zlib Encoder leaves input unconsumed after end is latched" {
  let source = b"the final accepted input"
  let enc = @zlib.Encoder::new()
  let no_output = FixedArray::make(0, b'\x00')
  let initial_status = enc.step(source[:], no_output.mut_view(), action=Finish)
  let initial_consumed = enc.last_consumed()
  let initial_produced = enc.last_produced()
  assert_true(initial_status is NeedMoreOutput)
  assert_eq(initial_consumed, source.length())
  assert_eq(initial_produced, 0)
  let output = FixedArray::make(1, b'\x00')
  let compressed = Buffer()
  let late_status = enc.step(b"late input"[:], output.mut_view())
  let late_consumed = enc.last_consumed()
  let late_produced = enc.last_produced()
  assert_true(late_status is NeedMoreOutput)
  assert_eq(late_consumed, 0)
  assert_eq(late_produced, 1)
  compressed.write_byte(output[0])
  for _ in 0..<4096 {
    let status = enc.step(b""[:], output.mut_view())
    let consumed = enc.last_consumed()
    let produced = enc.last_produced()
    assert_eq(consumed, 0)
    if produced == 1 {
      compressed.write_byte(output[0])
    }
    if status is Done {
      break
    }
  }
  assert_true(enc.is_finished())
  assert_eq(@zlib.zlib_decompress(compressed.to_bytes()), source)
}

///|
test "streaming zlib Decoder drains large pending input one byte at a time" {
  let source = Bytes::from_array(Array::make(8192, b'\xA5'))
  let compressed = @zlib.zlib_compress(source, level=0)
  let dec = @zlib.Decoder::new()
  let output = FixedArray::make(1, b'\x00')
  let decoded = Buffer()
  let mut first_call = true
  for _ in 0..<(source.length() + 64) {
    let chunk = if first_call { compressed[:] } else { b""[:] }
    let status = dec.step(chunk, output.mut_view())
    let consumed = dec.last_consumed()
    let produced = dec.last_produced()
    assert_eq(consumed, chunk.length())
    assert_true(produced >= 0 && produced <= 1)
    if produced == 1 {
      decoded.write_byte(output[0])
    }
    first_call = false
    if status is Done {
      break
    }
  }
  assert_true(dec.is_finished())
  assert_eq(decoded.to_bytes(), source)
  let terminal_status = dec.step(
    b"not part of the stream"[:],
    output.mut_view(),
  )
  let terminal_consumed = dec.last_consumed()
  let terminal_produced = dec.last_produced()
  assert_true(terminal_status is Done)
  assert_eq(terminal_consumed, 0)
  assert_eq(terminal_produced, 0)
}

///|
test "streaming zlib Decoder resumes with one-byte input and output" {
  let source = Bytes::from_array(Array::make(700, b'\x5A'))
  let compressed = @zlib.zlib_compress(source)
  let dec = @zlib.Decoder::new()
  let output = FixedArray::make(1, b'\x00')
  let decoded = Buffer()
  let mut fed = 0
  for _ in 0..<(source.length() + compressed.length() + 64) {
    let next = if fed < compressed.length() { fed + 1 } else { fed }
    let chunk = compressed[fed:next]
    let status = dec.step(chunk, output.mut_view())
    let consumed = dec.last_consumed()
    let produced = dec.last_produced()
    assert_eq(consumed, chunk.length())
    assert_true(produced >= 0 && produced <= 1)
    fed = fed + consumed
    if produced == 1 {
      decoded.write_byte(output[0])
    }
    if status is Done {
      break
    }
    if status is NeedMoreInput && fed == compressed.length() {
      fail("decoder requested input after the complete stream was supplied")
    }
  }
  assert_true(dec.is_finished())
  assert_eq(fed, compressed.length())
  assert_eq(decoded.to_bytes(), source)
}

///|
/// A transport read may cross the zlib trailer into the next protocol frame.
/// The decoder accepts that read-ahead but must make it recoverable after Done.
test "streaming zlib Decoder preserves input after the trailer" {
  let source = b"zlib frame followed by another protocol message"
  let next_frame = b"NEXT-FRAME"
  let encoded = @zlib.zlib_compress(source)
  let combined = Buffer()
  for byte in encoded {
    combined.write_byte(byte)
  }
  for byte in next_frame {
    combined.write_byte(byte)
  }
  let decoder = @zlib.Decoder::new()
  let output = FixedArray::make(1, b'\x00')
  let decoded = Buffer()
  let mut first = true
  for _ in 0..<4096 {
    let chunk = if first { combined.to_bytes()[:] } else { b""[:] }
    let status = decoder.step(chunk, output.mut_view())
    let consumed = decoder.last_consumed()
    let produced = decoder.last_produced()
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
  let status = decoder.step(b"late"[:], output.mut_view())
  let consumed = decoder.last_consumed()
  let produced = decoder.last_produced()
  assert_true(status is Done)
  assert_eq(consumed, 0)
  assert_eq(produced, 0)
  assert_eq(decoder.unused_input(), next_frame)
}
