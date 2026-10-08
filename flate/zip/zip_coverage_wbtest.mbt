///|
/// Malformed records, numeric boundaries, and byte-preserving ZIP writes.

///|
fn expect_zip_error(f : () -> Unit raise ZipError) -> Unit raise {
  @test.assert_raise(f)
}

///|
fn expect_zip_kind(
  f : () -> Unit raise ZipError,
  expect : ZipErrorKind,
) -> Unit raise {
  let ZipError(kind, _) = @test.expect_error(f)
  @test.assert_eq(kind, expect)
}

///|
test "zip checked conversions reject out-of-range values" {
  expect_zip_error(() => ignore(0x80000000U.to_int_checked()))
}

///|
test "zip cursor and field readers reject truncated input" {
  expect_zip_error(() => ignore(Cursor(b"", 0).read_u8()))
  expect_zip_error(() => ignore(Cursor(b"", 0).read_bytes(1)))
  expect_zip_error(() => ignore(read_u16_le_at(b"", 0)))
  expect_zip_error(() => ignore(read_u32_le_at_raw(b"", 0)))
  expect_zip_error(() => ignore(read_u64_le_at(b"", 0)))
  @test.assert_eq(find_end_of_central(b"too short"), None)
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
    name_len: 0,
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
  @test.assert_eq(
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
  @test.assert_eq(
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
  @test.assert_eq(
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
    name_len: 0,
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
    name_len: 5,
    flags: 0,
    method_id: 0,
    crc: 0x11111111U,
    compressed_size: 3,
    uncompressed_size: 3,
    local_offset: 0,
    central_record: central_record(0, 0, 0, 0x11111111U, 3, 3, b"a.txt", b"", 0),
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
    InvalidDeflate,
  )
  let comp = @flate.deflate_all(b"0123456789")
  expect_zip_kind(
    () => ignore(inflate_entry(comp, 5, EntryUncompressedBytes, 5, () => false)),
    LimitExceeded(EntryUncompressedBytes, 5, 5),
  )
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
  let default_limits = ReadLimits()
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
  @test.assert_eq(eocd.entry_count, 3)
  @test.assert_eq(eocd.central_size, 0)
  @test.assert_eq(eocd.central_offset, 0)
  // Classic fields that mirror the zip64 values still resolve through the
  // zip64 record (only the disk count is sentinel to select the zip64 path).
  let eocd2 = parse_end_of_central(
    zip64_trailer(5, 0, 0, 0xFFFF, 5, 0, 0),
    default_limits,
    () => false,
  )
  @test.assert_eq(eocd2.entry_count, 5)
  @test.assert_eq(eocd2.central_size, 0)
  @test.assert_eq(eocd2.central_offset, 0)
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
  let default_limits = ReadLimits()
  // Wrong central record signature.
  expect_zip_error(() => {
    ignore(
      parse_central_directory(
        b"\x00\x00\x00\x00",
        eocd_for(1, 4, 4),
        default_limits,
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
        () => false,
      ),
    )
  })
}

///|
test "zip entry decode rejects oversized and mismatched payloads" {
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
          ReadLimits(max_entry_uncompressed_bytes=5),
          0,
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
        ReadLimits(),
        0,
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
          ReadLimits(max_total_uncompressed_bytes=3),
          2,
          () => false,
        ),
      )
    },
    LimitExceeded(TotalUncompressedBytes, 3, 5),
  )
}

///|
test "zip classic trailer rejects too many entries and long comments" {
  let out = Output::writing(None)
  expect_zip_error(() => {
    out.write_generated_classic_end_record(false, 70000, 0, 0, b"")
  })
  let long_comment = Bytes::from_array(Array::make(70000, b'x'))
  expect_zip_error(() => {
    out.write_generated_classic_end_record(false, 1, 0, 0, long_comment)
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
  expect_zip_error(() => ignore(write(small, max_output_bytes=-1)))
  expect_zip_error(() => {
    ignore(write(small, max_output_bytes=-1, preserve=true))
  })
  @test.assert_eq(
    write(small, max_output_bytes=1000, preserve=true),
    write(small),
  )
}

///|
test "zip local-order keeps a replaced entry in its original position" {
  let src = Archive()
  src.add("a.txt", b"x")
  src.add("b.txt", b"y")
  let archive = read(write(src))
  @test.assert_eq(archive.replace("a.txt", b"xx"), true)
  let order = archive.local_order()
  @test.assert_eq(order.length(), 2)
  @test.assert_eq(archive.entries()[order[0]].name(), "a.txt")
  @test.assert_eq(archive.entries()[order[1]].name(), "b.txt")
}

///|
test "zip local-order sorts read-origin entries ahead of fresh ones" {
  let src = Archive()
  src.add("a.txt", b"x")
  src.add("b.txt", b"y")
  let archive = read(write(src))
  archive.add("fresh.txt", b"z")
  // Read-origin entries (origin Some) precede a fresh entry (origin None).
  let forward = archive.local_order()
  @test.assert_eq(forward.length(), 3)
  @test.assert_eq(archive.entries()[forward[0]].name(), "a.txt")
  @test.assert_eq(archive.entries()[forward[1]].name(), "b.txt")
  @test.assert_eq(archive.entries()[forward[2]].name(), "fresh.txt")
  // Even when the fresh entry sits first in the array, it still sorts last.
  let mixed = {
    entries: [archive.entries[2], archive.entries[0], archive.entries[1]],
    comment: b"",
    trailer: None,
    original: None,
  }
  let reordered = mixed.local_order()
  @test.assert_eq(mixed.entries()[reordered[0]].name(), "a.txt")
  @test.assert_eq(mixed.entries()[reordered[1]].name(), "b.txt")
  @test.assert_eq(mixed.entries()[reordered[2]].name(), "fresh.txt")
}

///|
test "zip owned copy handles chunk boundaries and cancellation" {
  for length in [0, 1, 65535, 65536, 65537, 131073] {
    let source = Bytes::makei(length + 2, i => (i % 251).to_byte())
    let mut polls = 0
    let copied = copy_cancellable(source[1:length + 1], () => {
      polls += 1
      false
    })
    @test.assert_eq(copied, source[1:length + 1].to_owned())
    let expected_polls = 2 + (length + 65535) / 65536
    @test.assert_eq(polls, expected_polls)
    for cancel_at in 1..<(expected_polls + 1) {
      let mut calls = 0
      expect_zip_kind(
        () => {
          ignore(
            copy_cancellable(source[1:length + 1], () => {
              calls += 1
              calls == cancel_at
            }),
          )
        },
        Cancelled,
      )
      @test.assert_eq(calls, cancel_at)
    }
  }
}

///|
test "zip output writes unaligned fields and transfers only written bytes" {
  let expected = b"\xff\x34\x12\x78\x56\x34\x12\x08\x07\x06\x05\x04\x03\x02\x01"
  for capacity in [0, 1, 15, 64] {
    let out = Output::writing(Some(15), size_hint=capacity)
    out.write_bytes(b"\xff")
    out.write_u16(0x1234)
    out.write_u32(0x12345678)
    out.write_u64(0x0102030405060708)
    expect_zip_kind(
      () => out.write_bytes(b"x"),
      LimitExceeded(OutputBytes, 15, 16),
    )
    @test.assert_eq(out.finish(), expected)
  }
}

///|
test "zip matching raw names preserve empty and Unicode names" {
  for name in ["", "a.txt", "目录/🙂.txt", "é.txt", "é.txt"] {
    let archive = Archive()
    archive.add(name, b"payload", compression=Store)
    let encoded = write(archive)
    let decoded = read(encoded)
    @test.assert_eq(decoded.entries()[0].name(), name)
    @test.assert_eq(decoded.entries()[0].data().to_owned(), b"payload")
    @test.assert_eq(write(decoded, preserve=true), encoded)
  }
}

///|
test "zip local name mismatch preserves UTF-8 error classification" {
  for name in [b"b.txt", b"a", b"a.txtx", b"", b"\xc3\xa9.txt"] {
    let local_bytes = local_record(
      0, 0, 0x11111111U, 3, 3, name, b"", b"abc", b"",
    )
    expect_zip_kind(
      () => {
        ignore(
          read_local_record(local_bytes, base_meta(), local_bytes.length()),
        )
      },
      UnsupportedFeature,
    )
  }
  for name in [b"\xff.txt", b"\xc0\xaf", b"\xed\xa0\x80", b"\xe2\x82"] {
    let local_bytes = local_record(
      0, 0, 0x11111111U, 3, 3, name, b"", b"abc", b"",
    )
    expect_zip_kind(
      () => {
        ignore(
          read_local_record(local_bytes, base_meta(), local_bytes.length()),
        )
      },
      InvalidUtf8,
    )
    // Even identical invalid raw names must fail central-directory decoding.
    let central = central_record(0, 0, 0, 0x11111111U, 3, 3, name, b"", 0)
    expect_zip_kind(
      () => ignore(parse_central_record(central, Cursor(central, 0))),
      InvalidUtf8,
    )
  }
}

///|
test "zip output rejects Int overflow and oversized raw header names" {
  let counting = Output::counting(None)
  counting.count(0x7fff_ffff)
  expect_zip_kind(() => counting.count(1), UnsupportedFeature)
  let archive = Archive()
  archive.add("a", b"", compression=Store)
  let entry = archive.entries()[0]
  let long_name = Bytes::make(65536, b'x')
  expect_zip_kind(
    () => {
      Output::writing(None).write_local_record(
        entry,
        long_name,
        { compressed_size: 0, compressed: None, },
        false,
        false,
      )
    },
    UnsupportedFeature,
  )
  expect_zip_kind(
    () => {
      Output::writing(None).write_central_record(
        entry, long_name, 0, 0, false, false,
      )
    },
    UnsupportedFeature,
  )
  expect_zip_kind(
    () => ignore(write(archive, max_output_bytes=1)),
    LimitExceeded(OutputBytes, 1, 31),
  )
}

///|
test "zip local order sorts source offsets and keeps new entries stable" {
  let archive = Archive()
  for i in 0..<32 {
    archive.add("entry-\{i}", b"", compression=Store)
    if i % 3 == 0 {
      archive.entries[i] = {
        ..archive.entries[i],
        origin_local_offset: Some((31 - i) * 10),
      }
    }
  }
  let order = archive.local_order()
  for i in 0..<11 {
    @test.assert_eq(order[i], 30 - i * 3)
  }
  let mut next = 11
  for i in 0..<32 {
    if i % 3 != 0 {
      @test.assert_eq(order[next], i)
      next += 1
    }
  }
}

///|
test "ZIP64 sizing agrees with emitted headers and descriptors" {
  let archive = Archive()
  archive.add("a", b"", compression=Store)
  let entry = archive.entries()[0]
  let counting = Output::counting(None)
  let output = Output::writing(None)
  for out in [counting, output] {
    out.write_local_record(
      entry,
      b"a",
      { compressed_size: 0, compressed: None, },
      true,
      true,
    )
    out.write_central_record(entry, b"a", 0, 0, true, true)
  }
  let bytes = output.finish()
  @test.assert_eq(counting.size, bytes.length())
  @test.assert_eq(bytes.length(), 150)
  @test.assert_eq(read_u32_le_at_raw(bytes, 51), DATA_DESCRIPTOR_SIG)
  @test.assert_eq(read_u32_le_at_raw(bytes, 75), CENTRAL_HEADER_SIG)
  @test.assert_eq(read_u16_le_at(bytes, 105), 28)
}

///|
/// Moved from the checksum package: cancellation belongs to the ZIP driver.
test "CRC-32 computation honours ZIP cancellation" {
  inspect(crc32_cancellable(b"", cancelled=() => false), content="0")
  let data = Bytes::make(16 * 1024, b'x')
  @test.assert_eq(
    crc32_cancellable(data, cancelled=() => false),
    @checksum.crc32(data),
  )
  let mut polls = 0
  let ZipError(kind, _) = @test.expect_error(() => {
    crc32_cancellable(data, cancelled=() => {
      polls += 1
      polls >= 4
    })
  })
  @test.assert_eq(kind, Cancelled)
  assert_true(polls >= 4)
}

///|
/// Cancellation cases moved from the former combined checksum property.
test "property: ZIP checksum cancellation includes the last poll" {
  @quickcheck.check(
    (data : Bytes) => {
      guard crc32_cancellable(data, cancelled=() => false) ==
        @checksum.crc32(data) else {
        return false
      }
      let ZipError(kind, _) = @test.expect_error(() => {
        crc32_cancellable(data, cancelled=() => true)
      })
      guard kind is Cancelled else { return false }
      let total_polls = 2 + (data.length() - 1) / 4096
      let mut polls = 0
      let ZipError(kind, _) = @test.expect_error(() => {
        crc32_cancellable(data, cancelled=() => {
          polls += 1
          polls >= total_polls
        })
      })
      kind is Cancelled
    },
    count=60,
    max_size=2000,
    seed=0xC0C11E,
  )
}
