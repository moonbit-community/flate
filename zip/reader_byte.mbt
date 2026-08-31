///|
/// Byte-level primitives and shared ZIP format constants: the little-endian
/// cursor, fixed-width field readers, the end-of-central scan, and
/// cancellation-aware owned copies.

///|
pub const LOCAL_HEADER_SIG : UInt = 0x04034b50

///|
pub const CENTRAL_HEADER_SIG : UInt = 0x02014b50

///|
pub const END_OF_CENTRAL_SIG : UInt = 0x06054b50

///|
pub const DATA_DESCRIPTOR_SIG : UInt = 0x08074b50

///|
pub const ZIP64_EOCD_SIG : UInt = 0x06064b50

///|
pub const ZIP64_LOCATOR_SIG : UInt = 0x07064b50

///|
pub const FLAG_DATA_DESCRIPTOR : Int = 0x0008

///|
pub const FLAG_UTF8 : Int = 0x0800

///|
pub const FLAG_ENCRYPTED : Int = 0x0001

///|
pub const FLAG_DEFLATE_STRENGTH : Int = 0x0006

///|
pub const ZIP64_EXTRA_ID : Int = 0x0001

///|
pub const MAX_U32 : UInt = 0xFFFFFFFF

///|
priv struct Cursor {
  bytes : BytesView
  mut pos : Int
}

///|
fn Cursor::Cursor(bytes : BytesView, pos : Int) -> Cursor {
  { bytes, pos, }
}

///|
fn Cursor::read_u8(self : Cursor) -> Int raise ZipError {
  if self.pos < 0 || self.pos >= self.bytes.length() {
    raise ZipError(Truncated, "zip: truncated header")
  }
  let value = self.bytes[self.pos].to_int()
  self.pos = self.pos + 1
  value
}

///|
fn Cursor::read_u16(self : Cursor) -> Int raise ZipError {
  let b0 = self.read_u8()
  let b1 = self.read_u8()
  b0 | (b1 << 8)
}

///|
fn Cursor::read_u32_raw(self : Cursor) -> UInt raise ZipError {
  let b0 = self.read_u8()
  let b1 = self.read_u8()
  let b2 = self.read_u8()
  let b3 = self.read_u8()
  b0.reinterpret_as_uint() |
  (b1.reinterpret_as_uint() << 8) |
  (b2.reinterpret_as_uint() << 16) |
  (b3.reinterpret_as_uint() << 24)
}

///|
fn Cursor::read_u64_raw(self : Cursor) -> UInt64 raise ZipError {
  let lo = self.read_u32_raw()
  let hi = self.read_u32_raw()
  (UInt64::extend_uint(hi) << 32) | UInt64::extend_uint(lo)
}

///|
fn Cursor::read_bytes(self : Cursor, len : Int) -> BytesView raise ZipError {
  if len < 0 || self.pos < 0 || len > self.bytes.length() - self.pos {
    raise ZipError(Truncated, "zip: truncated field")
  }
  let start = self.pos
  self.pos = self.pos + len
  self.bytes[start:self.pos]
}

///|
fn Cursor::skip(self : Cursor, len : Int) -> Unit raise ZipError {
  ignore(self.read_bytes(len))
}

///|
fn read_u16_le_at(bytes : BytesView, offset : Int) -> Int raise ZipError {
  if offset < 0 || 2 > bytes.length() - offset {
    raise ZipError(Truncated, "zip: truncated field")
  }
  let b0 = bytes[offset].to_int()
  let b1 = bytes[offset + 1].to_int()
  b0 | (b1 << 8)
}

///|
fn read_u32_le_at_raw(bytes : BytesView, offset : Int) -> UInt raise ZipError {
  if offset < 0 || 4 > bytes.length() - offset {
    raise ZipError(Truncated, "zip: truncated field")
  }
  bytes[offset].to_uint() |
  (bytes[offset + 1].to_uint() << 8) |
  (bytes[offset + 2].to_uint() << 16) |
  (bytes[offset + 3].to_uint() << 24)
}

///|
fn read_u64_le_at(bytes : BytesView, offset : Int) -> UInt64 raise ZipError {
  if offset < 0 || 8 > bytes.length() - offset {
    raise ZipError(Truncated, "zip: truncated field")
  }
  let mut result : UInt64 = 0
  for i in 0..<8 {
    let b = bytes[offset + i].to_uint()
    result = result | (UInt64::extend_uint(b) << (i * 8))
  }
  result
}

///|
/// Locate the end-of-central-directory record by scanning the conventional
/// last (65535 + 22) bytes for the signature whose comment length reaches the
/// end of the input. Returns its offset, or `None`.
fn find_end_of_central(bytes : BytesView) -> Int? raise ZipError {
  let len = bytes.length()
  if len < 22 {
    return None
  }
  let max_scan = 22 + 0xFFFF
  let min_offset = (len - max_scan).max(0)
  for i in (len - 22)>=..min_offset {
    if read_u32_le_at_raw(bytes, i) == END_OF_CENTRAL_SIG &&
      read_u16_le_at(bytes, i + 20) == len - i - 22 {
      return Some(i)
    }
  } nobreak {
    None
  }
}

///|
fn decode_name(bytes : BytesView) -> String raise ZipError {
  @encoding/utf8.decode(bytes) catch {
    _ => raise ZipError(InvalidUtf8, "zip: entry name is not UTF-8")
  }
}

///|
fn ensure_flags_supported(flags : Int) -> Unit raise ZipError {
  if (flags & FLAG_ENCRYPTED) != 0 {
    raise ZipError(
      UnsupportedFeature,
      "zip: encrypted entries are not supported",
    )
  }
  let supported = FLAG_DATA_DESCRIPTOR | FLAG_UTF8 | FLAG_DEFLATE_STRENGTH
  let unsupported = flags & supported.lnot()
  if unsupported != 0 {
    raise ZipError(
      UnsupportedFeature,
      "zip: unsupported entry flags: 0x\{unsupported.to_string(radix=16)}",
    )
  }
}

///|
fn method_from_code(method_id : Int) -> Compression raise ZipError {
  match method_id {
    0 => Store
    8 => Deflate
    _ =>
      raise ZipError(
        UnsupportedCompression(method_id),
        "zip: unsupported compression method \{method_id}",
      )
  }
}

///|
/// Copies `bytes` into owned storage, polling `cancelled` every 64 KiB so a
/// large source record cannot hide behind a monolithic runtime copy.
fn copy_cancellable(
  bytes : BytesView,
  cancelled : () -> Bool,
) -> Bytes raise ZipError {
  check_cancelled(cancelled)
  let output : UninitializedArray[Byte] = UninitializedArray::make(
    bytes.length(),
  )
  for index in 0..<bytes.length() {
    if (index & 0xffff) == 0 {
      check_cancelled(cancelled)
    }
    output[index] = bytes[index]
  }
  check_cancelled(cancelled)
  initialized_zip_byte_buffer_to_bytes(output)
}

///|
fn initialized_zip_byte_buffer_to_bytes(
  buffer : UninitializedArray[Byte],
) -> Bytes = "%identity"
