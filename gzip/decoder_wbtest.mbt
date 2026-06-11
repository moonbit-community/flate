///|
/// Header-phase memory must be O(1): FNAME bytes are discarded as they
/// arrive, never banked in `pending`, so an adversarial unterminated FNAME
/// cannot grow decoder memory.
test "gzip header FNAME bytes are discarded, not retained" {
  let dec = Decoder::new()
  let obuf = FixedArray::make(1, b'\x00')
  // Fixed header with FLG = FNAME only.
  let hdr : Bytes = [0x1F, 0x8B, 0x08, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF]
  let (_st, _c, _p) = dec.step(hdr[:], obuf.mut_view())
  // 64 KB of name bytes with no terminator, fed in 1 KB chunks.
  let chunk = Bytes::make(1024, b'x')
  for _i in 0..<64 {
    let (_st2, _c2, _p2) = dec.step(chunk[:], obuf.mut_view())
    assert_eq(dec.pending.length(), 0)
  }
}
