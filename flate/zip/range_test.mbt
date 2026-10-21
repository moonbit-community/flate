///|
fn archive_range_source(bytes : Bytes) -> (@zip.ReadRange) -> BytesView {
  range => {
    let offset = range.offset().to_int()
    bytes[offset:offset + range.length()]
  }
}

///|
fn drive_directory_ranges(
  reader : @zip.DirectoryReader,
  source : (@zip.ReadRange) -> BytesView,
) -> @zip.Directory raise @zip.ZipError {
  for input = (b"" : BytesView) {
    match reader.advance(input) {
      NeedRead(range) => continue source(range)
      Done(directory) => break directory
    }
  }
}

///|
fn drive_entry_ranges(
  reader : @zip.EntryReader,
  source : (@zip.ReadRange) -> BytesView,
  output_size : Int32,
) -> Bytes raise @zip.ZipError {
  let output = FixedArray::make(output_size, b'\x00')
  let decoded = @buffer.Buffer()
  for input = (b"" : BytesView) {
    let status = reader.step(input, output)
    // NeedRead and Done may carry output too.
    decoded.write_bytes(Bytes::from_array(output[:reader.last_produced()]))
    match status {
      NeedRead(range) => continue source(range)
      NeedMoreOutput => continue b""
      Done => break decoded.to_bytes()
    }
  }
}

///|
test "range readers extract independent classic, ZIP64 and descriptor fixtures" {
  for bytes in [py_mini, py_zip64, py_descriptor, optional_zip64] {
    let source = archive_range_source(bytes)
    let directory_reader = @zip.DirectoryReader(bytes.length().to_uint64())
    let directory = drive_directory_ranges(directory_reader, source)
    let archive = @zip.read(bytes)
    @test.assert_eq(directory.entries().length(), archive.entries().length())
    guard directory_reader.advance(b"") is Done(repeated) else {
      @test.fail("completed directory reader requested more input")
    }
    @test.assert_eq(repeated.entries().length(), directory.entries().length())
    for i = 0; i < directory.entries().length(); i = i + 1 {
      let entry = directory.entries()[i]
      let expected = archive.entries()[i]
      @test.assert_eq(entry.name(), expected.name())
      @test.assert_eq(entry.crc32(), expected.crc32())
      let reader = directory.open_entry(i)
      @test.assert_eq(
        drive_entry_ranges(reader, source, 1),
        expected.data().to_owned(),
      )
      @test.assert_eq(reader.total_consumed(), entry.compressed_size())
      @test.assert_eq(reader.total_produced(), entry.uncompressed_size())
      assert_true(reader.step(b"", []) is Done)
      @test.assert_eq(reader.last_produced(), 0)
    }
  }
}

///|
test "directory records spanning chunks retain duplicate-name entry identity" {
  let archive = @zip.Archive()
  // The first central record is 65526 bytes, so the next header straddles
  // the first 64 KiB directory response.
  let long_name = String::make(65480, 'a')
  archive.add(long_name, b"", compression=Store)
  archive.add("same", b"first", compression=Store)
  archive.add("same", b"second", compression=Deflate)
  let bytes = @zip.write(archive)
  let source = archive_range_source(bytes)
  let requests : Array[Int32] = []
  let directory = drive_directory_ranges(
    DirectoryReader(bytes.length().to_uint64()),
    range => {
      requests.push(range.length())
      source(range)
    },
  )
  assert_true(requests.any(length => length == 65536))
  @test.assert_eq(directory.entries().length(), 3)
  @test.assert_eq(directory.entries()[0].name(), long_name)
  @test.assert_eq(directory.entries()[1].name(), "same")
  @test.assert_eq(directory.entries()[2].name(), "same")
  @test.assert_eq(
    drive_entry_ranges(directory.open_entry(1), source, 2),
    b"first",
  )
  @test.assert_eq(
    drive_entry_ranges(directory.open_entry(2), source, 2),
    b"second",
  )
}

///|
test "range protocol errors latch and empty output suspends extraction" {
  let source = archive_range_source(py_mini)
  let directory_reader = @zip.DirectoryReader(py_mini.length().to_uint64())
  guard directory_reader.advance(b"") is NeedRead(range) else {
    @test.fail("expected initial tail request")
  }
  let ZipError(kind, _) = @test.expect_error(() => directory_reader.advance(b""))
  @test.assert_eq(kind, InvalidRead)
  let ZipError(repeated, _) = @test.expect_error(() => {
    directory_reader.advance(source(range))
  })
  @test.assert_eq(repeated, kind)
  let directory = drive_directory_ranges(
    DirectoryReader(py_mini.length().to_uint64()),
    source,
  )
  let reader = directory.open_entry(0)
  guard reader.step(b"", []) is NeedRead(header) else {
    @test.fail("expected local-header request")
  }
  let ZipError(kind, _) = @test.expect_error(() => reader.step(b"", []))
  @test.assert_eq(kind, InvalidRead)
  let ZipError(repeated, _) = @test.expect_error(() => {
    reader.step(source(header), [])
  })
  @test.assert_eq(repeated, kind)
  @test.assert_eq(reader.last_produced(), 0)
  @test.assert_eq(reader.total_consumed(), 0UL)
  @test.assert_eq(reader.total_produced(), 0UL)

  let reader = directory.open_entry(0)
  for input = (b"" : BytesView) {
    match reader.step(input, []) {
      NeedRead(range) => continue source(range)
      NeedMoreOutput => break
      Done => @test.fail("empty output completed a nonempty payload")
    }
  }
  @test.assert_eq(reader.last_produced(), 0)
  @test.assert_eq(reader.total_consumed(), 0UL)
  @test.assert_eq(drive_entry_ranges(reader, source, 1), b"hi")
}

///|
test "range entry failures preserve CRC, descriptor and limit categories" {
  let archive = @zip.Archive()
  archive.add("x", b"0123456789", compression=Store)
  let original = @zip.write(archive)
  let changed = original.to_array()
  changed[31] = b'x' // first stored payload byte, after the one-byte name
  let damaged = Bytes::from_array(changed)
  let source = archive_range_source(damaged)
  let directory = drive_directory_ranges(
    DirectoryReader(damaged.length().to_uint64()),
    source,
  )
  let reader = directory.open_entry(0)
  let ZipError(kind, _) = @test.expect_error(() => {
    drive_entry_ranges(reader, source, 2)
  })
  @test.assert_eq(kind, ChecksumMismatch)
  @test.assert_eq(reader.last_produced(), 0)
  let ZipError(repeated, _) = @test.expect_error(() => {
    reader.step(b"unexpected", [])
  })
  @test.assert_eq(repeated, kind)
  @test.assert_eq(reader.last_produced(), 0)
  let ZipError(kind, _) = @test.expect_error(() => {
    directory.open_entry(0, limits=EntryReadLimits(max_output_bytes=9UL))
  })
  @test.assert_eq(kind, LimitExceeded(EntryUncompressedBytes, 9UL, 10UL))
  let ZipError(kind, _) = @test.expect_error(() => directory.open_entry(1))
  @test.assert_eq(kind, InvalidEntryIndex(1))

  let source = archive_range_source(py_descriptor)
  let directory = drive_directory_ranges(
    DirectoryReader(py_descriptor.length().to_uint64()),
    source,
  )
  // Python fixture: 30-byte local header, eight-byte name, no extra field.
  let descriptor = 38 + directory.entries()[0].compressed_size().to_int()
  let changed = py_descriptor.to_array()
  changed[descriptor + 4] = (changed[descriptor + 4].to_int() ^ 1).to_byte()
  let damaged = Bytes::from_array(changed)
  let source = archive_range_source(damaged)
  let directory = drive_directory_ranges(
    DirectoryReader(damaged.length().to_uint64()),
    source,
  )
  let reader = directory.open_entry(0)
  let ZipError(kind, _) = @test.expect_error(() => {
    drive_entry_ranges(reader, source, 3)
  })
  @test.assert_eq(kind, UnsupportedFeature)
  @test.assert_eq(reader.last_produced(), 0)
  let ZipError(repeated, _) = @test.expect_error(() => reader.step(b"", []))
  @test.assert_eq(repeated, kind)
}

///|
test "range output limit checks observed bytes even when declarations lie" {
  let archive = @zip.Archive()
  archive.add("x", b"0123456789")
  let original = @zip.write(archive)
  let directory = drive_directory_ranges(
    DirectoryReader(original.length().to_uint64()),
    archive_range_source(original),
  )
  let central = 31 + directory.entries()[0].compressed_size().to_int()
  let changed = original.to_array()
  changed[22] = b'\x04'
  changed[central + 24] = b'\x04'
  let damaged = Bytes::from_array(changed)
  let source = archive_range_source(damaged)
  let directory = drive_directory_ranges(
    DirectoryReader(damaged.length().to_uint64()),
    source,
  )
  let reader = directory.open_entry(
    0,
    limits=EntryReadLimits(max_output_bytes=5UL),
  )
  let ZipError(kind, _) = @test.expect_error(() => {
    drive_entry_ranges(reader, source, 16)
  })
  @test.assert_eq(kind, LimitExceeded(EntryUncompressedBytes, 5UL, 10UL))
  @test.assert_eq(reader.last_produced(), 0)
  let ZipError(repeated, _) = @test.expect_error(() => reader.step(b"", []))
  @test.assert_eq(repeated, kind)
}

///|
test "ZIP64 range offsets exceed 4 GiB without allocating the archive" {
  let base = 0x1_0000_0000UL
  let changed = py_zip64.to_array()
  // Relocate the independent ZIP64 fixture behind a virtual zero prefix.
  // Patch the central extra's local offset, ZIP64 central offset, and locator.
  for (offset, value) in [(138, base), (194, base + 65UL), (210, base + 146UL)] {
    for i = 0; i < 8; i = i + 1 {
      changed[offset + i] = ((value >> (8 * i)) & 0xffUL).to_int().to_byte()
    }
  }
  let suffix = Bytes::from_array(changed)
  let archive_size = base + suffix.length().to_uint64()
  let requested : Array[UInt64] = []
  let source = (range : @zip.ReadRange) => {
    let start = range.offset()
    requested.push(start)
    let output = FixedArray::make(range.length(), b'\x00')
    let destination = if start < base { (base - start).to_int() } else { 0 }
    let offset = if start > base { (start - base).to_int() } else { 0 }
    if destination < output.length() {
      output.blit_from_bytes(
        destination,
        suffix,
        offset,
        output.length() - destination,
      )
    }
    (Bytes::from_array(output) : BytesView)
  }
  let directory = drive_directory_ranges(DirectoryReader(archive_size), source)
  @test.assert_eq(directory.entries()[0].name(), "big.bin")
  let reader = directory.open_entry(0)
  @test.assert_eq(drive_entry_ranges(reader, source, 3), b"xxxxxxxx")
  @test.assert_eq(reader.total_consumed(), 8UL)
  @test.assert_eq(reader.total_produced(), 8UL)
  assert_true(requested.any(offset => offset == base))
}
