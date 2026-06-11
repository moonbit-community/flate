///|
/// CRC-32 (IEEE 802.3 / ISO 3309, polynomial 0xEDB88320 reflected) as used by
/// gzip and ZIP. Shared primitive: `@checksum.crc32`.
fn build_crc32_table() -> FixedArray[UInt] {
  let t = FixedArray::make(256, 0U)
  for n in 0..<256 {
    let mut c = n.reinterpret_as_uint()
    for _k in 0..<8 {
      c = if (c & 1) != 0 { 0xEDB88320 ^ (c >> 1) } else { c >> 1 }
    }
    t[n] = c
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
pub fn Crc32::new() -> Crc32 {
  { state: 0xFFFFFFFF }
}

///|
/// Fold `data` into the running checksum.
pub fn Crc32::update(self : Crc32, data : BytesView) -> Unit {
  let mut crc = self.state
  for b in data {
    crc = crc32_table[((crc ^ b.to_uint()) & 0xFF).reinterpret_as_int()] ^
      (crc >> 8)
  }
  self.state = crc
}

///|
/// The CRC-32 of everything fed so far. Non-destructive: more `update`s may
/// follow.
pub fn Crc32::finish(self : Crc32) -> UInt {
  self.state ^ 0xFFFFFFFF
}

///|
/// Compute the CRC-32 checksum of `data` in one shot.
pub fn crc32(data : Bytes) -> UInt {
  let d = Crc32::new()
  d.update(data[:])
  d.finish()
}
