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
  let (first_status, first_consumed, first_produced) = d.step(
    src[:],
    no_output.mut_view(),
  )
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
    let (status, consumed, _produced) = d.step(src[pos:], buf.mut_view())
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
  let (first_status, consumed, produced) = deflater.step(
    source[:],
    no_output.mut_view(),
    end=true,
  )
  assert_true(first_status is NeedMoreOutput)
  assert_eq(consumed, source.length())
  assert_eq(produced, 0)
  assert_true(deflater.end_requested)
  let compressed = Buffer()
  let output = FixedArray::make(257, b'\x00')
  for ;; {
    // The original one-shot end request must suffice while draining.
    let (status, later_consumed, n) = deflater.step(b""[:], output.mut_view())
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
  let _ = d.step(b""[:], no_output.mut_view(), flush=true)
  assert_true(d.flush_requested)
  assert_true(d.started)
  d.reset()
  assert_false(d.flush_requested)
  assert_false(d.started)
}

///|
test "Deflater reset clears a queued end request" {
  let d = Deflater::new(level=0)
  let src = Bytes::from_array(Array::make(17000, b'\x5A'))
  let no_output = FixedArray::make(0, b'\x00')
  let _ = d.step(src[:], no_output.mut_view())
  let _ = d.step(b""[:], no_output.mut_view(), end=true)
  assert_true(d.end_requested)
  assert_false(d.emitted_final)
  assert_true(d.started)
  d.reset()
  assert_false(d.end_requested)
  assert_false(d.started)
}

///|
/// An empty no-op call does not commit stream configuration, so a dictionary
/// may still be selected afterwards.
test "Deflater empty no-op remains fresh for a dictionary" {
  let d = Deflater::new()
  let no_output = FixedArray::make(0, b'\x00')
  let (status, consumed, produced) = d.step(b""[:], no_output.mut_view())
  assert_true(status is NeedMoreInput)
  assert_eq(consumed, 0)
  assert_eq(produced, 0)
  assert_false(d.started)
  d.set_dictionary(b"history"[:])
  assert_true(d.started)
}

///|
/// The old structural guard became fresh again after this empty marker drained;
/// the explicit lifecycle bit must still reject a late dictionary.
test "panic Deflater set_dictionary after an empty sync flush" {
  let d = Deflater::new()
  let output = FixedArray::make(16, b'\x00')
  ignore(d.step(b""[:], output.mut_view(), flush=true))
  d.set_dictionary(b"late dictionary"[:])
}

///|
/// Level zero clears pending input after emitting it, so lifecycle cannot be
/// inferred from an empty pending buffer either.
test "panic Deflater set_dictionary after nonempty input was emitted" {
  let d = Deflater::new(level=0)
  let input = Bytes::from_array(Array::make(17000, b'\x5A'))
  let output = FixedArray::make(18000, b'\x00')
  ignore(d.step(input[:], output.mut_view()))
  d.set_dictionary(b"late dictionary"[:])
}
