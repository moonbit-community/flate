///|
/// The block cap keeps `pending` bounded: after a large single feed is fully
/// processed, at most a 32 KB window plus one block (and lookahead margin)
/// remains buffered.
test "Deflater pending stays bounded after a large feed" {
  let d = Deflater::new()
  let buf = FixedArray::make(65536, b'\x00')
  let arr : Array[Byte] = []
  for i in 0..<200000 {
    arr.push((i % 251).to_byte())
  }
  let src = Bytes::from_array(arr)
  let mut fed = false
  for ;; {
    let view = if fed { b""[:] } else { src[:] }
    fed = true
    let (st, _c, _p) = d.step(view, buf, out_off=0)
    if st is NeedMoreInput {
      break
    }
  }
  assert_true(
    d.pending.length() <= window_size + deflate_block_size + min_lookahead,
  )
}
