///|
fn match_len_fixture(mismatch? : Int) -> Bytes {
  let data = Array::make(516, b'\x00')
  for i in 0..<258 {
    let byte = ((i * 37 + i / 7) & 0xFF).to_byte()
    data[i] = byte
    data[258 + i] = byte
  }
  match mismatch {
    Some(index) =>
      data[258 + index] = (data[258 + index].to_int() ^ 0xFF).to_byte()
    None => ()
  }
  Bytes::from_array(data)
}

///|
fn scalar_match_len_up_to_reference(
  data : Bytes,
  src : Int,
  pos : Int,
  limit : Int,
) -> Int {
  let mut k = 0
  while k < limit && data[src + k] == data[pos + k] {
    k = k + 1
  }
  k
}

///|
priv struct MatchLenDifferentialRng {
  mut state : UInt
}

///|
fn MatchLenDifferentialRng::new(seed : UInt) -> MatchLenDifferentialRng {
  { state: seed }
}

///|
fn MatchLenDifferentialRng::next(self : MatchLenDifferentialRng) -> UInt {
  self.state = self.state * 1664525U + 1013904223U
  self.state
}

///|
fn MatchLenDifferentialRng::below(
  self : MatchLenDifferentialRng,
  maximum : Int,
) -> Int {
  (self.next() >> 1).reinterpret_as_int() % maximum
}

///|
fn assert_match_len_differential_case(
  rng : MatchLenDifferentialRng,
  case_index : Int,
  src : Int,
  pos : Int,
  limit : Int,
  mismatch : Int,
) -> Unit {
  let bytes = Array::make(768, b'\x00')
  for i in 0..<bytes.length() {
    bytes[i] = (rng.next() >> 24).reinterpret_as_int().to_byte()
  }
  for i in 0..<limit {
    bytes[pos + i] = bytes[src + i]
  }
  if mismatch >= 0 && mismatch < limit {
    bytes[pos + mismatch] = (bytes[pos + mismatch].to_int() ^ 0xFF).to_byte()
  }
  let data = Bytes::from_array(bytes)
  let expected = scalar_match_len_up_to_reference(data, src, pos, limit)
  let actual = match_len_up_to(data, src, pos, limit)
  if actual != expected {
    abort(
      "match_len_up_to differential mismatch: case=\{case_index}, src=\{src}, pos=\{pos}, limit=\{limit}, mismatch=\{mismatch}, expected=\{expected}, actual=\{actual}",
    )
  }
}

///|
test "packed tokens preserve all DEFLATE boundaries" {
  let lengths = [3, 3, 258, 258]
  let distances = [1, 32768, 1, 32768]
  for i in 0..<lengths.length() {
    let length = lengths[i]
    let distance = distances[i]
    let token = pack_match_token(length, distance)
    assert_true(token > 255)
    assert_true(token < 1 << 25)
    assert_eq(token >> 16, length)
    assert_eq(token & 0xFFFF, distance)
  }
}

///|
test "v128 match length finds the first unequal lane and scalar tail" {
  for mismatch in [0, 1, 2, 15, 16, 17, 31, 32, 127, 255, 257] {
    let data = match_len_fixture(mismatch~)
    assert_eq(match_len_up_to(data, 0, 258, 258), mismatch)
  }
  let identical = match_len_fixture()
  assert_eq(match_len_up_to(identical, 0, 258, 258), 258)
  assert_eq(match_len_up_to(b"abcabcX", 0, 3, 4), 3)
}

///|
test "match length agrees with scalar reference across boundaries and tails" {
  let rng = MatchLenDifferentialRng::new(0x51DDFEEDU)
  let limits = [
    0, 1, 2, 7, 15, 16, 17, 18, 31, 32, 33, 47, 48, 49, 63, 64, 65, 127, 128, 129,
    255, 256, 257, 258,
  ]
  let mut case_index = 0
  for limit in limits {
    let src = case_index * 7 % 96
    let pos = 384 + case_index * 11 % 96
    assert_match_len_differential_case(rng, case_index, src, pos, limit, -1)
    case_index = case_index + 1
    if limit > 0 {
      assert_match_len_differential_case(
        rng,
        case_index,
        src,
        pos,
        limit,
        limit - 1,
      )
      case_index = case_index + 1
    }
  }
  for
    mismatch in [
      0, 1, 14, 15, 16, 17, 30, 31, 32, 33, 47, 48, 49, 63, 64, 65, 127, 128, 129,
      255, 256, 257,
    ] {
    assert_match_len_differential_case(
      rng,
      case_index,
      mismatch * 5 % 96,
      384 + mismatch * 13 % 96,
      258,
      mismatch,
    )
    case_index = case_index + 1
  }
  for _ in 0..<512 {
    let src = rng.below(96)
    let pos = 384 + rng.below(96)
    let limit = rng.below(259)
    let mismatch = if limit == 0 || rng.below(4) == 0 {
      -1
    } else {
      rng.below(limit)
    }
    assert_match_len_differential_case(
      rng, case_index, src, pos, limit, mismatch,
    )
    case_index = case_index + 1
  }
}
