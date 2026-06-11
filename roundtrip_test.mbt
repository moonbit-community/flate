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
    let (st, c, p) = def.step(chunk, obuf.mut_view(), end=last)
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
    let (st, c, p) = def.step(chunk, obuf.mut_view(), end=last)
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
