///|
/// A byte sink that either counts (sizing pass) or writes into a growable
/// buffer (emit pass), while enforcing an optional output ceiling.
priv struct Output {
  limit : Int?
  buf : Buffer?
  mut size : Int
}

///|
fn Output::counting(limit : Int?) -> Output {
  { limit, buf: None, size: 0, }
}

///|
fn Output::writing(limit : Int?) -> Output {
  { limit, buf: Some(Buffer()), size: 0, }
}

///|
fn Output::is_counting(self : Output) -> Bool {
  self.buf is None
}

///|
fn Output::grow(self : Output, additional : Int) -> Unit raise ZipError {
  if additional < 0 {
    raise ZipError(UnsupportedFeature, "zip: negative output size")
  }
  if self.limit is Some(limit) && additional > limit - self.size {
    raise ZipError(
      LimitExceeded(OutputBytes, limit, self.size + additional),
      "zip: output exceeds its byte limit",
    )
  }
  self.size = self.size + additional
}

///|
fn Output::write_byte(self : Output, b : Byte) -> Unit raise ZipError {
  self.grow(1)
  if self.buf is Some(buf) {
    buf.write_byte(b)
  }
}

///|
fn Output::write_bytes(self : Output, bytes : BytesView) -> Unit raise ZipError {
  self.grow(bytes.length())
  if self.buf is Some(buf) {
    buf.write_bytes(bytes)
  }
}

///|
/// Counts `n` payload bytes without materializing them (used by the sizing pass
/// for DEFLATE payloads whose compressed bytes are not held).
fn Output::count(self : Output, n : Int) -> Unit raise ZipError {
  self.grow(n)
}

///|
fn Output::write_u16(self : Output, value : Int) -> Unit raise ZipError {
  if value < 0 || value > 0xffff {
    raise ZipError(UnsupportedFeature, "zip: u16 overflow")
  }
  let raw = value.to_uint_checked()
  self.write_byte((raw & 0xff).to_byte())
  self.write_byte(((raw >> 8) & 0xff).to_byte())
}

///|
fn Output::write_u32(self : Output, value : UInt) -> Unit raise ZipError {
  self.write_byte((value & 0xff).to_byte())
  self.write_byte(((value >> 8) & 0xff).to_byte())
  self.write_byte(((value >> 16) & 0xff).to_byte())
  self.write_byte(((value >> 24) & 0xff).to_byte())
}

///|
fn Output::write_u64(self : Output, value : UInt64) -> Unit raise ZipError {
  for index in 0..<8 {
    self.write_byte(((value >> (8 * index)) & 0xff).to_byte())
  }
}

///|
fn Output::finish(self : Output) -> Bytes {
  if self.buf is Some(buf) {
    buf.to_bytes()
  } else {
    b""
  }
}

///|
fn write_u16_buf(buf : Buffer, value : Int) -> Unit raise ZipError {
  let raw = value.to_uint_checked()
  buf.write_byte((raw & 0xff).to_byte())
  buf.write_byte(((raw >> 8) & 0xff).to_byte())
}

///|
fn write_u64_buf(buf : Buffer, value : UInt64) -> Unit {
  for index in 0..<8 {
    buf.write_byte(((value >> (8 * index)) & 0xff).to_byte())
  }
}

///|
fn build_zip64_extra(
  uncomp~ : Int?,
  comp~ : Int?,
  offset~ : Int?,
) -> Bytes raise ZipError {
  let mut count = 0
  if uncomp is Some(_) {
    count = count + 1
  }
  if comp is Some(_) {
    count = count + 1
  }
  if offset is Some(_) {
    count = count + 1
  }
  if count == 0 {
    return b""
  }
  let buf = Buffer()
  write_u16_buf(buf, zip64_extra_id)
  write_u16_buf(buf, 8 * count)
  if uncomp is Some(value) {
    write_u64_buf(buf, value.to_uint64_checked())
  }
  if comp is Some(value) {
    write_u64_buf(buf, value.to_uint64_checked())
  }
  if offset is Some(value) {
    write_u64_buf(buf, value.to_uint64_checked())
  }
  buf.to_bytes()
}

///|
/// The materialized (or sized) payload of one fresh entry.
priv struct PreparedPayload {
  compressed_size : Int
  compressed : Bytes?
}

///|
/// Compress the entry's payload once. The sizing pass discards the bytes after
/// measuring; the emit pass keeps them so each entry is DEFLATEd exactly once
/// per pass.
fn prepare_payload(
  entry : Entry,
  level : Int,
  counting : Bool,
) -> PreparedPayload {
  match entry.compression {
    Store => { compressed_size: entry.data.length(), compressed: None, }
    Deflate => {
      let compressed = @flate.deflate_all(entry.data, level~)
      if counting {
        { compressed_size: compressed.length(), compressed: None, }
      } else {
        { compressed_size: compressed.length(), compressed: Some(compressed), }
      }
    }
  }
}

///|
fn method_code(entry : Entry) -> Int {
  match entry.compression {
    Store => 0
    Deflate => 8
  }
}

///|
fn entry_name_bytes(entry : Entry) -> Bytes raise ZipError {
  let name = @encoding/utf8.encode(entry.name)
  if name.length() > 0xffff {
    raise ZipError(UnsupportedFeature, "zip: entry name too long")
  }
  name
}

///|
fn write_local_record(
  out : Output,
  entry : Entry,
  name_bytes : Bytes,
  payload : PreparedPayload,
  use_descriptor : Bool,
  force_zip64 : Bool,
) -> Unit raise ZipError {
  let method_id = method_code(entry)
  let data_len = entry.data.length()
  let compressed_size = payload.compressed_size
  let crc = entry.crc32
  let needs_zip64_sizes = force_zip64 ||
    data_len.to_uint_checked() > max_u32 ||
    compressed_size.to_uint_checked() > max_u32
  let version = if needs_zip64_sizes { 45 } else { 20 }
  let flags = flag_utf8 |
    (if use_descriptor { flag_data_descriptor } else { 0 })
  let local_extra = if needs_zip64_sizes {
    build_zip64_extra(
      uncomp=Some(data_len),
      comp=Some(compressed_size),
      offset=None,
    )
  } else {
    b""
  }
  out.write_u32(local_header_sig)
  out.write_u16(version)
  out.write_u16(flags)
  out.write_u16(method_id)
  out.write_u16(0)
  out.write_u16(0)
  if use_descriptor {
    out.write_u32(0)
    let size_field = if needs_zip64_sizes { max_u32 } else { 0 }
    out.write_u32(size_field)
    out.write_u32(size_field)
  } else {
    out.write_u32(crc)
    let comp_field = if needs_zip64_sizes {
      max_u32
    } else {
      compressed_size.to_uint_checked()
    }
    let uncomp_field = if needs_zip64_sizes {
      max_u32
    } else {
      data_len.to_uint_checked()
    }
    out.write_u32(comp_field)
    out.write_u32(uncomp_field)
  }
  out.write_u16(name_bytes.length())
  out.write_u16(local_extra.length())
  out.write_bytes(name_bytes)
  out.write_bytes(local_extra)
  // Both arms fall through to the data descriptor below, so the descriptor is
  // emitted (and, in the sizing pass, counted) for STORED and DEFLATE entries
  // alike — a `guard` would `return` out of the missing-payload branch and
  // skip it.
  if payload.compressed is Some(compressed) {
    out.write_bytes(compressed)
  } else {
    match entry.compression {
      Store => out.write_bytes(entry.data)
      Deflate => out.count(compressed_size)
    }
  }
  if use_descriptor {
    out.write_u32(data_descriptor_sig)
    out.write_u32(crc)
    if needs_zip64_sizes {
      out.write_u64(compressed_size.to_uint64_checked())
      out.write_u64(data_len.to_uint64_checked())
    } else {
      out.write_u32(compressed_size.to_uint_checked())
      out.write_u32(data_len.to_uint_checked())
    }
  }
}

///|
fn write_central_record(
  out : Output,
  entry : Entry,
  name_bytes : Bytes,
  local_offset : Int,
  compressed_size : Int,
  use_descriptor : Bool,
  force_zip64 : Bool,
) -> Unit raise ZipError {
  let method_id = method_code(entry)
  let data_len = entry.data.length()
  let needs_zip64_sizes = force_zip64 ||
    data_len.to_uint_checked() > max_u32 ||
    compressed_size.to_uint_checked() > max_u32
  let needs_zip64_offset = force_zip64 ||
    local_offset.to_uint_checked() > max_u32
  let needs_zip64_entry = needs_zip64_sizes || needs_zip64_offset
  let version = if needs_zip64_entry { 45 } else { 20 }
  let flags = flag_utf8 |
    (if use_descriptor { flag_data_descriptor } else { 0 })
  let central_extra = build_zip64_extra(
    uncomp=if needs_zip64_sizes { Some(data_len) } else { None },
    comp=if needs_zip64_sizes { Some(compressed_size) } else { None },
    offset=if needs_zip64_offset { Some(local_offset) } else { None },
  )
  out.write_u32(central_header_sig)
  out.write_u16(version)
  out.write_u16(version)
  out.write_u16(flags)
  out.write_u16(method_id)
  out.write_u16(0)
  out.write_u16(0)
  out.write_u32(entry.crc32)
  let comp_field = if needs_zip64_sizes {
    max_u32
  } else {
    compressed_size.to_uint_checked()
  }
  let uncomp_field = if needs_zip64_sizes {
    max_u32
  } else {
    data_len.to_uint_checked()
  }
  out.write_u32(comp_field)
  out.write_u32(uncomp_field)
  out.write_u16(name_bytes.length())
  out.write_u16(central_extra.length())
  out.write_u16(0)
  out.write_u16(0)
  out.write_u16(0)
  out.write_u32(0)
  let offset_field = if needs_zip64_offset {
    max_u32
  } else {
    local_offset.to_uint_checked()
  }
  out.write_u32(offset_field)
  out.write_bytes(name_bytes)
  out.write_bytes(central_extra)
}

///|
fn write_preserved_central_record(
  out : Output,
  source : SourceRecord,
  local_offset : Int,
) -> Unit raise ZipError {
  let template = source.central_record
  if template.length() < 46 ||
    read_u32_le_at_raw(template, 0) != central_header_sig {
    raise ZipError(
      UnsupportedFeature,
      "zip: preserved central record is malformed",
    )
  }
  match source.central_zip64_offset_position {
    Some(position) => {
      out.write_bytes(template[0:position])
      out.write_u64(local_offset.to_uint64_checked())
      out.write_bytes(template[position + 8:])
    }
    None => {
      out.write_bytes(template[0:42])
      out.write_u32(local_offset.to_uint_checked())
      out.write_bytes(template[46:])
    }
  }
}

///|
fn write_generated_classic_end_record(
  out : Output,
  zip64 : Bool,
  total_entries : Int,
  central_size : Int,
  central_offset : Int,
  comment : Bytes,
) -> Unit raise ZipError {
  out.write_u32(end_of_central_sig)
  out.write_u16(0)
  out.write_u16(0)
  if zip64 {
    out.write_u16(0xffff)
    out.write_u16(0xffff)
    out.write_u32(max_u32)
    out.write_u32(max_u32)
  } else {
    if total_entries > 0xffff {
      raise ZipError(
        UnsupportedFeature,
        "zip: too many entries for a classic archive",
      )
    }
    out.write_u16(total_entries)
    out.write_u16(total_entries)
    out.write_u32(central_size.to_uint_checked())
    out.write_u32(central_offset.to_uint_checked())
  }
  if comment.length() > 0xffff {
    raise ZipError(UnsupportedFeature, "zip: archive comment too long")
  }
  out.write_u16(comment.length())
  out.write_bytes(comment)
}

///|
fn write_generated_zip64_trailer(
  out : Output,
  total_entries : Int,
  central_size : Int,
  central_offset : Int,
  comment : Bytes,
) -> Unit raise ZipError {
  let zip64_offset = out.size
  out.write_u32(zip64_eocd_sig)
  out.write_u64((44).to_uint64_checked())
  out.write_u16(45)
  out.write_u16(45)
  out.write_u32(0)
  out.write_u32(0)
  let entry_count = total_entries.to_uint64_checked()
  out.write_u64(entry_count)
  out.write_u64(entry_count)
  out.write_u64(central_size.to_uint64_checked())
  out.write_u64(central_offset.to_uint64_checked())
  out.write_u32(zip64_locator_sig)
  out.write_u32(0)
  out.write_u64(zip64_offset.to_uint64_checked())
  out.write_u32(1)
  write_generated_classic_end_record(
    out, true, total_entries, central_size, central_offset, comment,
  )
}

///|
fn write_preserved_trailer(
  out : Output,
  trailer : TrailerTemplate,
  total_entries : Int,
  central_size : Int,
  central_offset : Int,
) -> Unit raise ZipError {
  let classic = trailer.classic_end_record
  if classic.length() < 22 ||
    read_u32_le_at_raw(classic, 0) != end_of_central_sig {
    raise ZipError(UnsupportedFeature, "zip: preserved end record is malformed")
  }
  match trailer.zip64_end_record {
    Some(end_record) => {
      if end_record.length() < 56 ||
        read_u32_le_at_raw(end_record, 0) != zip64_eocd_sig {
        raise ZipError(
          UnsupportedFeature,
          "zip: preserved zip64 end record is malformed",
        )
      }
      let zip64_offset = out.size
      // Patch the two entry-count fields, central size, and central offset
      // (offsets 24/32/40/48 within the record) over the verbatim template.
      out.write_bytes(end_record[0:24])
      out.write_u64(total_entries.to_uint64_checked())
      out.write_u64(total_entries.to_uint64_checked())
      out.write_u64(central_size.to_uint64_checked())
      out.write_u64(central_offset.to_uint64_checked())
      out.write_bytes(end_record[56:])
      guard trailer.zip64_locator is Some(locator) else {
        raise ZipError(
          UnsupportedFeature,
          "zip: preserved zip64 locator is missing",
        )
      }
      if locator.length() != 20 ||
        read_u32_le_at_raw(locator, 0) != zip64_locator_sig {
        raise ZipError(
          UnsupportedFeature,
          "zip: preserved zip64 locator is malformed",
        )
      }
      out.write_bytes(locator[0:8])
      out.write_u64(zip64_offset.to_uint64_checked())
      out.write_bytes(locator[16:])
      // The classic record of a preserved ZIP64 archive carries sentinels;
      // re-emit it verbatim.
      out.write_bytes(classic)
    }
    None =>
      write_preserved_classic_end_record(
        out, classic, total_entries, central_size, central_offset,
      )
  }
}

///|
/// Streams a classic end record while patching both entry-count fields
/// (offsets 8, 10) and the central size/offset (offsets 12, 16). Fields
/// carrying ZIP64 sentinels are left untouched.
fn write_preserved_classic_end_record(
  out : Output,
  classic : Bytes,
  total_entries : Int,
  central_size : Int,
  central_offset : Int,
) -> Unit raise ZipError {
  if classic.length() < 22 ||
    read_u32_le_at_raw(classic, 0) != end_of_central_sig {
    raise ZipError(UnsupportedFeature, "zip: preserved end record is malformed")
  }
  let count = total_entries.min(0xffff)
  let mut cursor = 0
  let entries_on_disk = read_u16_le_at(classic, 8)
  if entries_on_disk != 0xffff {
    out.write_bytes(classic[cursor:8])
    out.write_u16(count)
    cursor = 10
  }
  let total_on_disk = read_u16_le_at(classic, 10)
  if total_on_disk != 0xffff {
    out.write_bytes(classic[cursor:10])
    out.write_u16(count)
    cursor = 12
  }
  let size_field = read_u32_le_at_raw(classic, 12)
  if size_field != max_u32 {
    out.write_bytes(classic[cursor:12])
    out.write_u32(central_size.to_uint_checked())
    cursor = 16
  }
  let offset_field = read_u32_le_at_raw(classic, 16)
  if offset_field != max_u32 {
    out.write_bytes(classic[cursor:16])
    out.write_u32(central_offset.to_uint_checked())
    cursor = 20
  }
  out.write_bytes(classic[cursor:])
}

///|
/// Per-entry sizing/emission bookkeeping shared between the counting and emit
/// passes.
priv struct EntryPlan {
  local_offset : Int
  compressed_size : Int
}

///|
/// The order in which local records are written: pristine entries first, in
/// their original source order, then entries created in memory. This lets a
/// byte-preserving rewrite keep the archive's original layout for everything
/// it can re-emit verbatim.
fn archive_local_order(archive : Archive) -> Array[Int] {
  let order = []
  for index in 0..<archive.entries.length() {
    order.push(index)
  }
  order.sort_by((left, right) => {
    match (archive.entries[left].source, archive.entries[right].source) {
      (Some(a), Some(b)) => a.local_offset.compare(b.local_offset)
      (Some(_), None) => -1
      (None, Some(_)) => 1
      (None, None) => left.compare(right)
    }
  })
  order
}

///|
/// Writes every local record, then every central directory record, filling
/// `plans` with each entry's local offset and compressed size. Returns the
/// central directory's offset and size.
fn emit_archive(
  out : Output,
  archive : Archive,
  order : Array[Int],
  plans : Array[EntryPlan],
  preserve : Bool,
  level : Int,
  force_zip64 : Bool,
) -> (Int, Int) raise ZipError {
  for index in order {
    let entry = archive.entries[index]
    let local_offset = out.size
    match (entry.source, preserve) {
      (Some(source), true) => {
        out.write_bytes(source.local_record)
        plans[index] = { local_offset, compressed_size: entry.compressed_size, }
      }
      _ => {
        let payload = prepare_payload(entry, level, out.is_counting())
        write_local_record(
          out,
          entry,
          entry_name_bytes(entry),
          payload,
          entry.data_descriptor,
          force_zip64,
        )
        plans[index] = {
          local_offset,
          compressed_size: payload.compressed_size,
        }
      }
    }
  }
  let central_offset = out.size
  for index in order {
    let entry = archive.entries[index]
    match (entry.source, preserve) {
      (Some(source), true) =>
        write_preserved_central_record(out, source, plans[index].local_offset)
      _ =>
        write_central_record(
          out,
          entry,
          entry_name_bytes(entry),
          plans[index].local_offset,
          plans[index].compressed_size,
          entry.data_descriptor,
          force_zip64,
        )
    }
  }
  let central_size = out.size - central_offset
  (central_offset, central_size)
}

///|
fn write_trailer(
  out : Output,
  archive : Archive,
  total_entries : Int,
  central_size : Int,
  central_offset : Int,
  preserve : Bool,
  force_zip64 : Bool,
) -> Unit raise ZipError {
  let needs_zip64 = force_zip64 ||
    total_entries > 0xffff ||
    central_size.to_uint_checked() > max_u32 ||
    central_offset.to_uint_checked() > max_u32
  match (preserve, archive.trailer) {
    (true, Some(trailer)) if !needs_zip64 || trailer.zip64_end_record is Some(_) =>
      write_preserved_trailer(
        out, trailer, total_entries, central_size, central_offset,
      )
    _ =>
      if needs_zip64 {
        write_generated_zip64_trailer(
          out,
          total_entries,
          central_size,
          central_offset,
          archive.comment,
        )
      } else {
        write_generated_classic_end_record(
          out,
          false,
          total_entries,
          central_size,
          central_offset,
          archive.comment,
        )
      }
  }
}

///|
fn write_impl(
  archive : Archive,
  preserve : Bool,
  level : Int,
  max_output : Int?,
) -> Bytes raise ZipError {
  let order = archive_local_order(archive)
  let plans = Array::make(archive.entries.length(), {
    local_offset: 0,
    compressed_size: 0,
  })
  match max_output {
    Some(limit) => {
      let counting = Output::counting(Some(limit))
      let (counting_central_offset, counting_central_size) = emit_archive(
        counting, archive, order, plans, preserve, level, false,
      )
      write_trailer(
        counting,
        archive,
        archive.entries.length(),
        counting_central_size,
        counting_central_offset,
        preserve,
        false,
      )
      let size = counting.size
      let out = Output::writing(Some(limit))
      let (central_offset, central_size) = emit_archive(
        out, archive, order, plans, preserve, level, false,
      )
      write_trailer(
        out,
        archive,
        archive.entries.length(),
        central_size,
        central_offset,
        preserve,
        false,
      )
      if central_offset != counting_central_offset ||
        central_size != counting_central_size ||
        out.size != size {
        raise ZipError(UnsupportedFeature, "zip: sizing and emission disagreed")
      }
      out.finish()
    }
    None => {
      let out = Output::writing(None)
      let (central_offset, central_size) = emit_archive(
        out, archive, order, plans, preserve, level, false,
      )
      write_trailer(
        out,
        archive,
        archive.entries.length(),
        central_size,
        central_offset,
        preserve,
        false,
      )
      out.finish()
    }
  }
}

///|
/// Serialize `archive` into a ZIP byte stream, encoding every entry fresh
/// (DEFLATE by default, STORED when the entry says so). `level` 0-9 trades
/// speed for ratio on the DEFLATE payloads.
pub fn write(archive : Archive, level? : Int = 6) -> Bytes raise ZipError {
  write_impl(archive, false, level, None)
}

///|
/// Serialize `archive`, re-emitting pristine entries (those read from a
/// previous archive and never replaced) byte-for-byte from their retained
/// source records, so unchanged packages round-trip without loss. Entries
/// created or replaced in memory are encoded fresh.
pub fn write_preserving(
  archive : Archive,
  level? : Int = 6,
) -> Bytes raise ZipError {
  write_impl(archive, true, level, None)
}

///|
/// Serialize `archive` like `write` while enforcing a hard output ceiling. The
/// output is sized first, so an over-limit archive raises
/// `LimitExceeded(OutputBytes, ...)` without materializing a candidate buffer.
pub fn write_limited(
  archive : Archive,
  max_output_bytes~ : Int,
  level? : Int = 6,
) -> Bytes raise ZipError {
  if max_output_bytes < 0 {
    raise ZipError(UnsupportedFeature, "zip: output limit must be non-negative")
  }
  write_impl(archive, false, level, Some(max_output_bytes))
}

///|
/// Serialize `archive` like `write_preserving` while enforcing a hard output
/// ceiling (sized first, so an over-limit archive raises without materializing
/// a candidate buffer).
pub fn write_preserving_limited(
  archive : Archive,
  max_output_bytes~ : Int,
  level? : Int = 6,
) -> Bytes raise ZipError {
  if max_output_bytes < 0 {
    raise ZipError(UnsupportedFeature, "zip: output limit must be non-negative")
  }
  write_impl(archive, true, level, Some(max_output_bytes))
}
