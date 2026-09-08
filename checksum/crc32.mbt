///|
/// CRC-32 (IEEE 802.3 / ISO 3309, polynomial 0xEDB88320 reflected) as used by
/// gzip and ZIP. Shared primitive: `@checksum.crc32`.
fn build_crc32_table() -> FixedArray[UInt] {
  let t = FixedArray::make(8 * 256, 0U)
  for n in 0..<256 {
    let mut c = n.reinterpret_as_uint()
    for _k in 0..<8 {
      c = if (c & 1) != 0 { 0xEDB88320 ^ (c >> 1) } else { c >> 1 }
    }
    t[n] = c
  }
  // Slice k is the remainder after k further zero bytes. Keep slice zero
  // compatible with the byte-at-a-time tail and incremental update_byte.
  for slice in 1..<8 {
    for n in 0..<256 {
      let previous = t[(slice - 1) * 256 + n]
      t[slice * 256 + n] = t[(previous & 0xFF).reinterpret_as_int()] ^
        (previous >> 8)
    }
  }
  t
}

///|
let crc32_table : FixedArray[UInt] = build_crc32_table()

///|
/// Incremental CRC-32 accumulator. Feed bytes with `update` across as many
/// calls as you like, then read the result with `finish`; this is what a
/// streaming gzip/ZIP container uses so it never has to hold the whole input.
pub struct Crc32 {
  priv mut state : UInt // running CRC, before the final one's-complement
}

///|
/// Create a fresh CRC-32 accumulator.
pub fn Crc32::Crc32() -> Crc32 {
  { state: 0xFFFFFFFF, }
}

///|
/// Fold eight bytes at a time using independent table lookups, then handle
/// the remaining bytes with the scalar recurrence. Explicit byte assembly
/// supports unaligned views and every backend without host-endian assumptions.
pub fn Crc32::update(self : Crc32, data : BytesView) -> Unit {
  let mut crc = self.state
  let mut position = 0
  while data.length() - position >= 8 {
    let first = crc ^
      data[position].to_uint() ^
      (data[position + 1].to_uint() << 8) ^
      (data[position + 2].to_uint() << 16) ^
      (data[position + 3].to_uint() << 24)
    crc = crc32_table[1792 + (first & 0xFF).reinterpret_as_int()] ^
      crc32_table[1536 + ((first >> 8) & 0xFF).reinterpret_as_int()] ^
      crc32_table[1280 + ((first >> 16) & 0xFF).reinterpret_as_int()] ^
      crc32_table[1024 + (first >> 24).reinterpret_as_int()] ^
      crc32_table[768 + data[position + 4].to_int()] ^
      crc32_table[512 + data[position + 5].to_int()] ^
      crc32_table[256 + data[position + 6].to_int()] ^
      crc32_table[data[position + 7].to_int()]
    position = position + 8
  }
  for i in position..<data.length() {
    crc = crc32_table[((crc ^ data[i].to_uint()) & 0xFF).reinterpret_as_int()] ^
      (crc >> 8)
  }
  self.state = crc
}

///|
/// Fold a single byte into the running checksum. Lets a caller checksum bytes
/// it can only reach one at a time (e.g. read back from a `MutArrayView`
/// output) without materializing a `Bytes`.
pub fn Crc32::update_byte(self : Crc32, b : Byte) -> Unit {
  self.state = crc32_table[((self.state ^ b.to_uint()) & 0xFF).reinterpret_as_int()] ^
    (self.state >> 8)
}

///|
/// The CRC-32 of everything fed so far. Non-destructive: more `update`s may
/// follow.
pub fn Crc32::finish(self : Crc32) -> UInt {
  self.state ^ 0xFFFFFFFF
}

///|
/// Compute the CRC-32 checksum of `data` in one shot.
pub fn crc32(data : BytesView) -> UInt {
  let d = Crc32()
  d.update(data)
  d.finish()
}

///|
/// Compute the CRC-32 checksum of `data` while polling `cancelled` at bounded
/// byte intervals, returning `None` if cancellation is observed. Intended for
/// cooperative cancellation on large, untrusted input; callers without that
/// need can use `crc32`.
pub fn crc32_cancellable(
  bytes : BytesView,
  cancelled? : () -> Bool = () => false,
) -> UInt? {
  if cancelled() {
    return None
  }
  let crc = Crc32()
  let mut start = 0
  while start < bytes.length() {
    if start > 0 && cancelled() {
      return None
    }
    let end = (start + 4096).min(bytes.length())
    crc.update(bytes[start:end])
    start = end
  }
  if cancelled() {
    None
  } else {
    Some(crc.finish())
  }
}
