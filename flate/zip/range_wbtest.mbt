///|
fn list_zip_ranges(bytes : Bytes) -> Directory raise ZipError {
  let reader = DirectoryReader(bytes.length().to_uint64())
  for input = (b"" : BytesView) {
    match reader.advance(input) {
      NeedRead(range) => {
        let offset = range.offset().to_int()
        continue bytes[offset:offset + range.length()]
      }
      Done(directory) => break directory
    }
  }
}

///|
fn extract_zip_ranges(
  directory : Directory,
  index : Int32,
  bytes : Bytes,
  output_size : Int32,
) -> Bytes raise ZipError {
  let reader = directory.open_entry(index)
  let output = FixedArray::make(output_size, b'\x00')
  let decoded = @buffer.Buffer()
  for input = (b"" : BytesView) {
    let status = reader.step(input, output)
    decoded.write_bytes(Bytes::from_array(output[:reader.last_produced()]))
    match status {
      NeedRead(range) => {
        let offset = range.offset().to_int()
        continue bytes[offset:offset + range.length()]
      }
      NeedMoreOutput => continue b""
      Done => break decoded.to_bytes()
    }
  }
}

///|
test "memory and range readers agree on decoded size mismatches" {
  for compression in [Store, Deflate] {
    let bytes = zip_with_underreported_size(compression)
    let directory = list_zip_ranges(bytes)
    expect_zip_kind(() => ignore(read(bytes)), SizeMismatch)
    expect_zip_kind(
      () => ignore(extract_zip_ranges(directory, 1, bytes, 3)),
      SizeMismatch,
    )
  }
}

///|
test "memory and range readers agree on local size mismatches" {
  for compression in [Store, Deflate] {
    let archive = Archive()
    archive.add("x", b"0123456789", compression~)
    let original = write(archive)
    let directory = list_zip_ranges(original)
    @test.assert_eq(
      extract_zip_ranges(directory, 0, original, 3),
      b"0123456789",
    )
    let changed = original.to_array()
    changed[22] = b'\x04'
    let bytes = Bytes::from_array(changed)
    let directory = list_zip_ranges(bytes)
    expect_zip_kind(() => ignore(read(bytes)), SizeMismatch)
    expect_zip_kind(
      () => ignore(extract_zip_ranges(directory, 0, bytes, 3)),
      SizeMismatch,
    )
  }
}
