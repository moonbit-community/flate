// Output-identity goldens for the zlib wrapper (header, DEFLATE body and
// Adler-32 trailer). See `encode_golden_test.mbt` in the root package.

///|
fn golden_fnv(data : BytesView) -> String {
  let mut h = 0xcbf29ce484222325UL
  for b in data {
    h = (h ^ b.to_uint64()) * 0x100000001b3UL
  }
  let digest = h.to_string(radix=16)
  "\{data.length()} \{"0".repeat(16 - digest.length())}\{digest}"
}

///|
fn golden_input(size : Int, seed : UInt, alphabet : Int) -> Bytes {
  let mut state = seed
  Bytes::makei(size, _ => {
    state = state * 1103515245U + 12345U
    let r = ((state >> 16) & 0x7FFFU).reinterpret_as_int()
    // Small alphabets compress; the full byte range exercises Adler-32 sums.
    if r % 7 == 0 {
      b' '
    } else {
      (0x41 + r % alphabet).to_byte()
    }
  })
}

///|
/// The PDF-writer driving pattern: one `Finish` step per call with a fixed
/// 32 KiB output window, re-presenting the unconsumed suffix.
fn golden_zlib_stream(input : Bytes, level : Int, out_chunk : Int) -> Bytes {
  let encoder = @zlib.Encoder(level~)
  let out = FixedArray::make(out_chunk, b'\x00')
  let result = Buffer()
  for pos = 0 {
    let status = encoder.step(input[pos:], out.mut_view(), action=Finish)
    for i in 0..<encoder.last_produced() {
      result.write_byte(out[i])
    }
    if status is Done {
      break result.to_bytes()
    }
    continue pos + encoder.last_consumed()
  }
}

///|
test "zlib output goldens" {
  let buf = StringBuilder()
  let inputs = [
    ("empty", b""),
    ("one", b"\xff"),
    ("text", golden_input(70000, 1, 20)),
    ("binary", golden_input(50000, 2, 190)),
    ("long", golden_input(200000, 3, 6)),
  ]
  for entry in inputs {
    let (name, data) = entry
    for level in [0, 1, 6, 9] {
      buf.write_string(
        "L\{level} \{name} compress: \{golden_fnv(@zlib.zlib_compress(data, level~))}\n",
      )
      buf.write_string(
        "L\{level} \{name} stream: \{golden_fnv(golden_zlib_stream(data, level, 32768))}\n",
      )
    }
    buf.write_string(
      "L6 \{name} small output: \{golden_fnv(golden_zlib_stream(data, 6, 17))}\n",
    )
  }
  inspect(
    buf.to_string(),
    content=(
      #|L0 empty compress: 11 7b0d1697cc314eec
      #|L0 empty stream: 11 7b0d1697cc314eec
      #|L1 empty compress: 8 cdbaa16f4cacd636
      #|L1 empty stream: 8 cdbaa16f4cacd636
      #|L6 empty compress: 8 cdbaa16f4cacd636
      #|L6 empty stream: 8 cdbaa16f4cacd636
      #|L9 empty compress: 8 cdbaa16f4cacd636
      #|L9 empty stream: 8 cdbaa16f4cacd636
      #|L6 empty small output: 8 cdbaa16f4cacd636
      #|L0 one compress: 12 d2f4072dd583d910
      #|L0 one stream: 12 d2f4072dd583d910
      #|L1 one compress: 9 01cdcee3b40e80cc
      #|L1 one stream: 9 01cdcee3b40e80cc
      #|L6 one compress: 9 01cdcee3b40e80cc
      #|L6 one stream: 9 01cdcee3b40e80cc
      #|L9 one compress: 9 01cdcee3b40e80cc
      #|L9 one stream: 9 01cdcee3b40e80cc
      #|L6 one small output: 9 01cdcee3b40e80cc
      #|L0 text compress: 70016 f4ee5dcee121bd7c
      #|L0 text stream: 70031 86bc7bf5d63432d0
      #|L1 text compress: 43964 faf93064c3d66276
      #|L1 text stream: 43476 befa4b71076e0ed1
      #|L6 text compress: 38670 72b9356515862c81
      #|L6 text stream: 38682 70721a05d6ef558b
      #|L9 text compress: 43656 e89e5e57f4a56049
      #|L9 text stream: 43122 3418b18b7beac27f
      #|L6 text small output: 38682 70721a05d6ef558b
      #|L0 binary compress: 50011 b0b61a20d8000e46
      #|L0 binary stream: 50026 913932a9909c5cf4
      #|L1 binary compress: 45706 2f9bcda82411359f
      #|L1 binary stream: 45779 e150faae58e38a2e
      #|L6 binary compress: 45401 d99a0770245ea8d1
      #|L6 binary stream: 45509 cdf5cb1a2ad873e3
      #|L9 binary compress: 45706 5349c13f93c46223
      #|L9 binary stream: 45780 605d8c292b7c43ba
      #|L6 binary small output: 45509 cdf5cb1a2ad873e3
      #|L0 long compress: 200026 34ff8f8fd2a14228
      #|L0 long stream: 200071 c5423fda9cb2a7bc
      #|L1 long compress: 82829 a6a80fef1b8c9ef4
      #|L1 long stream: 82915 dc4cf0b3ee5291de
      #|L6 long compress: 74507 728b568eb7bbd8a9
      #|L6 long stream: 74622 95163a5f82cf2f37
      #|L9 long compress: 80577 45296312b965eab1
      #|L9 long stream: 80129 fd552152c482e5fc
      #|L6 long small output: 74622 95163a5f82cf2f37
      #|
    ),
  )
}
