///|
/// Whitebox coverage for the ZIP package's error paths that the public round-trip
/// and limit tests cannot reach through `read`/`write` alone: checked numeric
/// conversions, the byte cursor, the zip64 helpers, and the writer's guards.

///|
fn expect_zip_error(f : () -> Unit raise ZipError) -> Unit raise {
  try f() catch {
    ZipError(_, _) => ()
  } noraise {
    _ => fail("expected a ZipError")
  }
}

///|
fn expect_zip_kind(
  f : () -> Unit raise ZipError,
  expect : ZipErrorKind,
) -> Unit raise {
  try f() catch {
    ZipError(kind, _) => assert_eq(kind, expect)
  } noraise {
    _ => fail("expected a ZipError")
  }
}

///|
test "zip checked conversions reject out-of-range values" {
  expect_zip_error(() => ignore(0x80000000U.to_int_checked()))
  expect_zip_error(() => ignore((-1).to_uint_checked()))
  expect_zip_error(() => ignore((-1).to_uint64_checked()))
}

///|
test "zip cursor and field readers reject truncated input" {
  expect_zip_error(() => ignore(Cursor(b"", 0).read_u8()))
  expect_zip_error(() => ignore(Cursor(b"", 0).read_bytes(1)))
  expect_zip_error(() => ignore(read_u16_le_at(b"", 0)))
  expect_zip_error(() => ignore(read_u32_le_at_raw(b"", 0)))
  expect_zip_error(() => ignore(read_u64_le_at(b"", 0)))
  assert_eq(find_end_of_central(b"too short"), None)
  expect_zip_kind(() => ignore(decode_name(b"\xff")), InvalidUtf8)
  expect_zip_kind(
    () => ensure_flags_supported(FLAG_ENCRYPTED),
    UnsupportedFeature,
  )
  expect_zip_kind(() => ensure_flags_supported(0x0010), UnsupportedFeature)
  expect_zip_kind(
    () => ignore(method_from_code(99)),
    UnsupportedCompression(99),
  )
}

///|
test "zip wrap_inflate_error maps both error surfaces" {
  ignore(@flate.inflate_exact(b"not a deflate stream")) catch {
    err => ignore(wrap_inflate_error(err))
  }
  try {
    raise ZipError(InvalidUtf8, "fabricated non-inflate error")
  } catch {
    err => ignore(wrap_inflate_error(err))
  }
}

///|
test "zip raw source records are exposed on read entries" {
  let archive = Archive()
  archive.add("a.txt", b"payload")
  let parsed = read(write(archive))
  let entry = parsed.entries()[0]
  assert_true(entry.raw_local_record() is Some(_))
  assert_true(entry.raw_central_record() is Some(_))
}

///|
fn push_u16le(buf : Array[Byte], v : Int) -> Unit {
  buf.push((v & 0xFF).to_byte())
  buf.push(((v >> 8) & 0xFF).to_byte())
}

///|
fn push_u32le(buf : Array[Byte], v : UInt) -> Unit {
  for i in 0..<4 {
    buf.push(((v >> (i * 8)) & 0xFF).reinterpret_as_int().to_byte())
  }
}

///|
fn push_u64le(buf : Array[Byte], v : UInt64) -> Unit {
  for i in 0..<8 {
    buf.push(((v >> (i * 8)) & 0xFF).to_int().to_byte())
  }
}

///|
fn bytes_of(buf : Array[Byte]) -> Bytes {
  Bytes::from_array(buf)
}

///|
test "zip extra-field and zip64 helpers reject malformed fields" {
  expect_zip_error(() => ignore(extra_field_at(b"", 0)))
  expect_zip_error(() => ignore(extra_field_at(b"\x01\x00\x05\x00", 0)))
  expect_zip_error(() => ignore(read_zip64_extra(b"", true, false, false)))
  expect_zip_error(() => {
    ignore(
      read_zip64_extra(b"\x01\x00\x04\x00\x00\x00\x00\x00", true, false, false),
    )
  })
  let ok = read_zip64_extra(
    b"\x01\x00\x08\x00\x00\x00\x00\x00\x00\x00\x00\x00", false, false, true,
  )
  assert_true(ok.3 is Some(_))
}

///|
test "zip zip64 end record rejects malformed trailers" {
  // Locator declares a second disk.
  let locator_multi_disk = {
    let buf : Array[Byte] = []
    push_u32le(buf, ZIP64_LOCATOR_SIG)
    push_u32le(buf, 0)
    push_u64le(buf, 0)
    push_u32le(buf, 2)
    bytes_of(buf)
  }
  expect_zip_error(() => ignore(read_zip64_eocd(locator_multi_disk, 20)))
  // Locator points at the end record itself (no room for one).
  let out_of_bounds = {
    let buf : Array[Byte] = []
    push_u32le(buf, ZIP64_LOCATOR_SIG)
    push_u32le(buf, 0)
    push_u64le(buf, 0)
    push_u32le(buf, 1)
    bytes_of(buf)
  }
  expect_zip_error(() => ignore(read_zip64_eocd(out_of_bounds, 20)))
  // End record carries the wrong signature.
  let bad_sig = {
    let buf : Array[Byte] = []
    push_u32le(buf, LOCAL_HEADER_SIG)
    for _ in 0..<8 {
      buf.push(b'\x00')
    }
    push_u32le(buf, ZIP64_LOCATOR_SIG)
    push_u32le(buf, 0)
    push_u64le(buf, 0)
    push_u32le(buf, 1)
    bytes_of(buf)
  }
  expect_zip_error(() => ignore(read_zip64_eocd(bad_sig, 32)))
  // End record size does not reach the locator.
  let size_mismatch = {
    let buf : Array[Byte] = []
    push_u32le(buf, ZIP64_EOCD_SIG)
    push_u64le(buf, 44)
    push_u32le(buf, ZIP64_LOCATOR_SIG)
    push_u32le(buf, 0)
    push_u64le(buf, 0)
    push_u32le(buf, 1)
    bytes_of(buf)
  }
  expect_zip_error(() => ignore(read_zip64_eocd(size_mismatch, 32)))
  // End record claims a non-zero disk number.
  let multi_disk = {
    let buf : Array[Byte] = []
    push_u32le(buf, ZIP64_EOCD_SIG)
    push_u64le(buf, 44)
    push_u16le(buf, 45)
    push_u16le(buf, 45)
    push_u32le(buf, 1)
    push_u32le(buf, 0)
    push_u64le(buf, 1)
    push_u64le(buf, 1)
    push_u64le(buf, 0)
    push_u64le(buf, 0)
    push_u32le(buf, ZIP64_LOCATOR_SIG)
    push_u32le(buf, 0)
    push_u64le(buf, 0)
    push_u32le(buf, 1)
    bytes_of(buf)
  }
  expect_zip_error(() => ignore(read_zip64_eocd(multi_disk, 76)))
  // Locator missing entirely (before the archive start).
  expect_zip_error(() => ignore(read_zip64_eocd(b"", 0)))
}

///|
fn descriptor_meta(crc~ : UInt) -> EntryMeta {
  {
    name: "",
    flags: 0,
    method_id: 0,
    crc,
    compressed_size: 4,
    uncompressed_size: 4,
    local_offset: 0,
    central_record: b"",
    central_zip64_offset_position: None,
    data_descriptor: true,
  }
}

///|
test "zip data-descriptor sizing matches and rejects ambiguous or bad layouts" {
  // Unsigned descriptor (no signature prefix).
  let unsigned = {
    let buf : Array[Byte] = []
    push_u32le(buf, 0x11223344U)
    push_u32le(buf, 4)
    push_u32le(buf, 4)
    bytes_of(buf)
  }
  assert_eq(
    data_descriptor_size(unsigned, 0, descriptor_meta(crc=0x11223344U), false),
    12,
  )
  // Signed descriptor.
  let signed = {
    let buf : Array[Byte] = []
    push_u32le(buf, DATA_DESCRIPTOR_SIG)
    push_u32le(buf, 0x11223344U)
    push_u32le(buf, 4)
    push_u32le(buf, 4)
    bytes_of(buf)
  }
  assert_eq(
    data_descriptor_size(signed, 0, descriptor_meta(crc=0x11223344U), false),
    16,
  )
  // ZIP64-sized unsigned descriptor.
  let zip64 = {
    let buf : Array[Byte] = []
    push_u32le(buf, 0x11223344U)
    push_u64le(buf, 4)
    push_u64le(buf, 4)
    bytes_of(buf)
  }
  assert_eq(
    data_descriptor_size(zip64, 0, descriptor_meta(crc=0x11223344U), true),
    20,
  )
  // A truncated descriptor raises inside the matcher and is rejected.
  let truncated = {
    let buf : Array[Byte] = []
    push_u32le(buf, 0x11223344U)
    bytes_of(buf)
  }
  expect_zip_kind(
    () => {
      ignore(
        data_descriptor_size(
          truncated,
          0,
          descriptor_meta(crc=0x11223344U),
          false,
        ),
      )
    },
    UnsupportedFeature,
  )
  // When CRC, sizes, and signature all share one value, both layouts match.
  let sig_int = DATA_DESCRIPTOR_SIG.reinterpret_as_int()
  let ambiguous_meta : EntryMeta = {
    name: "",
    flags: 0,
    method_id: 0,
    crc: DATA_DESCRIPTOR_SIG,
    compressed_size: sig_int,
    uncompressed_size: sig_int,
    local_offset: 0,
    central_record: b"",
    central_zip64_offset_position: None,
    data_descriptor: true,
  }
  let ambiguous = {
    let buf : Array[Byte] = []
    for _ in 0..<4 {
      push_u32le(buf, DATA_DESCRIPTOR_SIG)
    }
    bytes_of(buf)
  }
  expect_zip_kind(
    () => ignore(data_descriptor_size(ambiguous, 0, ambiguous_meta, false)),
    UnsupportedFeature,
  )
}

///|
fn local_record(
  flags : Int,
  method_id : Int,
  crc : UInt,
  comp_size : Int,
  uncomp_size : Int,
  name : Bytes,
  extra : Bytes,
  payload : Bytes,
  descriptor : Bytes,
) -> Bytes {
  let buf : Array[Byte] = []
  push_u32le(buf, LOCAL_HEADER_SIG)
  push_u16le(buf, 20)
  push_u16le(buf, flags)
  push_u16le(buf, method_id)
  push_u16le(buf, 0)
  push_u16le(buf, 0)
  push_u32le(buf, crc)
  push_u32le(buf, comp_size.reinterpret_as_uint())
  push_u32le(buf, uncomp_size.reinterpret_as_uint())
  push_u16le(buf, name.length())
  push_u16le(buf, extra.length())
  for b in name {
    buf.push(b)
  }
  for b in extra {
    buf.push(b)
  }
  for b in payload {
    buf.push(b)
  }
  for b in descriptor {
    buf.push(b)
  }
  bytes_of(buf)
}

///|
fn base_meta() -> EntryMeta {
  {
    name: "a.txt",
    flags: 0,
    method_id: 0,
    crc: 0x11111111U,
    compressed_size: 3,
    uncompressed_size: 3,
    local_offset: 0,
    central_record: b"",
    central_zip64_offset_position: None,
    data_descriptor: false,
  }
}

///|
test "zip local-record validation rejects each mismatch" {
  // Offset outside the central directory.
  expect_zip_error(() => {
    ignore(read_local_record(b"", { ..base_meta(), local_offset: 100, }, 50))
  })
  // Flags differ between local and central.
  let flags_bytes = local_record(
    0x0800, 0, 0x11111111U, 3, 3, b"a.txt", b"", b"abc", b"",
  )
  expect_zip_error(() => {
    ignore(read_local_record(flags_bytes, base_meta(), 100))
  })
  // Method differs.
  let method_bytes = local_record(
    0, 8, 0x11111111U, 3, 3, b"a.txt", b"", b"abc", b"",
  )
  expect_zip_error(() => {
    ignore(read_local_record(method_bytes, base_meta(), 100))
  })
  // Name differs.
  let name_bytes = local_record(
    0, 0, 0x11111111U, 3, 3, b"b.txt", b"", b"abc", b"",
  )
  expect_zip_error(() => ignore(read_local_record(name_bytes, base_meta(), 100)))
  // Descriptor entry with a mismatched CRC.
  let desc_crc_bytes = local_record(
    0x0008, 0, 0x22222222U, 3, 3, b"a.txt", b"", b"abc", b"",
  )
  expect_zip_error(() => {
    ignore(
      read_local_record(
        desc_crc_bytes,
        { ..base_meta(), flags: 0x0008, data_descriptor: true, },
        100,
      ),
    )
  })
  // Non-descriptor entry with a mismatched CRC.
  let crc_bytes = local_record(
    0, 0, 0x22222222U, 3, 3, b"a.txt", b"", b"abc", b"",
  )
  expect_zip_error(() => ignore(read_local_record(crc_bytes, base_meta(), 100)))
  // Size mismatch between local and central.
  let size_bytes = local_record(
    0, 0, 0x11111111U, 5, 5, b"a.txt", b"", b"abcde", b"",
  )
  expect_zip_error(() => ignore(read_local_record(size_bytes, base_meta(), 100)))
  // Compressed payload runs past the central directory.
  let overflow_bytes = local_record(
    0, 0, 0x11111111U, 3, 3, b"a.txt", b"", b"abc", b"",
  )
  expect_zip_error(() => {
    ignore(read_local_record(overflow_bytes, base_meta(), 37))
  })
  // A data descriptor extending past the central directory.
  let desc_overflow = {
    let buf : Array[Byte] = []
    push_u32le(buf, 0x11111111U)
    push_u32le(buf, 1)
    push_u32le(buf, 1)
    bytes_of(buf)
  }
  let desc_bytes = local_record(
    0x0008, 0, 0x11111111U, 1, 1, b"a", b"", b"x", desc_overflow,
  )
  expect_zip_error(() => {
    ignore(
      read_local_record(
        desc_bytes,
        {
          ..base_meta(),
          flags: 0x0008,
          compressed_size: 1,
          uncompressed_size: 1,
          name: "a",
          data_descriptor: true,
        },
        43,
      ),
    )
  })
}

///|
test "zip inflate_entry maps output-limit and corrupt-stream failures" {
  expect_zip_kind(
    () => {
      ignore(
        inflate_entry(
          b"garbage deflate stream",
          100,
          EntryUncompressedBytes,
          100,
          () => false,
        ),
      )
    },
    UnsupportedFeature,
  )
  let comp = @flate.deflate_all(b"0123456789")
  expect_zip_kind(
    () => {
      ignore(inflate_entry(comp[:], 5, EntryUncompressedBytes, 5, () => false))
    },
    LimitExceeded(EntryUncompressedBytes, 5, 5),
  )
}

///|
test "zip preserved-source budget rejects oversize charges" {
  expect_zip_error(() => SourceBudget(10).charge(11))
  expect_zip_error(() => SourceBudget(10).charge(-1))
}

///|
fn classic_eocd(
  disk_no : Int,
  disk_start : Int,
  disk_entries : Int,
  total_entries : Int,
  central_size : Int,
  central_offset : Int,
) -> Bytes {
  let buf : Array[Byte] = []
  push_u32le(buf, END_OF_CENTRAL_SIG)
  push_u16le(buf, disk_no)
  push_u16le(buf, disk_start)
  push_u16le(buf, disk_entries)
  push_u16le(buf, total_entries)
  push_u32le(buf, central_size.reinterpret_as_uint())
  push_u32le(buf, central_offset.reinterpret_as_uint())
  push_u16le(buf, 0)
  bytes_of(buf)
}

///|
fn zip64_trailer(
  zip_entries : UInt64,
  zip_size : UInt64,
  zip_offset : UInt64,
  classic_disk_entries : Int,
  classic_total_entries : Int,
  classic_size_raw : UInt,
  classic_offset_raw : UInt,
) -> Bytes {
  let buf : Array[Byte] = []
  push_u32le(buf, ZIP64_EOCD_SIG)
  push_u64le(buf, 44)
  push_u16le(buf, 45)
  push_u16le(buf, 45)
  push_u32le(buf, 0)
  push_u32le(buf, 0)
  push_u64le(buf, zip_entries)
  push_u64le(buf, zip_entries)
  push_u64le(buf, zip_size)
  push_u64le(buf, zip_offset)
  push_u32le(buf, ZIP64_LOCATOR_SIG)
  push_u32le(buf, 0)
  push_u64le(buf, 0)
  push_u32le(buf, 1)
  push_u32le(buf, END_OF_CENTRAL_SIG)
  push_u16le(buf, 0)
  push_u16le(buf, 0)
  push_u16le(buf, classic_disk_entries)
  push_u16le(buf, classic_total_entries)
  push_u32le(buf, classic_size_raw)
  push_u32le(buf, classic_offset_raw)
  push_u16le(buf, 0)
  bytes_of(buf)
}

///|
test "zip end-of-central parsing rejects inconsistent trailers" {
  let default_limits = ReadLimits::default()
  // Multi-disk classic EOCD.
  expect_zip_error(() => {
    ignore(
      parse_end_of_central(classic_eocd(1, 0, 0, 0, 0, 0), default_limits, () => {
        false
      }),
    )
  })
  // Classic entry-count mismatch.
  expect_zip_error(() => {
    ignore(
      parse_end_of_central(classic_eocd(0, 0, 2, 1, 0, 0), default_limits, () => {
        false
      }),
    )
  })
  // Central directory does not fill the declared bounds.
  expect_zip_error(() => {
    ignore(
      parse_end_of_central(classic_eocd(0, 0, 1, 1, 5, 0), default_limits, () => {
        false
      }),
    )
  })
  // Classic disk-entries disagree with the zip64 count.
  expect_zip_error(() => {
    ignore(
      parse_end_of_central(
        zip64_trailer(5, 0, 0, 0, 0xFFFF, 0, 0),
        default_limits,
        () => false,
      ),
    )
  })
  // Classic total-entries disagree with the zip64 count.
  expect_zip_error(() => {
    ignore(
      parse_end_of_central(
        zip64_trailer(5, 0, 0, 0xFFFF, 0, 0, 0),
        default_limits,
        () => false,
      ),
    )
  })
  // Classic central size disagrees with the zip64 size.
  expect_zip_error(() => {
    ignore(
      parse_end_of_central(
        zip64_trailer(5, 100, 0, 0xFFFF, 0xFFFF, 0, 0),
        default_limits,
        () => false,
      ),
    )
  })
  // Classic central offset disagrees with the zip64 offset.
  expect_zip_error(() => {
    ignore(
      parse_end_of_central(
        zip64_trailer(5, 100, 200, 0xFFFF, 0xFFFF, 0xFFFFFFFF, 0),
        default_limits,
        () => false,
      ),
    )
  })
  // Fully sentinel classic fields resolve through the zip64 record.
  let eocd = parse_end_of_central(
    zip64_trailer(3, 0, 0, 0xFFFF, 0xFFFF, 0xFFFFFFFF, 0xFFFFFFFF),
    default_limits,
    () => false,
  )
  assert_eq(eocd.entry_count, 3)
  assert_eq(eocd.central_size, 0)
  assert_eq(eocd.central_offset, 0)
  // Classic fields that mirror the zip64 values still resolve through the
  // zip64 record (only the disk count is sentinel to select the zip64 path).
  let eocd2 = parse_end_of_central(
    zip64_trailer(5, 0, 0, 0xFFFF, 5, 0, 0),
    default_limits,
    () => false,
  )
  assert_eq(eocd2.entry_count, 5)
  assert_eq(eocd2.central_size, 0)
  assert_eq(eocd2.central_offset, 0)
}

///|
fn central_record(
  disk : Int,
  flags : Int,
  method_id : Int,
  crc : UInt,
  comp_size : Int,
  uncomp_size : Int,
  name : Bytes,
  extra : Bytes,
  local_offset : Int,
) -> Bytes {
  let buf : Array[Byte] = []
  push_u32le(buf, CENTRAL_HEADER_SIG)
  push_u16le(buf, 20)
  push_u16le(buf, 20)
  push_u16le(buf, flags)
  push_u16le(buf, method_id)
  push_u16le(buf, 0)
  push_u16le(buf, 0)
  push_u32le(buf, crc)
  push_u32le(buf, comp_size.reinterpret_as_uint())
  push_u32le(buf, uncomp_size.reinterpret_as_uint())
  push_u16le(buf, name.length())
  push_u16le(buf, extra.length())
  push_u16le(buf, 0)
  push_u16le(buf, disk)
  push_u16le(buf, 0)
  push_u32le(buf, 0)
  push_u32le(buf, local_offset.reinterpret_as_uint())
  for b in name {
    buf.push(b)
  }
  for b in extra {
    buf.push(b)
  }
  bytes_of(buf)
}

///|
fn eocd_for(
  entry_count : Int,
  central_size : Int,
  central_len : Int,
) -> EndOfCentral {
  {
    eocd_offset: central_len,
    entry_count,
    central_size,
    central_offset: 0,
    central_boundary: central_len,
    zip64_eocd_offset: None,
    comment: b"",
  }
}

///|
test "zip central-directory parsing rejects malformed records" {
  let budget = SourceBudget(1000)
  let default_limits = ReadLimits::default()
  // Wrong central record signature.
  expect_zip_error(() => {
    ignore(
      parse_central_directory(
        b"\x00\x00\x00\x00",
        eocd_for(1, 4, 4),
        default_limits,
        budget,
        () => false,
      ),
    )
  })
  // Central record on a non-zero disk.
  let disk_record = central_record(1, 0, 0, 0x11111111U, 3, 3, b"a.txt", b"", 0)
  expect_zip_error(() => {
    ignore(
      parse_central_directory(
        disk_record,
        eocd_for(1, disk_record.length(), disk_record.length()),
        default_limits,
        budget,
        () => false,
      ),
    )
  })
  // ZIP64 size placeholders with no zip64 extra field.
  let max_int = MAX_U32.reinterpret_as_int()
  let missing_uncomp = central_record(
    0, 0, 0, 0x11111111U, 3, max_int, b"a.txt", b"", 0,
  )
  expect_zip_error(() => {
    ignore(
      parse_central_directory(
        missing_uncomp,
        eocd_for(1, missing_uncomp.length(), missing_uncomp.length()),
        default_limits,
        budget,
        () => false,
      ),
    )
  })
  let missing_comp = central_record(
    0, 0, 0, 0x11111111U, max_int, 3, b"a.txt", b"", 0,
  )
  expect_zip_error(() => {
    ignore(
      parse_central_directory(
        missing_comp,
        eocd_for(1, missing_comp.length(), missing_comp.length()),
        default_limits,
        budget,
        () => false,
      ),
    )
  })
  let missing_offset = central_record(
    0, 0, 0, 0x11111111U, 3, 3, b"a.txt", b"", max_int,
  )
  expect_zip_error(() => {
    ignore(
      parse_central_directory(
        missing_offset,
        eocd_for(1, missing_offset.length(), missing_offset.length()),
        default_limits,
        budget,
        () => false,
      ),
    )
  })
  // Central records end before the declared central size.
  let good_record = central_record(0, 0, 0, 0x11111111U, 3, 3, b"a.txt", b"", 0)
  expect_zip_error(() => {
    ignore(
      parse_central_directory(
        good_record,
        eocd_for(1, good_record.length() + 3, good_record.length()),
        default_limits,
        budget,
        () => false,
      ),
    )
  })
}

///|
test "zip entry decode rejects oversized and mismatched payloads" {
  let budget = SourceBudget(1000)
  // Stored entry larger than the per-entry limit.
  let big_store = local_record(
    0, 0, 0x11111111U, 10, 10, b"a.txt", b"", b"0123456789", b"",
  )
  expect_zip_kind(
    () => {
      ignore(
        decode_entry(
          big_store,
          { ..base_meta(), compressed_size: 10, uncompressed_size: 10, },
          100,
          ReadLimits::default().with_entry_limit(5),
          0,
          budget,
          () => false,
        ),
      )
    },
    LimitExceeded(EntryUncompressedBytes, 5, 10),
  )
  // Decoded size disagrees with the central directory.
  let size_mismatch = local_record(
    0, 0, 0x11111111U, 3, 5, b"a.txt", b"", b"abc", b"",
  )
  expect_zip_error(() => {
    ignore(
      decode_entry(
        size_mismatch,
        { ..base_meta(), compressed_size: 3, uncompressed_size: 5, },
        100,
        ReadLimits::default(),
        0,
        budget,
        () => false,
      ),
    )
  })
  // Entries together exceed the total uncompressed limit.
  let total_over = local_record(
    0, 0, 0x11111111U, 3, 3, b"a.txt", b"", b"abc", b"",
  )
  expect_zip_kind(
    () => {
      ignore(
        decode_entry(
          total_over,
          base_meta(),
          100,
          ReadLimits::default().with_total_limit(3),
          2,
          budget,
          () => false,
        ),
      )
    },
    LimitExceeded(TotalUncompressedBytes, 3, 5),
  )
}

///|
test "zip Output and field writers reject bad sizes" {
  expect_zip_error(() => Output::counting(None).grow(-1))
  expect_zip_error(() => Output::counting(None).write_u16(0x10000))
  assert_eq(Output::counting(None).finish(), b"")
}

///|
test "zip build_zip64_extra emits each field combination" {
  assert_eq(build_zip64_extra(uncomp=None, comp=None, offset=None), b"")
  assert_eq(
    build_zip64_extra(uncomp=Some(7), comp=None, offset=None).length(),
    12,
  )
  assert_eq(
    build_zip64_extra(uncomp=None, comp=Some(8), offset=None).length(),
    12,
  )
  assert_eq(
    build_zip64_extra(uncomp=None, comp=None, offset=Some(9)).length(),
    12,
  )
  assert_eq(
    build_zip64_extra(uncomp=Some(1), comp=Some(2), offset=Some(3)).length(),
    28,
  )
}

///|
test "zip force_zip64 emits zip64 local and central records" {
  let archive = Archive()
  archive.add("a.txt", b"payload", compression=Store, data_descriptor=true)
  let entry = archive.entries()[0]
  let name_bytes = entry_name_bytes(entry)
  let payload = prepare_payload(entry, 6, false)
  let local_out = Output::writing(None)
  write_local_record(local_out, entry, name_bytes, payload, true, true)
  // The non-descriptor zip64 size fields.
  let no_desc = Output::writing(None)
  write_local_record(no_desc, entry, name_bytes, payload, false, true)
  let central_out = Output::writing(None)
  write_central_record(
    central_out,
    entry,
    name_bytes,
    0,
    payload.compressed_size,
    true,
    true,
  )
  // A preserved central record with a zip64 offset patch.
  let template = central_record(0, 0, 0, 0, 1, 1, b"a.txt", b"", 0)
  let source : SourceRecord = {
    local_record: b"",
    central_record: template,
    central_zip64_offset_position: Some(38),
  }
  write_preserved_central_record(Output::writing(None), source, 0)
  // A malformed preserved central record is rejected.
  let bad_source : SourceRecord = {
    local_record: b"",
    central_record: b"bad template",
    central_zip64_offset_position: None,
  }
  expect_zip_error(() => {
    write_preserved_central_record(Output::writing(None), bad_source, 0)
  })
}

///|
fn zip64_end_record_bytes() -> Bytes {
  let buf : Array[Byte] = []
  push_u32le(buf, ZIP64_EOCD_SIG)
  push_u64le(buf, 44)
  push_u16le(buf, 45)
  push_u16le(buf, 45)
  push_u32le(buf, 0)
  push_u32le(buf, 0)
  push_u64le(buf, 1)
  push_u64le(buf, 1)
  push_u64le(buf, 0)
  push_u64le(buf, 0)
  bytes_of(buf)
}

///|
fn zip64_locator_bytes() -> Bytes {
  let buf : Array[Byte] = []
  push_u32le(buf, ZIP64_LOCATOR_SIG)
  push_u32le(buf, 0)
  push_u64le(buf, 0)
  push_u32le(buf, 1)
  bytes_of(buf)
}

///|
test "zip preserved-trailer writers reject malformed templates" {
  let out = Output::writing(None)
  let classic = classic_eocd(0, 0, 0, 0, 0, 0)
  expect_zip_error(() => {
    write_preserved_trailer(
      out,
      {
        classic_end_record: b"bad",
        zip64_end_record: None,
        zip64_locator: None,
      },
      0,
      0,
      0,
    )
  })
  expect_zip_error(() => {
    write_preserved_trailer(
      out,
      {
        classic_end_record: classic,
        zip64_end_record: Some(b"bad"),
        zip64_locator: None,
      },
      0,
      0,
      0,
    )
  })
  expect_zip_error(() => {
    write_preserved_trailer(
      out,
      {
        classic_end_record: classic,
        zip64_end_record: Some(zip64_end_record_bytes()),
        zip64_locator: None,
      },
      0,
      0,
      0,
    )
  })
  expect_zip_error(() => {
    write_preserved_trailer(
      out,
      {
        classic_end_record: classic,
        zip64_end_record: Some(zip64_end_record_bytes()),
        zip64_locator: Some(b"bad"),
      },
      0,
      0,
      0,
    )
  })
  expect_zip_error(() => {
    write_preserved_classic_end_record(out, b"bad", 0, 0, 0)
  })
  // A valid preserved zip64 trailer round-trips.
  write_preserved_trailer(
    out,
    {
      classic_end_record: classic_eocd(
        0, 0, 0xffff, 0xffff, 0xffffffff, 0xffffffff,
      ),
      zip64_end_record: Some(zip64_end_record_bytes()),
      zip64_locator: Some(zip64_locator_bytes()),
    },
    1,
    0,
    0,
  )
}

///|
test "zip retained_size_estimate counts zip64 trailer records" {
  let classic = classic_eocd(0, 0, 0xffff, 0xffff, 0xffffffff, 0xffffffff)
  let with_zip64 = Archive()
  with_zip64.add("a.txt", b"payload")
  with_zip64.trailer = Some({
    classic_end_record: classic,
    zip64_end_record: Some(zip64_end_record_bytes()),
    zip64_locator: Some(zip64_locator_bytes()),
  })
  let without_zip64 = Archive()
  without_zip64.add("a.txt", b"payload")
  without_zip64.trailer = Some({
    classic_end_record: classic,
    zip64_end_record: None,
    zip64_locator: None,
  })
  assert_true(
    with_zip64.retained_size_estimate() > without_zip64.retained_size_estimate(),
  )
  assert_true(with_zip64.retained_size_estimate() > 0L)
}

///|
test "zip classic trailer rejects too many entries and long comments" {
  let out = Output::writing(None)
  expect_zip_error(() => {
    write_generated_classic_end_record(out, false, 70000, 0, 0, b"")
  })
  let long_comment = Bytes::from_array(Array::make(70000, b'x'))
  expect_zip_error(() => {
    write_generated_classic_end_record(out, false, 1, 0, 0, long_comment)
  })
}

///|
test "zip entry names and output limits are checked" {
  let long_name = String::make(70000, 'x')
  let archive = Archive()
  archive.add(long_name, b"")
  expect_zip_error(() => ignore(write(archive)))
  let small = Archive()
  small.add("a.txt", b"x")
  expect_zip_error(() => ignore(write_limited(small, max_output_bytes=-1)))
  expect_zip_error(() => {
    ignore(write_preserving_limited(small, max_output_bytes=-1))
  })
  assert_eq(
    write_preserving_limited(small, max_output_bytes=1000),
    write(small),
  )
}

///|
test "zip local-order keeps a replaced entry in its original position" {
  let src = Archive()
  src.add("a.txt", b"x")
  src.add("b.txt", b"y")
  let archive = read(write(src))
  assert_eq(archive.replace("a.txt", b"xx"), true)
  let order = archive_local_order(archive)
  assert_eq(order.length(), 2)
  assert_eq(archive.entries()[order[0]].name(), "a.txt")
  assert_eq(archive.entries()[order[1]].name(), "b.txt")
}

///|
test "zip local-order sorts read-origin entries ahead of fresh ones" {
  let src = Archive()
  src.add("a.txt", b"x")
  src.add("b.txt", b"y")
  let archive = read(write(src))
  archive.add("fresh.txt", b"z")
  // Read-origin entries (origin Some) precede a fresh entry (origin None).
  let forward = archive_local_order(archive)
  assert_eq(forward.length(), 3)
  assert_eq(archive.entries()[forward[0]].name(), "a.txt")
  assert_eq(archive.entries()[forward[1]].name(), "b.txt")
  assert_eq(archive.entries()[forward[2]].name(), "fresh.txt")
  // Even when the fresh entry sits first in the array, it still sorts last.
  let mixed = {
    entries: [archive.entries[2], archive.entries[0], archive.entries[1]],
    comment: b"",
    trailer: None,
  }
  let reordered = archive_local_order(mixed)
  assert_eq(mixed.entries()[reordered[0]].name(), "a.txt")
  assert_eq(mixed.entries()[reordered[1]].name(), "b.txt")
  assert_eq(mixed.entries()[reordered[2]].name(), "fresh.txt")
}
