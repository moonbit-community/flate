///|
/// The ZIP compression methods this package can read and write.
pub(all) enum Compression {
  Store
  Deflate
} derive(Eq, Debug)

///|
pub extend Compression with Eq::{not_equal, equal}

///|
pub extend Compression with Debug::{to_repr}

///|
/// Resource bounds applied to a bounded read. Every field is a ceiling in
/// bytes (or, for `max_entries`, a count); `ReadLimits::default()` imposes no
/// limits. `max_preserved_source_bytes` bounds the raw local/central records
/// retained in memory so a byte-preserving rewrite cannot be weaponized as an
/// unbounded retention bomb.
pub struct ReadLimits {
  max_package_bytes : Int
  max_entries : Int
  max_entry_uncompressed_bytes : Int
  max_total_uncompressed_bytes : Int
  max_preserved_source_bytes : Int
}

///|
/// The default, unlimited resource bounds.
pub fn ReadLimits::default() -> ReadLimits {
  {
    max_package_bytes: 0x7fff_ffff,
    max_entries: 0x7fff_ffff,
    max_entry_uncompressed_bytes: 0x7fff_ffff,
    max_total_uncompressed_bytes: 0x7fff_ffff,
    max_preserved_source_bytes: 0x7fff_ffff,
  }
}

///|
/// A copy of `self` with a new package-size ceiling.
pub fn ReadLimits::with_package_limit(
  self : ReadLimits,
  limit : Int,
) -> ReadLimits {
  {
    max_package_bytes: limit,
    max_entries: self.max_entries,
    max_entry_uncompressed_bytes: self.max_entry_uncompressed_bytes,
    max_total_uncompressed_bytes: self.max_total_uncompressed_bytes,
    max_preserved_source_bytes: self.max_preserved_source_bytes,
  }
}

///|
/// A copy of `self` with a new entry-count ceiling.
pub fn ReadLimits::with_entries_limit(
  self : ReadLimits,
  limit : Int,
) -> ReadLimits {
  {
    max_package_bytes: self.max_package_bytes,
    max_entries: limit,
    max_entry_uncompressed_bytes: self.max_entry_uncompressed_bytes,
    max_total_uncompressed_bytes: self.max_total_uncompressed_bytes,
    max_preserved_source_bytes: self.max_preserved_source_bytes,
  }
}

///|
/// A copy of `self` with a new per-entry uncompressed ceiling.
pub fn ReadLimits::with_entry_limit(
  self : ReadLimits,
  limit : Int,
) -> ReadLimits {
  {
    max_package_bytes: self.max_package_bytes,
    max_entries: self.max_entries,
    max_entry_uncompressed_bytes: limit,
    max_total_uncompressed_bytes: self.max_total_uncompressed_bytes,
    max_preserved_source_bytes: self.max_preserved_source_bytes,
  }
}

///|
/// A copy of `self` with a new total uncompressed ceiling.
pub fn ReadLimits::with_total_limit(
  self : ReadLimits,
  limit : Int,
) -> ReadLimits {
  {
    max_package_bytes: self.max_package_bytes,
    max_entries: self.max_entries,
    max_entry_uncompressed_bytes: self.max_entry_uncompressed_bytes,
    max_total_uncompressed_bytes: limit,
    max_preserved_source_bytes: self.max_preserved_source_bytes,
  }
}

///|
/// A copy of `self` with a new preserved-source-record ceiling.
pub fn ReadLimits::with_preserved_source_limit(
  self : ReadLimits,
  limit : Int,
) -> ReadLimits {
  {
    max_package_bytes: self.max_package_bytes,
    max_entries: self.max_entries,
    max_entry_uncompressed_bytes: self.max_entry_uncompressed_bytes,
    max_total_uncompressed_bytes: self.max_total_uncompressed_bytes,
    max_preserved_source_bytes: limit,
  }
}

///|
/// Raw local and central directory records captured from a read, kept so an
/// unchanged entry can be re-emitted byte-for-byte without re-encoding.
priv struct SourceRecord {
  local_record : Bytes
  central_record : Bytes
  central_zip64_offset_position : Int?
}

///|
/// A single archive entry: its decoded payload plus the metadata the central
/// directory carried for it. Entries produced by `read` also retain their raw
/// source records (`raw_local_record` / `raw_central_record`) for
/// byte-preserving rewrites; entries built with `Archive::add` do not.
pub struct Entry {
  priv name : String
  priv data : Bytes
  priv compression : Compression
  priv crc32 : UInt
  priv data_descriptor : Bool
  priv compressed_size : Int
  priv source : SourceRecord?
  priv origin_local_offset : Int?
}

///|
pub fn Entry::name(self : Entry) -> String {
  self.name
}

///|
pub fn Entry::data(self : Entry) -> BytesView {
  self.data
}

///|
pub fn Entry::compression(self : Entry) -> Compression {
  self.compression
}

///|
/// The entry's stored CRC-32: the central-directory value for entries read from
/// an archive, or computed at `add` time for entries created in memory.
pub fn Entry::crc32(self : Entry) -> UInt {
  self.crc32
}

///|
pub fn Entry::data_descriptor(self : Entry) -> Bool {
  self.data_descriptor
}

///|
/// The original local header + payload (+ data descriptor) bytes of a pristine
/// entry read from an archive, or `None` for entries created in memory or
/// replaced after a read.
pub fn Entry::raw_local_record(self : Entry) -> BytesView? {
  self.source.map(source => source.local_record)
}

///|
/// The original central directory record bytes of a pristine entry read from an
/// archive, or `None` for entries created in memory or replaced after a read.
pub fn Entry::raw_central_record(self : Entry) -> BytesView? {
  self.source.map(source => source.central_record)
}

///|
/// Raw end-of-archive records captured from a read so a byte-preserving write
/// can re-emit the trailer (with patched counts/sizes/offsets) instead of
/// regenerating it.
priv struct TrailerTemplate {
  classic_end_record : Bytes
  zip64_end_record : Bytes?
  zip64_locator : Bytes?
}

///|
/// An in-memory ZIP archive: an ordered list of entries plus an archive
/// comment. Reading a ZIP materializes this; writing serializes it back.
pub struct Archive {
  priv entries : Array[Entry]
  priv mut comment : Bytes
  priv mut trailer : TrailerTemplate?
}

///|
/// Create an empty archive.
pub fn Archive::Archive() -> Archive {
  { entries: [], comment: b"", trailer: None, }
}

///|
/// Append a new entry whose payload is `data`. `data` is owned by the archive,
/// so later `Bytes` mutation cannot corrupt it. The default method is
/// `Deflate`; pass `Store` to keep the payload verbatim. Setting
/// `data_descriptor=true` emits the entry in streaming form (zeroed local
/// sizes + a trailing data descriptor).
pub fn Archive::add(
  self : Archive,
  name : String,
  data : BytesView,
  compression? : Compression = Deflate,
  data_descriptor? : Bool = false,
) -> Unit {
  let data = data.to_owned()
  self.entries.push({
    name,
    data,
    compression,
    data_descriptor,
    crc32: @checksum.crc32(data),
    compressed_size: data.length(),
    source: None,
    origin_local_offset: None,
  })
}

///|
/// Replace the payload of the entry named `name`. The entry keeps its method
/// policy but drops its raw source records (the next write re-encodes it).
/// Its original position in the archive is retained, so a byte-preserving
/// write keeps the entry where it was. Returns `false` when no such entry
/// exists.
pub fn Archive::replace(
  self : Archive,
  name : StringView,
  data : BytesView,
) -> Bool {
  for index in 0..<self.entries.length() {
    let entry = self.entries[index]
    if entry.name()[:] == name {
      let data = data.to_owned()
      self.entries[index] = {
        name: entry.name,
        data,
        compression: entry.compression,
        data_descriptor: entry.data_descriptor,
        crc32: @checksum.crc32(data),
        compressed_size: data.length(),
        source: None,
        origin_local_offset: entry.origin_local_offset,
      }
      return true
    }
  }
  false
}

///|
/// Remove the entry named `name`. Returns `false` when no such entry exists.
pub fn Archive::remove(self : Archive, name : StringView) -> Bool {
  for index in 0..<self.entries.length() {
    if self.entries[index].name()[:] == name {
      ignore(self.entries.remove(index))
      return true
    }
  }
  false
}

///|
/// A read-only view of an entry payload, or `None` when absent.
pub fn Archive::get(self : Archive, name : StringView) -> BytesView? {
  for entry in self.entries {
    if entry.name()[:] == name {
      return Some(entry.data())
    }
  }
  None
}

///|
/// The archive's entry list in order.
pub fn Archive::entries(self : Archive) -> ArrayView[Entry] {
  self.entries
}

///|
/// The archive-level comment bytes (empty when none).
pub fn Archive::comment(self : Archive) -> BytesView {
  self.comment
}

///|
/// Replace the archive-level comment. Long comments (over 65535 bytes) are
/// rejected at write time. Changing the comment invalidates a retained
/// end-record template, so a later byte-preserving write regenerates the
/// trailer with the new comment.
pub fn Archive::set_comment(self : Archive, comment : BytesView) -> Unit {
  self.comment = comment.to_owned()
  self.trailer = None
}

///|
/// Returns an independently mutable snapshot of this archive. The clone shares
/// entry payloads and preserved source records (immutable `Bytes`) but owns a
/// fresh entries array, so `add`/`replace`/`remove` on either side never
/// affects the other. `add` and `replace` defensively own their inputs.
pub fn Archive::clone(self : Archive) -> Archive {
  {
    entries: self.entries.copy(),
    comment: self.comment,
    trailer: self.trailer,
  }
}

///|
/// Deprecated alias of `Archive::clone`.
#deprecated("use `Archive::clone` instead")
pub fn Archive::fork(self : Archive) -> Archive {
  self.clone()
}

///|
/// Conservatively estimates bytes retained by this materialized archive: the
/// archive comment, captured trailer records, and per-entry payloads, names,
/// and preserved source records (each with a bookkeeping reserve). Payloads
/// and records are counted exactly; only allocator/container overhead uses a
/// fixed per-entry reserve. The source package buffer an archive was read from
/// is not included.
pub fn Archive::retained_size_estimate(self : Archive) -> Int64 {
  let mut total = self.comment.length().to_int64()
  match self.trailer {
    Some(trailer) => {
      total = total + trailer.classic_end_record.length().to_int64()
      match trailer.zip64_end_record {
        Some(record) => total = total + record.length().to_int64()
        None => ()
      }
      match trailer.zip64_locator {
        Some(locator) => total = total + locator.length().to_int64()
        None => ()
      }
    }
    None => ()
  }
  for entry in self.entries {
    total = total + entry.data.length().to_int64()
    total = total + entry.name.length().to_int64() * 2L
    // Entry/array slots, references, option wrappers, and allocator metadata.
    total = total + 512L
    match entry.source {
      Some(source) => {
        total = total + source.local_record.length().to_int64()
        total = total + source.central_record.length().to_int64()
        total = total + 128L
      }
      None => ()
    }
  }
  total
}
