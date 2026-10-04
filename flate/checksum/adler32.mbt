///|
/// Largest modulus.
const ADLER_MODULUS : Int = 65521

///|
/// With reduced a,b <= 65520 and bytes <= 255, after n bytes:
/// b <= 65520 + n*65520 + 255*n*(n+1)/2.
/// At n=3800 this is 2090626020, below signed Int's 2147483647 limit.
const ADLER_BLOCK_SIZE : Int = 3800

///|
/// Incremental Adler-32 accumulator (RFC 1950 §9), the streaming counterpart to
/// `adler32`. Feed bytes with `update`, read with `finish`.
pub struct Adler32 {
  priv mut a : Int
  priv mut b : Int
}

///|
/// Create a fresh Adler-32 accumulator.
pub fn Adler32::Adler32() -> Adler32 {
  { a: 1, b: 0, }
}

///|
/// The plain sum (low 16 bits) and the weighted sum `8*d0 + 7*d1 + ... + d7`
/// (bits 16 and up) of the eight bytes at `i`; both fit their fields.
#cfg(not(any(target="native", target="wasm")))
#inline
fn adler_group8(data : BytesView, i : Int) -> Int {
  // SAFETY: callers prove `data.length() - i >= 8`.
  let d0 = data.unsafe_get(i).to_int()
  let d1 = data.unsafe_get(i + 1).to_int()
  let d2 = data.unsafe_get(i + 2).to_int()
  let d3 = data.unsafe_get(i + 3).to_int()
  let d4 = data.unsafe_get(i + 4).to_int()
  let d5 = data.unsafe_get(i + 5).to_int()
  let d6 = data.unsafe_get(i + 6).to_int()
  let d7 = data.unsafe_get(i + 7).to_int()
  let s01 = d0 + d1
  let s0123 = s01 + (d2 + d3)
  let s45 = d4 + d5
  let s4567 = s45 + (d6 + d7)
  let weighted = (s0123 << 2) +
    (s0123 + (s01 << 1) + d0 + d2) +
    (s4567 + (s45 << 1) + d4 + d6)
  (s0123 + s4567) | (weighted << 16)
}

///|
/// SWAR form of the scalar `adler_group8`: one 64-bit load, with the even
/// and odd bytes spread into 16-bit lanes and gathered by multiplication.
/// Lane sums stay below 2^16, so no carry crosses into the gathered lane.
#cfg(any(target="native", target="wasm"))
#inline
fn adler_group8(data : BytesView, i : Int) -> Int {
  // SAFETY: callers prove `data.length() - i >= 8`.
  let x = data.unsafe_read_uint64_le(i)
  let even = x & 0x00FF00FF00FF00FFUL // d0, d2, d4, d6
  let odd = (x >> 8) & 0x00FF00FF00FF00FFUL // d1, d3, d5, d7
  let sum = ((even + odd) * 0x0001000100010001UL) >> 48
  // 0*d0 + 1*d1 + ... + 7*d7, gathered in the top lane.
  let indexed = ((even * 0x0000000200040006UL) >> 48) +
    ((odd * 0x0001000300050007UL) >> 48)
  (sum | (((sum << 3) - indexed) << 16)).to_int()
}

///|
/// The end of the whole eight-byte groups in `start..<end`. Computed from
/// the span so that no index past `end` is ever formed, even for views
/// ending near `Int` overflow.
fn adler_groups_end(start : Int, end : Int) -> Int {
  end - (end - start) % 8
}

///|
/// Fold `data` into the running checksum.
pub fn Adler32::update(self : Adler32, data : BytesView) -> Unit {
  let mut a = self.a
  let mut b = self.b
  let mut start = 0
  while start < data.length() {
    let end = start + (data.length() - start).min(ADLER_BLOCK_SIZE)
    // Eight serial steps folded into one: `b` gains `8a` (with `a` from
    // before the group) plus the byte weights 8..1, and `a` gains the plain
    // sum. The `b` terms are collected in two separate sums so no long add
    // chain runs through `b`. Every partial sum is at most the serial loop's
    // `b` after the same bytes, so the block bound still holds, and the
    // reduced result is the same.
    let mut a_sum = 0
    let mut weighted_sum = 0
    let mut i = start
    let groups_end = adler_groups_end(start, end)
    while i < groups_end {
      let packed = adler_group8(data, i)
      let weighted = packed >> 16
      a_sum = a_sum + a
      weighted_sum = weighted_sum + weighted
      a = a + (packed & 0xFFFF)
      i = i + 8
    }
    b = b + (a_sum << 3) + weighted_sum
    while i < end {
      a = a + data.unsafe_get(i).to_int()
      b = b + a
      i = i + 1
    }
    a = a % ADLER_MODULUS
    b = b % ADLER_MODULUS
    start = end
  }
  self.a = a
  self.b = b
}

///|
/// Fold a single byte into the running checksum. Lets a caller checksum bytes
/// it can only reach one at a time (e.g. read back from a `MutArrayView`
/// output) without materializing a `Bytes`.
pub fn Adler32::update_byte(self : Adler32, byte : Byte) -> Unit {
  self.a = (self.a + byte.to_int()) % ADLER_MODULUS
  self.b = (self.b + self.a) % ADLER_MODULUS
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
  let d = Adler32()
  d.update(data[:])
  d.finish()
}
