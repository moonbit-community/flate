///|
fn expect_writer_error(f : () -> Unit raise) -> Unit raise {
  try f() catch {
    ZipError(kind, _) => assert_eq(kind, UnsupportedFeature)
    _ => fail("unexpected writer error")
  } noraise {
    _ => fail("expected writer error")
  }
}

///|
test "incremental ZIP mixes whole files and known or unknown sized entries" {
  let out = Buffer()
  let writer = Writer(bytes => out.write_bytes(bytes))
  assert_eq(writer.position(), 0UL)
  assert_false(writer.is_finished())
  assert_false(writer.is_failed())
  writer.add("stored", b"abc", compression=Store)
  writer.add("deflated", b"abcabcabc")
  writer.add("reused", b"abcabcabc")
  for compression in [Store, Deflate] {
    for known in [true, false] {
      let compression_name = if compression is Store {
        "store"
      } else {
        "deflate"
      }
      let name = "chunked-\{compression_name}-\{known}"
      if known {
        writer.begin_entry(name, compression~, size=6UL)
      } else {
        writer.begin_entry(name, compression~)
      }
      writer.write(b"")
      writer.write(b"abc")
      writer.write(b"abc")
      writer.end_entry()
    }
  }
  writer.begin_entry("empty", compression=Store, size=0UL)
  writer.end_entry()
  writer.finish(comment=b"comment")
  let bytes = out.to_bytes()
  assert_true(writer.is_finished())
  assert_false(writer.is_failed())
  assert_eq(writer.position(), bytes.length().to_uint64())
  let archive = read(bytes)
  assert_eq(archive.entries().length(), 8)
  assert_eq(archive.comment().to_owned(), b"comment")
  for entry in archive.entries() {
    assert_eq(entry.crc32(), @checksum.crc32(entry.data()))
  }
  assert_eq(archive.get("stored").unwrap().to_owned(), b"abc")
  assert_eq(archive.get("deflated").unwrap().to_owned(), b"abcabcabc")
  for index in 3..<7 {
    assert_eq(archive.entries()[index].data().to_owned(), b"abcabc")
  }
  assert_eq(archive.get("empty").unwrap().length(), 0)
  expect_writer_error(() => writer.finish())
  expect_writer_error(() => writer.add("late", b""))
  expect_writer_error(() => writer.write(b""))
}

///|
test "incremental ZIP pumps multiple output buffers and reuses the deflater" {
  let mut seed = 0x12345678U
  let payload = Bytes::makei(262144, _ => {
    seed = seed ^ (seed << 13)
    seed = seed ^ (seed >> 17)
    seed = seed ^ (seed << 5)
    seed.to_byte()
  })
  let out = Buffer()
  let writer = Writer(bytes => out.write_bytes(bytes))
  for name in ["first", "second"] {
    writer.begin_entry(name, size=payload.length().to_uint64())
    writer.write(payload)
    writer.end_entry()
  }
  writer.finish()
  let archive = read(out.to_bytes())
  for entry in archive.entries() {
    assert_eq(entry.data().to_owned(), payload)
    assert_eq(entry.crc32(), @checksum.crc32(payload))
  }
}

///|
test "incremental ZIP validates states and allows recovery from size errors" {
  let out = Buffer()
  let writer = Writer(bytes => out.write_bytes(bytes))
  expect_writer_error(() => writer.write(b"x"))
  expect_writer_error(() => writer.end_entry())
  let long_name = String::make(65536, 'x')
  expect_writer_error(() => writer.add(long_name, b""))
  expect_writer_error(() => writer.begin_entry(long_name))
  writer.begin_entry("a", compression=Store, size=3UL)
  expect_writer_error(() => writer.begin_entry("b"))
  expect_writer_error(() => writer.add("b", b""))
  expect_writer_error(() => writer.finish())
  expect_writer_error(() => writer.write(b"abcd"))
  writer.write(b"a")
  expect_writer_error(() => writer.end_entry())
  writer.write(b"bc")
  writer.end_entry()
  expect_writer_error(() => writer.finish(comment=Bytes::make(65536, b'x')))
  writer.finish()
  assert_eq(read(out.to_bytes()).get("a").unwrap().to_owned(), b"abc")
}

///|
suberror StreamSinkFailure {
  StreamSinkFailure(Int)
}

///|
test "incremental ZIP propagates sink errors and poisons the writer" {
  for fail_at in [1, 2, 3] {
    let mut calls = 0
    let writer = Writer(_ => {
      calls += 1
      if calls == fail_at {
        raise StreamSinkFailure(42)
      }
    })
    try {
      writer.add("a", b"payload", compression=Store)
      writer.finish()
    } catch {
      StreamSinkFailure(code) => assert_eq(code, 42)
      _ => fail("unexpected sink error")
    } noraise {
      _ => fail("expected sink failure")
    }
    assert_true(writer.is_failed())
    assert_false(writer.is_finished())
    expect_writer_error(() => writer.add("b", b""))
    expect_writer_error(() => writer.finish())
    expect_writer_error(() => writer.write(b""))
    assert_eq(calls, fail_at)
  }
}

///|
test "incremental ZIP rejects reentrant sink calls" {
  let cell : Array[Writer] = []
  let writer = Writer(_ => cell[0].add("recursive", b""))
  cell.push(writer)
  expect_writer_error(() => writer.add("outer", b"x"))
  assert_true(writer.is_failed())
  assert_eq(writer.position(), 0UL)
}

///|
test "incremental ZIP guards UInt64 offsets and sizes without huge buffers" {
  let writer = Writer(_ => ())
  writer.offset = 0xffff_ffff_ffff_ffffUL
  expect_writer_error(() => writer.add("a", b""))
  assert_true(writer.is_failed())
  assert_eq(writer.position(), 0xffff_ffff_ffff_ffffUL)
  let entry_writer = Writer(_ => ())
  entry_writer.begin_entry("a", compression=Store)
  entry_writer.pending().size = 0xffff_ffff_ffff_ffffUL
  expect_writer_error(() => entry_writer.write(b"x"))
  assert_false(entry_writer.is_failed())
}

///|
test "incremental ZIP emits ZIP64 offset and count sentinels" {
  // Simulate a sink already positioned at the classic offset boundary.
  let out = Buffer()
  let writer = Writer(bytes => out.write_bytes(bytes))
  writer.offset = 0xffff_ffffUL
  writer.add("a", b"x", compression=Store)
  writer.finish()
  let bytes = out.to_bytes()
  let directory = 32
  assert_eq(read_u32_le_at_raw(bytes, directory), CENTRAL_HEADER_SIG)
  assert_eq(read_u32_le_at_raw(bytes, directory + 42), MAX_U32)
  assert_eq(read_u16_le_at(bytes, directory + 6), 45)
  assert_eq(read_u64_le_at(bytes, directory + 51), 0xffff_ffffUL)
  let eocd = bytes.length() - 22
  assert_eq(read_u16_le_at(bytes, eocd + 10), 0xffff)
  assert_eq(read_u32_le_at_raw(bytes, eocd + 16), MAX_U32)
  // A ZIP64 size plus offset must encode all three extra fields.
  let record = stream_central_record(
    b"a",
    Store,
    1U,
    3UL,
    2UL,
    0xffff_ffffUL,
    true,
    true,
  )
  assert_eq(read_u16_le_at(record, 30), 28)
  assert_eq(read_u64_le_at(record, 51), 3UL)
  assert_eq(read_u64_le_at(record, 59), 2UL)
  assert_eq(read_u64_le_at(record, 67), 0xffff_ffffUL)
  let counted = Buffer()
  let many = Writer(bytes => counted.write_bytes(bytes))
  many.directory = Array::make(65535, b"")
  many.finish()
  assert_eq(read_u32_le_at_raw(counted.to_bytes(), 0), ZIP64_EOCD_SIG)
}
