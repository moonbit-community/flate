///|
test "inflate suspends/resumes across a tiny output buffer" {
  let inf = @flate.Inflater()
  let small : FixedArray[Byte] = FixedArray::make(2, b'\x00')
  let collected = Buffer()
  let view = hello_stored[:]
  let mut consumed = 0
  for ;; {
    let status = inf.step(view[consumed:], small.mut_view())
    let used = inf.last_consumed()
    let produced = inf.last_produced()
    for i in 0..<produced {
      collected.write_byte(small[i])
    }
    consumed = consumed + used
    if status is Done {
      break
    }
  }
  assert_eq(collected.to_bytes(), b"hello")
  assert_true(inf.is_finished())
}

///|
/// Stream a dynamic-Huffman block through `step`, revealing input 5 bytes at a
/// time and draining a 300-byte output buffer (< 611 decoded), exercising both
/// NeedMoreInput and NeedMoreOutput suspension/resume.
test "Inflater::step streams a dynamic block in small chunks" {
  let comp = v_dynamic_text
  let inf = @flate.Inflater()
  let obuf = FixedArray::make(300, b'\x00')
  let result = Buffer()
  let mut consumed = 0
  let mut avail = 0
  for ;; {
    let st = inf.step(comp[consumed:avail], obuf.mut_view())
    let c = inf.last_consumed()
    let p = inf.last_produced()
    for i in 0..<p {
      result.write_byte(obuf[i])
    }
    consumed = consumed + c
    if st is Done {
      break
    }
    if st is NeedMoreInput {
      if avail >= comp.length() {
        fail("unexpected truncation")
      }
      avail = if avail + 5 < comp.length() { avail + 5 } else { comp.length() }
    }
  }
  let out = result.to_bytes()
  inspect(out.length(), content="611")
  assert_eq(
    out[0:44].to_owned(),
    b"The quick brown fox jumps over the lazy dog.",
  )
}

///|
/// Stream a fixed-Huffman block (with back-references) one input byte at a time.
test "Inflater::step streams a fixed block one input byte at a time" {
  let comp = v_fixed_aaa
  let inf = @flate.Inflater()
  let obuf = FixedArray::make(300, b'\x00')
  let result = Buffer()
  let mut consumed = 0
  let mut avail = 0
  for ;; {
    let st = inf.step(comp[consumed:avail], obuf.mut_view())
    let c = inf.last_consumed()
    let p = inf.last_produced()
    for i in 0..<p {
      result.write_byte(obuf[i])
    }
    consumed = consumed + c
    if st is Done {
      break
    }
    if st is NeedMoreInput {
      if avail >= comp.length() {
        fail("unexpected truncation")
      }
      avail = avail + 1
    }
  }
  assert_eq(result.to_bytes(), b"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
}

///|
/// Drain a long back-reference (30 'a's, a single match) through a *1-byte*
/// output buffer, forcing the decoder to suspend and resume mid-copy on every
/// byte. This is the case the async `@io.Reader` driver hits with small reads,
/// which the old 258-byte-per-unit output floor would have deadlocked on.
test "Inflater::step makes progress with a 1-byte output buffer" {
  let inf = @flate.Inflater()
  let obuf = FixedArray::make(1, b'\x00')
  let result = Buffer()
  let view = v_fixed_aaa[:]
  let mut consumed = 0
  for ;; {
    let st = inf.step(view[consumed:], obuf.mut_view(end=1))
    let c = inf.last_consumed()
    let p = inf.last_produced()
    for i in 0..<p {
      result.write_byte(obuf[i])
    }
    consumed = consumed + c
    if st is Done {
      break
    }
  }
  assert_eq(result.to_bytes(), b"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
  assert_true(inf.is_finished())
}

///|
/// Decode the 611-byte dynamic block into a buffer far smaller than a single
/// 258-byte match, exercising mid-copy suspension plus `out_len` sub-ranging
/// (write into the middle of a larger array).
test "Inflater::step honors a small out_len within a larger buffer" {
  let inf = @flate.Inflater()
  let obuf = FixedArray::make(64, b'\x00')
  let result = Buffer()
  let view = v_dynamic_text[:]
  let mut consumed = 0
  for ;; {
    let st = inf.step(view[consumed:], obuf.mut_view(start=8, end=15))
    let c = inf.last_consumed()
    let p = inf.last_produced()
    for i in 8..<(8 + p) {
      result.write_byte(obuf[i])
    }
    consumed = consumed + c
    if st is Done {
      break
    }
  }
  let out = result.to_bytes()
  inspect(out.length(), content="611")
  assert_eq(
    out[0:44].to_owned(),
    b"The quick brown fox jumps over the lazy dog.",
  )
}
