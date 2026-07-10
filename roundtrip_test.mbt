///|
/// deflate_all -> inflate_all must reproduce the input exactly.
test "round-trip: empty" {
  assert_eq(@flate.inflate_all(@flate.deflate_all(b"")), b"")
}

///|
test "round-trip: short literal" {
  let s = b"hello, world"
  assert_eq(@flate.inflate_all(@flate.deflate_all(s)), s)
}

///|
test "round-trip: repetitive data actually compresses" {
  let s = b"abcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabc"
  let comp = @flate.deflate_all(s)
  assert_true(comp.length() < s.length())
  assert_eq(@flate.inflate_all(comp), s)
}

///|
test "round-trip: every byte value" {
  let arr = Array::make(256, b'\x00')
  for i in 0..<256 {
    arr[i] = i.to_byte()
  }
  let s = Bytes::from_array(arr)
  assert_eq(@flate.inflate_all(@flate.deflate_all(s)), s)
}

///|
test "round-trip: longer text" {
  let s = b"The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog."
  assert_eq(@flate.inflate_all(@flate.deflate_all(s)), s)
}

///|
/// A larger varied input the encoder compresses with a dynamic-Huffman block.
test "round-trip: large input via dynamic Huffman" {
  let s = b"the quick brown fox jumps over the lazy dog. pack my box with five dozen liquor jugs. how razorback-jumping frogs can level six piqued gymnasts! the quick brown fox jumps over the lazy dog again and again and again."
  let c = @flate.deflate_all(s)
  assert_true(c.length() < s.length())
  assert_eq(@flate.inflate_all(c), s)
}

///|
/// Stream compression through Deflater::step: feed input in 10-byte chunks,
/// drain a tiny 16-byte output buffer (forces NeedMoreOutput), then round-trip.
test "Deflater::step streams compression then round-trips" {
  let data = b"the quick brown fox jumps over the lazy dog. the quick brown fox jumps over the lazy dog. pack my box."
  let def = @flate.Deflater::new()
  let obuf = FixedArray::make(16, b'\x00')
  let comp = Buffer()
  let n = data.length()
  let mut pos = 0
  let mut sent_end = false
  for ;; {
    let last = sent_end || pos + 10 >= n
    let endi = if pos + 10 < n { pos + 10 } else { n }
    let chunk = if sent_end { data[n:n] } else { data[pos:endi] }
    let action : @flate.DeflateAction = if last { Finish } else { Continue }
    let st = def.step(chunk, obuf.mut_view(), action~)
    let c = def.last_consumed()
    let p = def.last_produced()
    for i in 0..<p {
      comp.write_byte(obuf[i])
    }
    pos = pos + c
    if last {
      sent_end = true
    }
    if st is Done {
      break
    }
  }
  assert_true(comp.to_bytes().length() < data.length())
  assert_eq(@flate.inflate_all(comp.to_bytes()), data)
}

///|
/// Stream ~45 KB through `Deflater::step` so it emits several non-final blocks
/// (block size is 16 KB), feeding 700-byte input chunks and draining a 64-byte
/// output buffer. This exercises multi-block emission, cross-block
/// back-references (the repeated phrase recurs past every 16 KB boundary), and
/// heavy NeedMoreOutput suspension — then round-trips.
test "Deflater emits multiple blocks for a large input and round-trips" {
  let unit = b"the quick brown fox jumps over the lazy dog. "
  let arr : Array[Byte] = []
  for _r in 0..<1000 {
    for i in 0..<unit.length() {
      arr.push(unit[i])
    }
  }
  let data = Bytes::from_array(arr) // 45000 bytes
  let def = @flate.Deflater::new()
  let obuf = FixedArray::make(64, b'\x00')
  let comp = Buffer()
  let n = data.length()
  let mut pos = 0
  let mut sent_end = false
  for ;; {
    let last = sent_end || pos + 700 >= n
    let endi = if pos + 700 < n { pos + 700 } else { n }
    let chunk = if sent_end { data[n:n] } else { data[pos:endi] }
    let action : @flate.DeflateAction = if last { Finish } else { Continue }
    let st = def.step(chunk, obuf.mut_view(), action~)
    let c = def.last_consumed()
    let p = def.last_produced()
    for i in 0..<p {
      comp.write_byte(obuf[i])
    }
    pos = pos + c
    if last {
      sent_end = true
    }
    if st is Done {
      break
    }
  }
  let compressed = comp.to_bytes()
  // Highly repetitive: should compress to a small fraction of the original.
  assert_true(compressed.length() < data.length() / 4)
  assert_eq(@flate.inflate_all(compressed), data)
}

///|
/// A final-input request is accepted only after older output is drained. The
/// caller re-presents an unconsumed suffix with `action=Finish`; once accepted, the
/// request remains sticky and later protocol input is left untouched.
test "Deflater finalization preserves unconsumed input under backpressure" {
  let prefix = Bytes::from_array(Array::make(17000, b'\x5A'))
  let final_input = b"terminal-state payload"
  let after_end = b"belongs to the next protocol state"
  let def = @flate.Deflater::new(level=0)
  let no_output = FixedArray::make(0, b'\x00')
  let compressed = Buffer()
  let prefix_status = def.step(prefix[:], no_output.mut_view())
  let prefix_consumed = def.last_consumed()
  let prefix_produced = def.last_produced()
  assert_true(prefix_status is NeedMoreOutput)
  assert_true(prefix_consumed < prefix.length())
  assert_eq(prefix_produced, 0)
  let obuf = FixedArray::make(257, b'\x00')
  let mut prefix_pos = prefix_consumed
  for ;; {
    let status = def.step(prefix[prefix_pos:], obuf.mut_view())
    let consumed = def.last_consumed()
    let produced = def.last_produced()
    prefix_pos = prefix_pos + consumed
    for i in 0..<produced {
      compressed.write_byte(obuf[i])
    }
    if prefix_pos == prefix.length() && status is NeedMoreInput {
      break
    }
  }
  // Queue a sync-flush marker without output room so final input first meets
  // older compressed output and must remain wholly unconsumed.
  let flush_status = def.step(b""[:], no_output.mut_view(), action=SyncFlush)
  let _flush_consumed = def.last_consumed()
  let _flush_produced = def.last_produced()
  assert_true(flush_status is NeedMoreOutput)
  let first_status = def.step(
    final_input[:],
    no_output.mut_view(),
    action=Finish,
  )
  let first_consumed = def.last_consumed()
  let first_produced = def.last_produced()
  assert_true(first_status is NeedMoreOutput)
  assert_eq(first_consumed, 0)
  assert_eq(first_produced, 0)
  let mut drain_calls = 0
  let mut final_pos = 0
  for ;; {
    let view = if final_pos < final_input.length() {
      final_input[final_pos:]
    } else {
      after_end[:]
    }
    let status = def.step(
      view,
      obuf.mut_view(),
      action=if final_pos < final_input.length() { Finish } else { Continue },
    )
    let consumed = def.last_consumed()
    let produced = def.last_produced()
    if final_pos < final_input.length() {
      final_pos = final_pos + consumed
    } else {
      assert_eq(consumed, 0)
    }
    for i in 0..<produced {
      compressed.write_byte(obuf[i])
    }
    drain_calls = drain_calls + 1
    if status is Done {
      break
    }
    assert_true(status is NeedMoreOutput)
  }
  assert_true(drain_calls > 1)
  assert_eq(final_pos, final_input.length())
  assert_true(def.is_finished())
  let expected = Buffer()
  for byte in prefix {
    expected.write_byte(byte)
  }
  for byte in final_input {
    expected.write_byte(byte)
  }
  assert_eq(@flate.inflate_all(compressed.to_bytes()), expected.to_bytes())
  let sentinel = FixedArray::make(4, b'\xA5')
  let done_status = def.step(
    after_end[:],
    sentinel.mut_view(),
    action=SyncFlush,
  )
  let done_consumed = def.last_consumed()
  let done_produced = def.last_produced()
  assert_true(done_status is Done)
  assert_eq(done_consumed, 0)
  assert_eq(done_produced, 0)
  for byte in sentinel {
    assert_eq(byte, b'\xA5')
  }
}
