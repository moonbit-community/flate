///|
test "Inflater owns only a bounded atomic tail between non-overlapping chunks" {
  let bytes : Array[Byte] = []
  for i in 0..<4096 {
    bytes.push(((i * 29 + i / 7) & 0x0F).to_byte())
  }
  let source = Bytes::from_array(bytes)
  let compressed = deflate_all(source)
  let inflater = Inflater::new()
  let output = FixedArray::make(1, b'\x00')
  let decoded = Buffer()
  let mut pos = 0
  for ;; {
    let endi = if pos < compressed.length() { pos + 1 } else { pos }
    let (status, consumed, produced) = inflater.step(
      compressed[pos:endi],
      output.mut_view(),
      end=endi == compressed.length(),
    )
    pos = pos + consumed
    if produced == 1 {
      decoded.write_byte(output[0])
    }
    // A full dynamic header is the largest atomic input unit and is well below
    // this defensive test bound. Call-owned views must already be released.
    assert_true(inflater.staged_input.length() <= 512)
    assert_eq(inflater.view.length(), 0)
    assert_eq(inflater.out.length(), 0)
    if status is Done {
      break
    }
  }
  assert_eq(pos, compressed.length())
  assert_eq(decoded.to_bytes(), source)
}
