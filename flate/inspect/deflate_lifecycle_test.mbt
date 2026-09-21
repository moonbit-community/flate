///|
/// Every level 0-9 produces a valid stream; level 0 is stored-only (no
/// compression), levels >= 1 compress the repetitive payload well.
test "compression levels round-trip" {
  let unit = b"level test payload, the quick brown fox jumps over. "
  let arr : Array[Byte] = []
  for _r in 0..<600 {
    for b in unit {
      arr.push(b)
    }
  }
  let src = Bytes::from_array(arr)
  for level in 0..<10 {
    let out = @flate.deflate_all(src, level~)
    assert_eq(@flate.inflate_all(out), src)
    if level == 0 {
      assert_true(out.length() >= src.length()) // stored only, framing added
    } else {
      assert_true(out.length() < src.length() / 10) // repetitive data shrinks
    }
  }
}

///|
/// `reset()` reuses one engine across independent streams: the Deflater's
/// output matches a fresh compressor's, and the Inflater decodes a second
/// stream cleanly after the first.
test "reset reuses engines across streams" {
  let s1 = b"first stream payload, first stream payload"
  let s2 = b"second stream: completely different bytes!!"
  let d = @flate.Deflater()
  assert_eq(d.last_consumed(), 0)
  assert_eq(d.last_produced(), 0)
  let obuf = FixedArray::make(4096, b'\x00')
  let st1 = d.step(s1[:], obuf.mut_view(), action=Finish)
  assert_true(st1 is Done)
  d.reset()
  assert_eq(d.last_consumed(), 0)
  assert_eq(d.last_produced(), 0)
  let st2 = d.step(s2[:], obuf.mut_view(), action=Finish)
  let p2 = d.last_produced()
  assert_true(st2 is Done)
  let reused : Array[Byte] = []
  for i in 0..<p2 {
    reused.push(obuf[i])
  }
  assert_eq(Bytes::from_array(reused), @flate.deflate_all(s2))
  let inf = @flate.Inflater()
  assert_eq(inf.last_consumed(), 0)
  assert_eq(inf.last_produced(), 0)
  let dbuf = FixedArray::make(4096, b'\x00')
  let ist1 = inf.step(@flate.deflate_all(s1)[:], dbuf.mut_view())
  let ip1 = inf.last_produced()
  assert_true(ist1 is Done)
  let got1 : Array[Byte] = []
  for i in 0..<ip1 {
    got1.push(dbuf[i])
  }
  assert_eq(Bytes::from_array(got1), s1)
  let sentinel = FixedArray::make(4, b'\xA5')
  let done_status = inf.step(@flate.deflate_all(s2)[:], sentinel.mut_view())
  assert_true(done_status is Done)
  assert_eq(inf.last_consumed(), 0)
  assert_eq(inf.last_produced(), 0)
  for byte in sentinel {
    assert_eq(byte, b'\xA5')
  }
  inf.reset()
  assert_eq(inf.last_consumed(), 0)
  assert_eq(inf.last_produced(), 0)
  let ist2 = inf.step(@flate.deflate_all(s2)[:], dbuf.mut_view())
  let ip2 = inf.last_produced()
  assert_true(ist2 is Done)
  let got2 : Array[Byte] = []
  for i in 0..<ip2 {
    got2.push(dbuf[i])
  }
  assert_eq(Bytes::from_array(got2), s2)
}

///|
/// Preset dictionary on the raw engine: back-references reach into the
/// preloaded window, the stream is smaller than without the dictionary, and
/// decoding without it fails (distances reach before the stream start).
test "preset dictionary: raw deflate round-trip" {
  let dict = b"the quick brown fox jumps over the lazy dog"
  let msg = b"the quick brown fox jumps over the lazy dog, again and again!"
  let d = @flate.Deflater(dictionary=dict[:])
  let obuf = FixedArray::make(4096, b'\x00')
  let st = d.step(msg[:], obuf.mut_view(), action=Finish)
  let p = d.last_produced()
  assert_true(st is Done)
  let comp : Array[Byte] = []
  for i in 0..<p {
    comp.push(obuf[i])
  }
  let compressed = Bytes::from_array(comp)
  // The dictionary must actually pay: smaller than dictionary-less output.
  assert_true(compressed.length() < @flate.deflate_all(msg).length())
  // With the dictionary: decodes to the message.
  let inf = @flate.Inflater(dictionary=dict[:])
  let dbuf = FixedArray::make(4096, b'\x00')
  let ist = inf.step(compressed[:], dbuf.mut_view())
  let ip = inf.last_produced()
  assert_true(ist is Done)
  let got : Array[Byte] = []
  for i in 0..<ip {
    got.push(dbuf[i])
  }
  assert_eq(Bytes::from_array(got), msg)
  // Without the dictionary: a back-reference reaches before the stream start.
  let inf2 = @flate.Inflater()
  try {
    let _ = inf2.step(compressed[:], dbuf.mut_view())
  } catch {
    InflateError(_, _) => ()
  } noraise {
    _ => fail("expected the dictionary-less decode to fail")
  }
}
