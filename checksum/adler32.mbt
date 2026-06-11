///|
/// Largest modulus.
let adler_modulus = 65521

///|
/// Incremental Adler-32 accumulator (RFC 1950 §9), the streaming counterpart to
/// `adler32`. Feed bytes with `update`, read with `finish`.
pub struct Adler32 {
  priv mut a : Int
  priv mut b : Int
}

///|
/// Create a fresh Adler-32 accumulator.
pub fn Adler32::new() -> Adler32 {
  { a: 1, b: 0 }
}

///|
/// Fold `data` into the running checksum.
pub fn Adler32::update(self : Adler32, data : BytesView) -> Unit {
  let mut a = self.a
  let mut b = self.b
  for byte in data {
    a = (a + byte.to_int()) % adler_modulus
    b = (b + a) % adler_modulus
  }
  self.a = a
  self.b = b
}

///|
/// Fold a single byte into the running checksum. Lets a caller checksum bytes
/// it can only reach one at a time (e.g. read back from a `MutArrayView`
/// output) without materializing a `Bytes`.
pub fn Adler32::update_byte(self : Adler32, byte : Byte) -> Unit {
  self.a = (self.a + byte.to_int()) % adler_modulus
  self.b = (self.b + self.a) % adler_modulus
}

///|
/// The Adler-32 of everything fed so far. Non-destructive.
pub fn Adler32::finish(self : Adler32) -> UInt {
  (self.b.reinterpret_as_uint() << 16) | self.a.reinterpret_as_uint()
}

///|
/// Compute the Adler-32 checksum of `data` in one shot. Shared primitive:
/// `@checksum.adler32`.
pub fn adler32(data : Bytes) -> UInt {
  let d = Adler32::new()
  d.update(data[:])
  d.finish()
}
