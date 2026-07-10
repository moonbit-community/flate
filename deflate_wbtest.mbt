///|
/// The block cap keeps both accepted input and generated output bounded even
/// when a large caller-owned view is paired with no output capacity.
test "Deflater pending stays bounded after a large feed" {
  let d = Deflater::new()
  let no_output = FixedArray::make(0, b'\x00')
  let arr : Array[Byte] = []
  for i in 0..<200000 {
    arr.push((i % 251).to_byte())
  }
  let src = Bytes::from_array(arr)
  let first_status = d.step(src[:], no_output.mut_view())
  let first_consumed = d.last_consumed()
  let first_produced = d.last_produced()
  assert_true(first_status is NeedMoreOutput)
  assert_true(first_consumed > 0)
  assert_true(first_consumed < src.length())
  assert_eq(first_produced, 0)
  assert_true(
    d.pending.length() <= window_size + deflate_block_size + min_lookahead,
  )
  assert_true(d.w.out.length() <= deflate_block_size + min_lookahead + 16)

  let buf = FixedArray::make(65536, b'\x00')
  let mut pos = first_consumed
  for ;; {
    let status = d.step(src[pos:], buf.mut_view())
    let consumed = d.last_consumed()
    pos = pos + consumed
    assert_true(
      d.pending.length() <= window_size + deflate_block_size + min_lookahead,
    )
    assert_true(d.w.out.length() <= deflate_block_size + min_lookahead + 16)
    if status is NeedMoreInput && pos == src.length() {
      break
    }
  }
  assert_eq(pos, src.length())
}

///|
test "Deflater latches end before a completed view is backpressured" {
  let source = Bytes::from_array(
    Array::make(deflate_block_size + min_lookahead, b'\x41'),
  )
  let deflater = Deflater::new(level=0)
  let no_output = FixedArray::make(0, b'\x00')
  let first_status = deflater.step(
    source[:],
    no_output.mut_view(),
    action=Finish,
  )
  let consumed = deflater.last_consumed()
  let produced = deflater.last_produced()
  assert_true(first_status is NeedMoreOutput)
  assert_eq(consumed, source.length())
  assert_eq(produced, 0)
  assert_true(deflater.end_requested)
  let compressed = Buffer()
  let output = FixedArray::make(257, b'\x00')
  for ;; {
    // The original one-shot end request must suffice while draining.
    let status = deflater.step(b""[:], output.mut_view())
    let later_consumed = deflater.last_consumed()
    let n = deflater.last_produced()
    assert_eq(later_consumed, 0)
    for i in 0..<n {
      compressed.write_byte(output[i])
    }
    if status is Done {
      break
    }
    assert_true(status is NeedMoreOutput)
  }
  assert_eq(inflate_all(compressed.to_bytes()), source)
}

///|
test "stored block count handles empty and 65535-byte boundaries" {
  assert_eq(stored_block_count(0), 1)
  assert_eq(stored_block_count(1), 1)
  assert_eq(stored_block_count(65534), 1)
  assert_eq(stored_block_count(65535), 1)
  assert_eq(stored_block_count(65536), 2)
  assert_eq(stored_block_count(131069), 2)
  assert_eq(stored_block_count(131070), 2)
  assert_eq(stored_block_count(131071), 3)
}

///|
test "Deflater reset clears a queued flush request" {
  let d = Deflater::new(level=0)
  let src = Bytes::from_array(Array::make(17000, b'\x5A'))
  let no_output = FixedArray::make(0, b'\x00')
  let _ = d.step(src[:], no_output.mut_view())
  let _ = d.step(b""[:], no_output.mut_view(), action=SyncFlush)
  assert_true(d.flush_requested)
  d.reset()
  assert_false(d.flush_requested)
}

///|
test "Deflater reset clears a queued end request" {
  let d = Deflater::new(level=0)
  let src = Bytes::from_array(Array::make(17000, b'\x5A'))
  let no_output = FixedArray::make(0, b'\x00')
  let _ = d.step(src[:], no_output.mut_view())
  let _ = d.step(b""[:], no_output.mut_view(), action=Finish)
  assert_true(d.end_requested)
  assert_false(d.emitted_final)
  d.reset()
  assert_false(d.end_requested)
}
