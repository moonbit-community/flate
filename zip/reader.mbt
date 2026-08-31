///|
/// The ZIP reader: central-directory parsing, local-record validation, bounded
/// materialization of every entry, and the raw source records retained for
/// byte-preserving rewrites.

///|
priv struct EntryMeta {
  name : String
  flags : Int
  method_id : Int
  crc : UInt
  compressed_size : Int
  uncompressed_size : Int
  local_offset : Int
  central_record : Bytes
  central_zip64_offset_position : Int?
  data_descriptor : Bool
}

///|
/// The parsed local header region of one entry, with the byte range of its
/// payload plus its (optional) data descriptor.
priv struct LocalRecord {
  compressed : BytesView
  end : Int
}

///|
fn read_local_record(
  bytes : BytesView,
  meta : EntryMeta,
  central_offset : Int,
) -> LocalRecord raise ZipError {
  guard meta.local_offset >= 0 && meta.local_offset < central_offset else {
    raise ZipError(Truncated, "zip: local header offset out of bounds")
  }
  let reader = Cursor(bytes, meta.local_offset)
  guard reader.read_u32_raw() == LOCAL_HEADER_SIG else {
    raise ZipError(InvalidSignature, "zip: invalid local header signature")
  }
  ignore(reader.read_u16())
  let flags = reader.read_u16()
  ensure_flags_supported(flags)
  guard flags == meta.flags else {
    raise ZipError(UnsupportedFeature, "zip: local and central flags differ")
  }
  let method_id = reader.read_u16()
  guard method_id == meta.method_id else {
    raise ZipError(UnsupportedFeature, "zip: local and central methods differ")
  }
  ignore(reader.read_u16())
  ignore(reader.read_u16())
  let local_crc = reader.read_u32_raw()
  let comp_size_raw = reader.read_u32_raw()
  let uncomp_size_raw = reader.read_u32_raw()
  let name_len = reader.read_u16()
  let extra_len = reader.read_u16()
  let local_name = reader.read_bytes(name_len)
  let local_extra = reader.read_bytes(extra_len)
  guard decode_name(local_name) == meta.name else {
    raise ZipError(UnsupportedFeature, "zip: local and central names differ")
  }
  let has_descriptor = (flags & FLAG_DATA_DESCRIPTOR) != 0
  let need_local_uncomp = uncomp_size_raw == MAX_U32
  let need_local_comp = comp_size_raw == MAX_U32
  let (local_zip_uncomp, local_zip_comp, _, _) = read_zip64_extra(
    local_extra, need_local_uncomp, need_local_comp, false,
  )
  guard local_crc == meta.crc || (has_descriptor && local_crc == 0) else {
    raise ZipError(UnsupportedFeature, "zip: local and central CRC-32 differ")
  }
  guard local_size_matches(
      comp_size_raw,
      local_zip_comp,
      meta.compressed_size,
      has_descriptor,
    ) &&
    local_size_matches(
      uncomp_size_raw,
      local_zip_uncomp,
      meta.uncompressed_size,
      has_descriptor,
    ) else {
    raise ZipError(UnsupportedFeature, "zip: local and central sizes differ")
  }
  guard reader.pos <= central_offset &&
    meta.compressed_size <= central_offset - reader.pos else {
    raise ZipError(Truncated, "zip: compressed payload out of bounds")
  }
  let compressed = reader.read_bytes(meta.compressed_size)
  let end = if has_descriptor {
    // The descriptor's sizes are 64-bit iff the local header declared its
    // sizes through the ZIP64 extra field (0xffffffff placeholders).
    let zip64 = need_local_uncomp || need_local_comp
    let end = reader.pos + data_descriptor_size(bytes, reader.pos, meta, zip64)
    guard end <= central_offset else {
      raise ZipError(Truncated, "zip: data descriptor out of bounds")
    }
    end
  } else {
    reader.pos
  }
  { compressed, end, }
}

///|
fn check_sizes(
  uncompressed_size : Int,
  entry_limit : Int,
  total_limit : Int,
  used_total : Int,
) -> Unit raise ZipError {
  guard uncompressed_size <= entry_limit else {
    raise ZipError(
      LimitExceeded(EntryUncompressedBytes, entry_limit, uncompressed_size),
      "zip: entry exceeds the per-entry uncompressed limit",
    )
  }
  guard used_total >= 0 && uncompressed_size <= total_limit - used_total else {
    raise ZipError(
      LimitExceeded(
        TotalUncompressedBytes,
        total_limit,
        (used_total + uncompressed_size).min(0x7fff_ffff),
      ),
      "zip: entries exceed the total uncompressed limit",
    )
  }
}

///|
fn inflate_entry(
  compressed : BytesView,
  max_output : Int,
  limit_kind : LimitKind,
  reported_limit : Int,
  cancelled : () -> Bool,
) -> Bytes raise ZipError {
  let decoded = try
    @flate.inflate_exact(
      compressed.to_owned(),
      max_output=Some(max_output),
      cancelled~,
      preallocated=true,
    )
  catch {
    InflateError(OutputLimitExceeded, _) =>
      raise ZipError(
        LimitExceeded(limit_kind, reported_limit, max_output),
        "zip: decompressed size limit exceeded",
      )
    err => raise wrap_inflate_error(err)
  } noraise {
    decoded => decoded
  }
  decoded
}

///|
/// Tracks the raw source records retained for byte-preserving rewrites against
/// a caller-supplied ceiling.
priv struct SourceBudget {
  limit : Int
  mut used : Int
}

///|
fn SourceBudget::SourceBudget(limit : Int) -> SourceBudget {
  { limit, used: 0, }
}

///|
fn SourceBudget::charge(
  self : SourceBudget,
  amount : Int,
) -> Unit raise ZipError {
  guard amount >= 0 else {
    raise ZipError(UnsupportedFeature, "zip: negative preserved source size")
  }
  guard amount <= self.limit - self.used else {
    raise ZipError(
      LimitExceeded(
        PreservedSourceBytes,
        self.limit,
        (self.used + amount).min(0x7fff_ffff),
      ),
      "zip: preserved source records exceed their limit",
    )
  }
  self.used = self.used + amount
}

///|
/// The parsed end-of-central-directory header: the central directory's bounds,
/// the classic EOCD position, the optional ZIP64 EOCD position, and the archive
/// comment.
priv struct EndOfCentral {
  eocd_offset : Int
  entry_count : Int
  central_size : Int
  central_offset : Int
  central_boundary : Int
  zip64_eocd_offset : Int?
  comment : Bytes
}

///|
/// Resolve the ZIP64 end-of-central-directory fields for a classic EOCD whose
/// entry count or central size/offset spilled into the ZIP64 sentinels.
/// Returns (entry_count, central_size, central_offset, zip64_eocd_offset).
fn zip64_central_bounds(
  bytes : BytesView,
  eocd_offset : Int,
  disk_entries : Int,
  total_entries : Int,
  central_size_raw : UInt,
  central_offset_raw : UInt,
) -> (Int, Int, Int, Int) raise ZipError {
  let (zip_entries, zip_size, zip_offset, zip64_offset) = read_zip64_eocd(
    bytes, eocd_offset,
  )
  guard disk_entries == 0xFFFF || disk_entries.to_uint64() == zip_entries else {
    raise ZipError(
      UnsupportedFeature,
      "zip: classic and zip64 entry counts differ",
    )
  }
  guard total_entries == 0xFFFF || total_entries.to_uint64() == zip_entries else {
    raise ZipError(
      UnsupportedFeature,
      "zip: classic and zip64 entry counts differ",
    )
  }
  guard central_size_raw == MAX_U32 ||
    UInt64::extend_uint(central_size_raw) == zip_size else {
    raise ZipError(
      UnsupportedFeature,
      "zip: classic and zip64 central sizes differ",
    )
  }
  guard central_offset_raw == MAX_U32 ||
    UInt64::extend_uint(central_offset_raw) == zip_offset else {
    raise ZipError(
      UnsupportedFeature,
      "zip: classic and zip64 central offsets differ",
    )
  }
  let entry_count = (if total_entries == 0xFFFF {
    zip_entries
  } else {
    total_entries.to_uint64()
  }).to_int_checked()
  let central_size = (if central_size_raw == MAX_U32 {
    zip_size
  } else {
    UInt64::extend_uint(central_size_raw)
  }).to_int_checked()
  let central_offset = (if central_offset_raw == MAX_U32 {
    zip_offset
  } else {
    UInt64::extend_uint(central_offset_raw)
  }).to_int_checked()
  (entry_count, central_size, central_offset, zip64_offset)
}

///|
/// Enforce the entry-count and central-bounds limits and assemble the parsed
/// end-of-central-directory record.
fn validate_central_bounds(
  bytes : BytesView,
  limits : ReadLimits,
  eocd_offset : Int,
  entry_count : Int,
  central_size : Int,
  central_offset : Int,
  central_boundary : Int,
  zip64_eocd_offset : Int?,
  comment : Bytes,
) -> EndOfCentral raise ZipError {
  guard entry_count >= 0 else {
    raise ZipError(Truncated, "zip: central directory out of bounds")
  }
  guard entry_count <= limits.max_entries else {
    raise ZipError(
      LimitExceeded(Entries, limits.max_entries, entry_count),
      "zip: entry count exceeds its limit",
    )
  }
  guard central_offset <= central_boundary &&
    central_boundary <= bytes.length() &&
    central_size == central_boundary - central_offset else {
    raise ZipError(Truncated, "zip: central directory out of bounds")
  }
  {
    eocd_offset,
    entry_count,
    central_size,
    central_offset,
    central_boundary,
    zip64_eocd_offset,
    comment,
  }
}

///|
/// Locate and validate the end-of-central-directory record (and the ZIP64 EOCD
/// it points at), enforcing the package size, entry count, and central-bounds
/// limits. Returns the parsed bounds for the central-directory phase.
fn parse_end_of_central(
  bytes : BytesView,
  limits : ReadLimits,
  cancelled : () -> Bool,
) -> EndOfCentral raise ZipError {
  check_cancelled(cancelled)
  guard bytes.length() <= limits.max_package_bytes else {
    raise ZipError(
      LimitExceeded(PackageBytes, limits.max_package_bytes, bytes.length()),
      "zip: package exceeds the input size limit",
    )
  }
  guard find_end_of_central(bytes) is Some(eocd_offset) else {
    raise ZipError(
      MissingEndOfCentral,
      "zip: end of central directory not found",
    )
  }
  let reader = Cursor(bytes, eocd_offset)
  ignore(reader.read_u32_raw())
  let disk_no = reader.read_u16()
  let disk_start = reader.read_u16()
  let disk_entries = reader.read_u16()
  let total_entries = reader.read_u16()
  let central_size_raw = reader.read_u32_raw()
  let central_offset_raw = reader.read_u32_raw()
  let comment_len = reader.read_u16()
  guard disk_no == 0 && disk_start == 0 else {
    raise ZipError(
      UnsupportedFeature,
      "zip: multi-disk archives are not supported",
    )
  }
  let comment = copy_cancellable(reader.read_bytes(comment_len), cancelled)
  let needs_zip64 = disk_entries == 0xFFFF ||
    total_entries == 0xFFFF ||
    central_size_raw == MAX_U32 ||
    central_offset_raw == MAX_U32
  guard !needs_zip64 else {
    let (entry_count, central_size, central_offset, zip64_offset) = zip64_central_bounds(
      bytes, eocd_offset, disk_entries, total_entries, central_size_raw, central_offset_raw,
    )
    return validate_central_bounds(
      bytes,
      limits,
      eocd_offset,
      entry_count,
      central_size,
      central_offset,
      zip64_offset,
      Some(zip64_offset),
      comment,
    )
  }
  guard disk_entries == total_entries else {
    raise ZipError(
      UnsupportedFeature,
      "zip: multi-disk archives are not supported",
    )
  }
  validate_central_bounds(
    bytes,
    limits,
    eocd_offset,
    total_entries,
    central_size_raw.to_int_checked(),
    central_offset_raw.to_int_checked(),
    eocd_offset,
    None,
    comment,
  )
}

///|
/// Resolve a central-directory 32-bit field that may spill into a ZIP64 extra
/// entry: the classic field carries the `MAX_U32` sentinel when ZIP64 is in
/// use. `read_zip64_extra` guarantees a ZIP64 value whenever `need` is true (it
/// raises when the field is absent or mis-sized), so `unwrap` is safe there.
fn resolve_zip64_field(
  need : Bool,
  zip64_value : UInt64?,
  classic_raw : UInt,
) -> Int raise ZipError {
  guard need else { return classic_raw.to_int_checked() }
  zip64_value.unwrap().to_int_checked()
}

///|
/// Parse one central-directory record into `EntryMeta`, enforcing the
/// preserved-source ceiling.
fn parse_central_record(
  central_bytes : BytesView,
  central_reader : Cursor,
  source_budget : SourceBudget,
  cancelled : () -> Bool,
) -> EntryMeta raise ZipError {
  let central_record_start = central_reader.pos
  guard central_reader.read_u32_raw() == CENTRAL_HEADER_SIG else {
    raise ZipError(InvalidSignature, "zip: invalid central directory signature")
  }
  ignore(central_reader.read_u16())
  ignore(central_reader.read_u16())
  let flags = central_reader.read_u16()
  ensure_flags_supported(flags)
  let method_id = central_reader.read_u16()
  ignore(central_reader.read_u16())
  ignore(central_reader.read_u16())
  let crc = central_reader.read_u32_raw()
  let comp_size_raw = central_reader.read_u32_raw()
  let uncomp_size_raw = central_reader.read_u32_raw()
  let name_len = central_reader.read_u16()
  let extra_len = central_reader.read_u16()
  let comment_len = central_reader.read_u16()
  let disk = central_reader.read_u16()
  ignore(central_reader.read_u16())
  ignore(central_reader.read_u32_raw())
  let local_offset_raw = central_reader.read_u32_raw()
  let name_bytes = central_reader.read_bytes(name_len)
  let extra_bytes = central_reader.read_bytes(extra_len)
  let name = decode_name(name_bytes)
  central_reader.skip(comment_len)
  guard disk == 0 else {
    raise ZipError(
      UnsupportedFeature,
      "zip: multi-disk archives are not supported",
    )
  }
  source_budget.charge(central_reader.pos - central_record_start)
  let central_record = copy_cancellable(
    central_bytes[central_record_start:central_reader.pos],
    cancelled,
  )
  let need_uncomp = uncomp_size_raw == MAX_U32
  let need_comp = comp_size_raw == MAX_U32
  let need_offset = local_offset_raw == MAX_U32
  let (zip_uncomp, zip_comp, zip_offset, offset_position) = read_zip64_extra(
    extra_bytes, need_uncomp, need_comp, need_offset,
  )
  let uncompressed_size = resolve_zip64_field(
    need_uncomp, zip_uncomp, uncomp_size_raw,
  )
  let compressed_size = resolve_zip64_field(need_comp, zip_comp, comp_size_raw)
  let local_offset = resolve_zip64_field(
    need_offset, zip_offset, local_offset_raw,
  )
  let central_zip64_offset_position = offset_position.map(position => {
    46 + name_len + position
  })
  {
    name,
    flags,
    method_id,
    crc,
    compressed_size,
    uncompressed_size,
    local_offset,
    central_record,
    central_zip64_offset_position,
    data_descriptor: (flags & FLAG_DATA_DESCRIPTOR) != 0,
  }
}

///|
/// Parse every central-directory record into `EntryMeta`, enforcing the entry
/// count and preserved-source ceilings.
fn parse_central_directory(
  bytes : BytesView,
  eocd : EndOfCentral,
  limits : ReadLimits,
  source_budget : SourceBudget,
  cancelled : () -> Bool,
) -> Array[EntryMeta] raise ZipError {
  let central_bytes = bytes[eocd.central_offset:eocd.central_boundary]
  let central_reader = Cursor(central_bytes, 0)
  let max_plausible = eocd.central_size / 46
  let metas : Array[EntryMeta] = Array::new(
    capacity=eocd.entry_count.min(max_plausible),
  )
  let mut used_total = 0
  for entry_index in 0..<eocd.entry_count {
    if entry_index % 64 == 0 {
      check_cancelled(cancelled)
    }
    let meta = parse_central_record(
      central_bytes, central_reader, source_budget, cancelled,
    )
    check_sizes(
      meta.uncompressed_size,
      limits.max_entry_uncompressed_bytes,
      limits.max_total_uncompressed_bytes,
      used_total,
    )
    used_total = used_total + meta.uncompressed_size
    metas.push(meta)
  }
  guard central_reader.pos == eocd.central_size else {
    raise ZipError(
      UnsupportedFeature,
      "zip: central directory size/count mismatch",
    )
  }
  metas
}

///|
/// Capture the raw end-of-archive records (classic EOCD plus any ZIP64 EOCD and
/// locator) for byte-preserving rewrites, charging the preserved-source budget.
fn build_trailer(
  bytes : BytesView,
  eocd : EndOfCentral,
  source_budget : SourceBudget,
  cancelled : () -> Bool,
) -> TrailerTemplate raise ZipError {
  guard eocd.zip64_eocd_offset is Some(zip64_offset) else {
    source_budget.charge(bytes.length() - eocd.eocd_offset)
    return {
      classic_end_record: copy_cancellable(bytes[eocd.eocd_offset:], cancelled),
      zip64_end_record: None,
      zip64_locator: None,
    }
  }
  let locator_offset = eocd.eocd_offset - 20
  source_budget.charge(
    locator_offset - zip64_offset + 20 + (bytes.length() - eocd.eocd_offset),
  )
  {
    classic_end_record: copy_cancellable(bytes[eocd.eocd_offset:], cancelled),
    zip64_end_record: Some(
      copy_cancellable(bytes[zip64_offset:locator_offset], cancelled),
    ),
    zip64_locator: Some(
      copy_cancellable(bytes[locator_offset:eocd.eocd_offset], cancelled),
    ),
  }
}

///|
/// Materialize one entry: validate its local record against the central
/// metadata, decompress or copy its payload under the caller's limits, and
/// retain the raw source records for byte-preserving rewrites.
fn decode_entry(
  bytes : BytesView,
  meta : EntryMeta,
  central_offset : Int,
  limits : ReadLimits,
  actual_total : Int,
  source_budget : SourceBudget,
  cancelled : () -> Bool,
) -> Entry raise ZipError {
  check_cancelled(cancelled)
  let record = read_local_record(bytes, meta, central_offset)
  source_budget.charge(record.end - meta.local_offset)
  let entry_limit = limits.max_entry_uncompressed_bytes
  let total_limit = limits.max_total_uncompressed_bytes
  let remaining = total_limit - actual_total
  let (effective_cap, limit_kind, reported_limit) = if remaining < entry_limit {
    (remaining, TotalUncompressedBytes, total_limit)
  } else {
    (entry_limit, EntryUncompressedBytes, entry_limit)
  }
  let compression = method_from_code(meta.method_id)
  let data = {
    guard !(record.compressed.length() == 0 && meta.uncompressed_size == 0) else {
      b""
    }
    match compression {
      Store => {
        guard record.compressed.length() <= entry_limit else {
          raise ZipError(
            LimitExceeded(
              EntryUncompressedBytes,
              entry_limit,
              record.compressed.length(),
            ),
            "zip: stored entry exceeds its limit",
          )
        }
        copy_cancellable(record.compressed, cancelled)
      }
      Deflate =>
        inflate_entry(
          record.compressed,
          effective_cap,
          limit_kind,
          reported_limit,
          cancelled,
        )
    }
  }
  guard data.length() == meta.uncompressed_size else {
    raise ZipError(
      UnsupportedFeature,
      "zip: decoded size does not match central directory",
    )
  }
  guard data.length() <= total_limit - actual_total else {
    raise ZipError(
      LimitExceeded(
        TotalUncompressedBytes,
        total_limit,
        (actual_total + data.length()).min(0x7fff_ffff),
      ),
      "zip: entries exceed the total uncompressed limit",
    )
  }
  let source = Some({
    local_record: copy_cancellable(
      bytes[meta.local_offset:record.end],
      cancelled,
    ),
    central_record: meta.central_record,
    central_zip64_offset_position: meta.central_zip64_offset_position,
    local_offset: meta.local_offset,
  })
  {
    name: meta.name,
    data,
    compression,
    crc32: meta.crc,
    data_descriptor: meta.data_descriptor,
    compressed_size: meta.compressed_size,
    source,
  }
}

///|
fn read_impl(
  bytes : BytesView,
  limits : ReadLimits,
  cancelled : () -> Bool,
) -> Archive raise ZipError {
  let eocd = parse_end_of_central(bytes, limits, cancelled)
  let source_budget = SourceBudget(limits.max_preserved_source_bytes)
  let metas = parse_central_directory(
    bytes, eocd, limits, source_budget, cancelled,
  )
  let archive = {
    entries: [],
    comment: eocd.comment,
    trailer: Some(build_trailer(bytes, eocd, source_budget, cancelled)),
  }
  let mut actual_total = 0
  for meta in metas {
    let entry = decode_entry(
      bytes,
      meta,
      eocd.central_offset,
      limits,
      actual_total,
      source_budget,
      cancelled,
    )
    actual_total = actual_total + entry.data().length()
    archive.entries.push(entry)
  }
  check_cancelled(cancelled)
  archive
}

///|
/// Read a ZIP archive from `bytes`, decoding every entry. `limits` bounds the
/// package size, entry count, per-entry and total decompressed bytes, and the
/// source records retained for byte-preserving rewrites; `cancelled` is polled
/// across parsing and decoding. Each entry exposes the central directory's
/// stored CRC-32 via `Entry::crc32`; it is not verified during this read —
/// callers that need integrity checking compare it against
/// `@checksum.crc32(entry.data())`. Failures carry a stable `ZipErrorKind`
/// plus a diagnostic.
pub fn read(
  bytes : BytesView,
  limits? : ReadLimits = ReadLimits::default(),
  cancelled? : () -> Bool = () => false,
) -> Archive raise ZipError {
  read_impl(bytes, limits, cancelled)
}
