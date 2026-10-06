// Output-identity goldens for the encoders. Compressed bytes are not fixed by
// RFC 1951, but downstream users pin them (PDF writers, document snapshots),
// so performance work must not change them silently. Each line records the
// length and a 64-bit FNV-1a digest of one encoder output over a deterministic
// corpus. Update these snapshots only for intentional output changes.

///|
fn golden_fnv(data : BytesView) -> UInt64 {
  let mut h = 0xcbf29ce484222325UL
  for b in data {
    h = (h ^ b.to_uint64()) * 0x100000001b3UL
  }
  h
}

///|
fn golden_line(name : String, data : BytesView) -> String {
  let digest = golden_fnv(data).to_string(radix=16)
  "\{name}: \{data.length()} \{"0".repeat(16 - digest.length())}\{digest}\n"
}

///|
priv struct GoldenRng {
  mut state : UInt
}

///|
fn GoldenRng::next(self : GoldenRng) -> Int {
  self.state = self.state * 1103515245U + 12345U
  ((self.state >> 16) & 0x7FFFU).reinterpret_as_int()
}

///|
let golden_words : ReadOnlyArray[String] = [
  "the", "of", "and", "a", "to", "in", "is", "you", "that", "it", "he", "was", "for",
  "on", "are", "as", "with", "his", "they", "at", "be", "this", "have", "from", "or",
  "one", "had", "by", "word", "but", "not", "what", "all", "were", "compression",
  "stream", "window", "literal", "distance", "Huffman", "block",
]

///|
/// Word salad with punctuation and line breaks.
fn golden_text(size : Int, seed : UInt) -> Bytes {
  let rng = GoldenRng::{ state: seed, }
  let buf = Buffer()
  while buf.length() < size {
    buf.write_string_utf8(golden_words[rng.next() % golden_words.length()])
    match rng.next() % 16 {
      0 => buf.write_string_utf8(". ")
      1 => buf.write_string_utf8(",\n")
      _ => buf.write_byte(b' ')
    }
  }
  buf.to_bytes()[:size].to_owned()
}

///|
fn golden_random(size : Int, seed : UInt) -> Bytes {
  let rng = GoldenRng::{ state: seed, }
  Bytes::makei(size, _ => (rng.next() & 0xFF).to_byte())
}

///|
/// Text-showing operators with varying coordinates, like a PDF content stream.
fn golden_content_stream(size : Int, seed : UInt) -> Bytes {
  let rng = GoldenRng::{ state: seed, }
  let buf = Buffer()
  while buf.length() < size {
    let x = rng.next() % 600
    let y = rng.next() % 800
    let frac = rng.next() % 100
    buf.write_string_utf8(
      "BT\n/F\{rng.next() % 4} \{8 + rng.next() % 6} Tf\n1 0 0 -1 \{x}.\{frac} \{y} Tm\n[<",
    )
    for _ in 0..<(1 + rng.next() % 12) {
      let gid = rng.next() % 300
      for shift in [8, 4, 0] {
        let digit = (gid >> shift) & 15
        let code = if digit < 10 { 0x30 + digit } else { 0x37 + digit }
        buf.write_byte(code.to_byte())
      }
    }
    buf.write_string_utf8("> \{rng.next() % 500 - 250}] TJ\nET\n")
    if rng.next() % 5 == 0 {
      buf.write_string_utf8(
        "q\n0.\{rng.next() % 1000} 0 0 RG\n\{x} \{y} m \{x + 40} \{y} l S\nQ\n",
      )
    }
  }
  buf.to_bytes()[:size].to_owned()
}

///|
/// Big-endian 16/32-bit records with small deltas, like font tables.
fn golden_binary(size : Int, seed : UInt) -> Bytes {
  let rng = GoldenRng::{ state: seed, }
  let out = FixedArray::make(size, b'\x00')
  let mut value = 0
  let mut i = 0
  while i + 6 <= size {
    value = (value + rng.next() % 40) & 0xFFFF
    out[i] = (value >> 8).to_byte()
    out[i + 1] = (value & 0xFF).to_byte()
    out[i + 2] = b'\x00'
    out[i + 3] = (rng.next() % 3).to_byte()
    out[i + 4] = (rng.next() & 0xFF).to_byte()
    out[i + 5] = if rng.next() % 4 == 0 { b'\xFF' } else { b'\x00' }
    i += 6
  }
  Bytes::makei(size, i => out[i])
}

///|
/// Short periods, long single-byte runs and an exact repeat beyond 32 KiB.
fn golden_repetitive(size : Int, seed : UInt) -> Bytes {
  let rng = GoldenRng::{ state: seed, }
  let buf = Buffer()
  let head = golden_text(40000, seed + 1)
  buf.write_bytes(head)
  while buf.length() < size {
    match rng.next() % 3 {
      0 => {
        let byte = (rng.next() & 0xFF).to_byte()
        for _ in 0..<(rng.next() % 2000) {
          buf.write_byte(byte)
        }
      }
      1 => {
        let period = 1 + rng.next() % 9
        for k in 0..<(rng.next() % 1500) {
          buf.write_byte((k % period + 0x41).to_byte())
        }
      }
      _ => {
        let start = rng.next() % 30000
        buf.write_bytes(head[start:start + 300 + rng.next() % 600].to_owned())
      }
    }
  }
  buf.write_bytes(head)
  buf.to_bytes()
}

///|
fn golden_corpus() -> Array[(String, Bytes)] {
  let mixed = Buffer()
  mixed.write_bytes(golden_text(30000, 7))
  mixed.write_bytes(golden_random(20000, 8))
  mixed.write_bytes(golden_content_stream(30000, 9))
  mixed.write_bytes(golden_binary(20000, 10))
  [
    ("empty", b""),
    ("one", b"a"),
    ("three", b"abc"),
    ("five", b"aaaaa"),
    ("text-259", golden_text(259, 1)),
    ("text", golden_text(100000, 2)),
    ("random", golden_random(40000, 3)),
    ("content", golden_content_stream(120000, 4)),
    ("binary", golden_binary(60000, 5)),
    ("repetitive", golden_repetitive(90000, 6)),
    ("mixed", mixed.to_bytes()),
  ]
}

///|
/// Drive a streaming compressor with fixed input and output chunk sizes,
/// optionally requesting a sync flush after every input chunk.
fn golden_stream(
  input : Bytes,
  level : Int,
  in_chunk : Int,
  out_chunk : Int,
  sync_flush? : Bool = false,
  dictionary? : Bytes,
) -> Bytes {
  let deflater = match dictionary {
    Some(dict) => @flate.Deflater(level~, dictionary=dict)
    None => Deflater(level~)
  }
  let out = FixedArray::make(out_chunk, b'\x00')
  let result = Buffer()
  let mut pos = 0
  for ;; {
    let end = (pos + in_chunk).min(input.length())
    let action : @flate.DeflateAction = if end == input.length() {
      Finish
    } else if sync_flush {
      SyncFlush
    } else {
      Continue
    }
    let status = deflater.step(input[pos:end], out.mut_view(), action~)
    for i in 0..<deflater.last_produced() {
      result.write_byte(out[i])
    }
    pos += deflater.last_consumed()
    if status is Done {
      break
    }
  }
  result.to_bytes()
}

///|
test "deflate output goldens: one-shot and streaming, levels 0-9" {
  let buf = StringBuilder()
  let corpus = golden_corpus()
  for level in 0..<=9 {
    for entry in corpus {
      let (name, data) = entry
      let all = @flate.deflate_all(data, level~)
      buf.write_string(golden_line("L\{level} \{name} all", all))
      let stream = golden_stream(data, level, data.length() + 1, 65536)
      buf.write_string(golden_line("L\{level} \{name} stream", stream))
    }
  }
  inspect(
    buf.to_string(),
    content=(
      #|L0 empty all: 5 db1da3aeaa761262
      #|L0 empty stream: 5 db1da3aeaa761262
      #|L0 one all: 6 1847fcf4965aab91
      #|L0 one stream: 6 1847fcf4965aab91
      #|L0 three all: 8 a5d2ca09430b736e
      #|L0 three stream: 8 a5d2ca09430b736e
      #|L0 five all: 10 fbc1330c58953a25
      #|L0 five stream: 10 fbc1330c58953a25
      #|L0 text-259 all: 264 05c8e78d084e7e3b
      #|L0 text-259 stream: 264 05c8e78d084e7e3b
      #|L0 text all: 100010 e5c8828e0f0815c5
      #|L0 text stream: 100035 4f9df0b4db20a923
      #|L0 random all: 40005 4f1a98c89138d26f
      #|L0 random stream: 40015 aecea570d8eff403
      #|L0 content all: 120010 1492381fd5b261df
      #|L0 content stream: 120040 46bd3cec236589c3
      #|L0 binary all: 60005 3e77a36127a62520
      #|L0 binary stream: 60020 12160d4394dbbcc8
      #|L0 repetitive all: 130256 87d91efe8f39ee65
      #|L0 repetitive stream: 130286 3998f87c9755a869
      #|L0 mixed all: 100010 79f1a78946897740
      #|L0 mixed stream: 100035 970b10bc84dbd90c
      #|L1 empty all: 2 0835ee07b4ee5316
      #|L1 empty stream: 2 0835ee07b4ee5316
      #|L1 one all: 3 51aebd19d2425b1e
      #|L1 one stream: 3 51aebd19d2425b1e
      #|L1 three all: 5 62716ac1520c1ebe
      #|L1 three stream: 5 62716ac1520c1ebe
      #|L1 five all: 4 0e49d6e046c3b723
      #|L1 five stream: 4 0e49d6e046c3b723
      #|L1 text-259 all: 145 471346e2e94de027
      #|L1 text-259 stream: 145 471346e2e94de027
      #|L1 text all: 30114 95ee58b8812ba406
      #|L1 text stream: 30139 aaa5cad67d2fa979
      #|L1 random all: 40005 4f1a98c89138d26f
      #|L1 random stream: 40015 de5fea91be6ed88d
      #|L1 content all: 42865 c5d262cd92c3121a
      #|L1 content stream: 42782 9385fd34df62e246
      #|L1 binary all: 45159 84130d0c037d5673
      #|L1 binary stream: 45161 68bd8bf414a02efc
      #|L1 repetitive all: 27579 968888e85d169bb8
      #|L1 repetitive stream: 27519 8e053fb33dd00e96
      #|L1 mixed all: 59427 ffc2860e9efc8556
      #|L1 mixed stream: 56653 181b3341e57b1d36
      #|L2 empty all: 2 0835ee07b4ee5316
      #|L2 empty stream: 2 0835ee07b4ee5316
      #|L2 one all: 3 51aebd19d2425b1e
      #|L2 one stream: 3 51aebd19d2425b1e
      #|L2 three all: 5 62716ac1520c1ebe
      #|L2 three stream: 5 62716ac1520c1ebe
      #|L2 five all: 4 0e49d6e046c3b723
      #|L2 five stream: 4 0e49d6e046c3b723
      #|L2 text-259 all: 145 471346e2e94de027
      #|L2 text-259 stream: 145 471346e2e94de027
      #|L2 text all: 29453 636b80e64be97a20
      #|L2 text stream: 29450 3baaebd796d041ee
      #|L2 random all: 40005 4f1a98c89138d26f
      #|L2 random stream: 40015 de5fea91be6ed88d
      #|L2 content all: 41667 0bcb686c0ce61338
      #|L2 content stream: 41576 7dcb7adf9a045dba
      #|L2 binary all: 45157 0984c4759be50598
      #|L2 binary stream: 45159 8cc57dfcf9f4fdd2
      #|L2 repetitive all: 26473 9434f2ab6bb5ab22
      #|L2 repetitive stream: 26413 aca9b720f350c003
      #|L2 mixed all: 58801 db0a6a1434388b80
      #|L2 mixed stream: 56137 3c137a5cd8d4cb9e
      #|L3 empty all: 2 0835ee07b4ee5316
      #|L3 empty stream: 2 0835ee07b4ee5316
      #|L3 one all: 3 51aebd19d2425b1e
      #|L3 one stream: 3 51aebd19d2425b1e
      #|L3 three all: 5 62716ac1520c1ebe
      #|L3 three stream: 5 62716ac1520c1ebe
      #|L3 five all: 4 0e49d6e046c3b723
      #|L3 five stream: 4 0e49d6e046c3b723
      #|L3 text-259 all: 145 471346e2e94de027
      #|L3 text-259 stream: 145 471346e2e94de027
      #|L3 text all: 27830 1cd94daefe517c88
      #|L3 text stream: 27778 31fc8caca8a34861
      #|L3 random all: 40005 4f1a98c89138d26f
      #|L3 random stream: 40015 de5fea91be6ed88d
      #|L3 content all: 40571 06c1efe1e3fe8df5
      #|L3 content stream: 40460 bdb4af689a6b0a73
      #|L3 binary all: 45157 1d4c6ca80d6199fe
      #|L3 binary stream: 45158 292c3109298338cb
      #|L3 repetitive all: 25131 66fbf43c10dc3980
      #|L3 repetitive stream: 24991 a6235ba43ce75610
      #|L3 mixed all: 58026 e1f415c261268fc0
      #|L3 mixed stream: 55464 8f1cb2b9bfada1d4
      #|L4 empty all: 2 0835ee07b4ee5316
      #|L4 empty stream: 2 0835ee07b4ee5316
      #|L4 one all: 3 51aebd19d2425b1e
      #|L4 one stream: 3 51aebd19d2425b1e
      #|L4 three all: 5 62716ac1520c1ebe
      #|L4 three stream: 5 62716ac1520c1ebe
      #|L4 five all: 4 0e49d6e046c3b723
      #|L4 five stream: 4 0e49d6e046c3b723
      #|L4 text-259 all: 145 a4f84057274745ef
      #|L4 text-259 stream: 145 a4f84057274745ef
      #|L4 text all: 28607 be3f053d1318e4a9
      #|L4 text stream: 28619 7dbd98ce00fe760f
      #|L4 random all: 40005 4f1a98c89138d26f
      #|L4 random stream: 40015 de5fea91be6ed88d
      #|L4 content all: 40138 bdfd4d8f6ce51df0
      #|L4 content stream: 40112 a5fb890bbaa4619b
      #|L4 binary all: 43116 7d2339432497ab0b
      #|L4 binary stream: 42823 7096d3f7f420aae6
      #|L4 repetitive all: 25814 7cb538a693e16a68
      #|L4 repetitive stream: 25759 6e3645ed1d23296a
      #|L4 mixed all: 57622 dda4224c00be07f8
      #|L4 mixed stream: 55090 466ec0e6589cd891
      #|L5 empty all: 2 0835ee07b4ee5316
      #|L5 empty stream: 2 0835ee07b4ee5316
      #|L5 one all: 3 51aebd19d2425b1e
      #|L5 one stream: 3 51aebd19d2425b1e
      #|L5 three all: 5 62716ac1520c1ebe
      #|L5 three stream: 5 62716ac1520c1ebe
      #|L5 five all: 4 0e49d6e046c3b723
      #|L5 five stream: 4 0e49d6e046c3b723
      #|L5 text-259 all: 145 a4f84057274745ef
      #|L5 text-259 stream: 145 a4f84057274745ef
      #|L5 text all: 27718 c3ec401d42cecfc7
      #|L5 text stream: 27756 e4c222cb1a9c16e5
      #|L5 random all: 40005 4f1a98c89138d26f
      #|L5 random stream: 40015 de5fea91be6ed88d
      #|L5 content all: 39035 bd80e99215a0b778
      #|L5 content stream: 39028 a6998ec5b6bc0b18
      #|L5 binary all: 43118 b3d7f732d1118d9d
      #|L5 binary stream: 42824 0b1ba21ccf733851
      #|L5 repetitive all: 24955 2778c775f6792c56
      #|L5 repetitive stream: 24891 4c93f30dc1ff93f7
      #|L5 mixed all: 57183 6b2a0e2eeeb1120e
      #|L5 mixed stream: 54549 8de77ffa29356f33
      #|L6 empty all: 2 0835ee07b4ee5316
      #|L6 empty stream: 2 0835ee07b4ee5316
      #|L6 one all: 3 51aebd19d2425b1e
      #|L6 one stream: 3 51aebd19d2425b1e
      #|L6 three all: 5 62716ac1520c1ebe
      #|L6 three stream: 5 62716ac1520c1ebe
      #|L6 five all: 4 0e49d6e046c3b723
      #|L6 five stream: 4 0e49d6e046c3b723
      #|L6 text-259 all: 145 a4f84057274745ef
      #|L6 text-259 stream: 145 a4f84057274745ef
      #|L6 text all: 28408 88da5468c4f82502
      #|L6 text stream: 28509 79acf1238b457dfc
      #|L6 random all: 40005 4f1a98c89138d26f
      #|L6 random stream: 40015 de5fea91be6ed88d
      #|L6 content all: 37188 83b532624a592ecc
      #|L6 content stream: 37253 7ecaba12a8a644c3
      #|L6 binary all: 43757 5dacaf00847ad871
      #|L6 binary stream: 43693 3f3dae00bd46ec58
      #|L6 repetitive all: 25539 1078c30000213d58
      #|L6 repetitive stream: 25547 3a0df1647122ca82
      #|L6 mixed all: 57938 96b2a23a68019ecf
      #|L6 mixed stream: 54237 513bcd643ccc401d
      #|L7 empty all: 2 0835ee07b4ee5316
      #|L7 empty stream: 2 0835ee07b4ee5316
      #|L7 one all: 3 51aebd19d2425b1e
      #|L7 one stream: 3 51aebd19d2425b1e
      #|L7 three all: 5 62716ac1520c1ebe
      #|L7 three stream: 5 62716ac1520c1ebe
      #|L7 five all: 4 0e49d6e046c3b723
      #|L7 five stream: 4 0e49d6e046c3b723
      #|L7 text-259 all: 145 a4f84057274745ef
      #|L7 text-259 stream: 145 a4f84057274745ef
      #|L7 text all: 26267 60f644cca4fa8ab6
      #|L7 text stream: 26186 ee7e2e46eb5dca70
      #|L7 random all: 40005 4f1a98c89138d26f
      #|L7 random stream: 40015 de5fea91be6ed88d
      #|L7 content all: 38187 3dde2c046325c95e
      #|L7 content stream: 38142 f9ac81dca7091c41
      #|L7 binary all: 43118 b3d7f732d1118d9d
      #|L7 binary stream: 42824 0b1ba21ccf733851
      #|L7 repetitive all: 23933 794c61577d49b343
      #|L7 repetitive stream: 23768 1d4aa2ee3782f539
      #|L7 mixed all: 56730 4676445fefcb0b49
      #|L7 mixed stream: 54080 896b87dddcedfc93
      #|L8 empty all: 2 0835ee07b4ee5316
      #|L8 empty stream: 2 0835ee07b4ee5316
      #|L8 one all: 3 51aebd19d2425b1e
      #|L8 one stream: 3 51aebd19d2425b1e
      #|L8 three all: 5 62716ac1520c1ebe
      #|L8 three stream: 5 62716ac1520c1ebe
      #|L8 five all: 4 0e49d6e046c3b723
      #|L8 five stream: 4 0e49d6e046c3b723
      #|L8 text-259 all: 145 a4f84057274745ef
      #|L8 text-259 stream: 145 a4f84057274745ef
      #|L8 text all: 26282 41948cf07419cba5
      #|L8 text stream: 26202 411f98a6732f1d64
      #|L8 random all: 40005 4f1a98c89138d26f
      #|L8 random stream: 40015 de5fea91be6ed88d
      #|L8 content all: 37975 05ea41cbe9f5132f
      #|L8 content stream: 37928 85603bc6b7b945df
      #|L8 binary all: 43118 b3d7f732d1118d9d
      #|L8 binary stream: 42824 0b1ba21ccf733851
      #|L8 repetitive all: 23923 3890cf82c851a3ef
      #|L8 repetitive stream: 23760 3928a212b3dc4a6e
      #|L8 mixed all: 56707 6f1815239e0e7612
      #|L8 mixed stream: 54051 5a1417f980a7a140
      #|L9 empty all: 2 0835ee07b4ee5316
      #|L9 empty stream: 2 0835ee07b4ee5316
      #|L9 one all: 3 51aebd19d2425b1e
      #|L9 one stream: 3 51aebd19d2425b1e
      #|L9 three all: 5 62716ac1520c1ebe
      #|L9 three stream: 5 62716ac1520c1ebe
      #|L9 five all: 4 0e49d6e046c3b723
      #|L9 five stream: 4 0e49d6e046c3b723
      #|L9 text-259 all: 145 a4f84057274745ef
      #|L9 text-259 stream: 145 a4f84057274745ef
      #|L9 text all: 26282 41948cf07419cba5
      #|L9 text stream: 26202 411f98a6732f1d64
      #|L9 random all: 40005 4f1a98c89138d26f
      #|L9 random stream: 40015 de5fea91be6ed88d
      #|L9 content all: 37975 05ea41cbe9f5132f
      #|L9 content stream: 37928 85603bc6b7b945df
      #|L9 binary all: 43118 b3d7f732d1118d9d
      #|L9 binary stream: 42824 0b1ba21ccf733851
      #|L9 repetitive all: 23923 3890cf82c851a3ef
      #|L9 repetitive stream: 23760 3928a212b3dc4a6e
      #|L9 mixed all: 56707 6f1815239e0e7612
      #|L9 mixed stream: 54051 5a1417f980a7a140
      #|
    ),
  )
}

///|
test "deflate output goldens: streaming chunking, flushes and dictionaries" {
  let buf = StringBuilder()
  let corpus = golden_corpus()
  for level in [1, 4, 6, 9] {
    for entry in corpus {
      let (name, data) = entry
      let small = golden_stream(data, level, 4093, 1021)
      buf.write_string(golden_line("L\{level} \{name} chunked", small))
      let flushed = golden_stream(data, level, 9000, 4096, sync_flush=true)
      buf.write_string(golden_line("L\{level} \{name} sync", flushed))
    }
  }
  let dictionary = golden_text(40000, 11)
  for entry in corpus {
    let (name, data) = entry
    let with_dict = golden_stream(data, 6, 5000, 777, dictionary~)
    buf.write_string(golden_line("L6 \{name} dict", with_dict))
  }
  let tiny = golden_content_stream(5000, 12)
  buf.write_string(
    golden_line("L6 content bytewise", golden_stream(tiny, 6, 1, 1)),
  )
  inspect(
    buf.to_string(),
    content=(
      #|L1 empty chunked: 2 0835ee07b4ee5316
      #|L1 empty sync: 2 0835ee07b4ee5316
      #|L1 one chunked: 3 51aebd19d2425b1e
      #|L1 one sync: 3 51aebd19d2425b1e
      #|L1 three chunked: 5 62716ac1520c1ebe
      #|L1 three sync: 5 62716ac1520c1ebe
      #|L1 five chunked: 4 0e49d6e046c3b723
      #|L1 five sync: 4 0e49d6e046c3b723
      #|L1 text-259 chunked: 145 471346e2e94de027
      #|L1 text-259 sync: 145 471346e2e94de027
      #|L1 text chunked: 30139 aaa5cad67d2fa979
      #|L1 text sync: 30289 58fec3b58a062256
      #|L1 random chunked: 40015 de5fea91be6ed88d
      #|L1 random sync: 40045 ea9cc809cb955e4b
      #|L1 content chunked: 42782 9385fd34df62e246
      #|L1 content sync: 42978 2fd9d6812e8a4648
      #|L1 binary chunked: 45161 68bd8bf414a02efc
      #|L1 binary sync: 44992 d198b8574cc8b6e2
      #|L1 repetitive chunked: 27519 8e053fb33dd00e96
      #|L1 repetitive sync: 27759 47478cbdb5130431
      #|L1 mixed chunked: 56653 181b3341e57b1d36
      #|L1 mixed sync: 56296 1d74d3ffe2d85946
      #|L4 empty chunked: 2 0835ee07b4ee5316
      #|L4 empty sync: 2 0835ee07b4ee5316
      #|L4 one chunked: 3 51aebd19d2425b1e
      #|L4 one sync: 3 51aebd19d2425b1e
      #|L4 three chunked: 5 62716ac1520c1ebe
      #|L4 three sync: 5 62716ac1520c1ebe
      #|L4 five chunked: 4 0e49d6e046c3b723
      #|L4 five sync: 4 0e49d6e046c3b723
      #|L4 text-259 chunked: 145 a4f84057274745ef
      #|L4 text-259 sync: 145 a4f84057274745ef
      #|L4 text chunked: 28619 7dbd98ce00fe760f
      #|L4 text sync: 28775 1c43c15dbb69b68d
      #|L4 random chunked: 40015 de5fea91be6ed88d
      #|L4 random sync: 40045 ea9cc809cb955e4b
      #|L4 content chunked: 40112 a5fb890bbaa4619b
      #|L4 content sync: 40317 c100357dfe4924a9
      #|L4 binary chunked: 42823 7096d3f7f420aae6
      #|L4 binary sync: 42551 e5d9f5c016c500f1
      #|L4 repetitive chunked: 25759 6e3645ed1d23296a
      #|L4 repetitive sync: 25956 190329a8fa9711bf
      #|L4 mixed chunked: 55090 466ec0e6589cd891
      #|L4 mixed sync: 54625 7338f84e9af82825
      #|L6 empty chunked: 2 0835ee07b4ee5316
      #|L6 empty sync: 2 0835ee07b4ee5316
      #|L6 one chunked: 3 51aebd19d2425b1e
      #|L6 one sync: 3 51aebd19d2425b1e
      #|L6 three chunked: 5 62716ac1520c1ebe
      #|L6 three sync: 5 62716ac1520c1ebe
      #|L6 five chunked: 4 0e49d6e046c3b723
      #|L6 five sync: 4 0e49d6e046c3b723
      #|L6 text-259 chunked: 145 a4f84057274745ef
      #|L6 text-259 sync: 145 a4f84057274745ef
      #|L6 text chunked: 28509 79acf1238b457dfc
      #|L6 text sync: 28707 e37be789446dfd5f
      #|L6 random chunked: 40015 de5fea91be6ed88d
      #|L6 random sync: 40045 ea9cc809cb955e4b
      #|L6 content chunked: 37253 7ecaba12a8a644c3
      #|L6 content sync: 37503 f395b0a91a25f1ff
      #|L6 binary chunked: 43693 3f3dae00bd46ec58
      #|L6 binary sync: 43504 ecf38393953ffb21
      #|L6 repetitive chunked: 25547 3a0df1647122ca82
      #|L6 repetitive sync: 25807 c109480fdde6eec8
      #|L6 mixed chunked: 54237 513bcd643ccc401d
      #|L6 mixed sync: 53863 9eec6437454b874e
      #|L9 empty chunked: 2 0835ee07b4ee5316
      #|L9 empty sync: 2 0835ee07b4ee5316
      #|L9 one chunked: 3 51aebd19d2425b1e
      #|L9 one sync: 3 51aebd19d2425b1e
      #|L9 three chunked: 5 62716ac1520c1ebe
      #|L9 three sync: 5 62716ac1520c1ebe
      #|L9 five chunked: 4 0e49d6e046c3b723
      #|L9 five sync: 4 0e49d6e046c3b723
      #|L9 text-259 chunked: 145 a4f84057274745ef
      #|L9 text-259 sync: 145 a4f84057274745ef
      #|L9 text chunked: 26202 411f98a6732f1d64
      #|L9 text sync: 26367 4b53be9c9edf0032
      #|L9 random chunked: 40015 de5fea91be6ed88d
      #|L9 random sync: 40045 ea9cc809cb955e4b
      #|L9 content chunked: 37928 85603bc6b7b945df
      #|L9 content sync: 38132 2cbf2eda21683816
      #|L9 binary chunked: 42824 0b1ba21ccf733851
      #|L9 binary sync: 42551 666636331e896658
      #|L9 repetitive chunked: 23760 3928a212b3dc4a6e
      #|L9 repetitive sync: 23970 b52d2d06c71070a6
      #|L9 mixed chunked: 54051 5a1417f980a7a140
      #|L9 mixed sync: 53581 6cfdf9cfafaad732
      #|L6 empty dict: 2 0835ee07b4ee5316
      #|L6 one dict: 3 51aebd19d2425b1e
      #|L6 three dict: 5 62716ac1520c1ebe
      #|L6 five dict: 4 0e49d6e046c3b723
      #|L6 text-259 dict: 83 761c50eabe9c631e
      #|L6 text dict: 28146 c60ac9a041693e8f
      #|L6 random dict: 40015 de5fea91be6ed88d
      #|L6 content dict: 37253 7ecaba12a8a644c3
      #|L6 binary dict: 43693 3f3dae00bd46ec58
      #|L6 repetitive dict: 25218 13c7e13887ee435c
      #|L6 mixed dict: 53904 ab92906acbb49f5c
      #|L6 content bytewise: 1666 421e079126453631
      #|
    ),
  )
}

///|
test "deflate output goldens: other whole-buffer encoders" {
  let buf = StringBuilder()
  let corpus = golden_corpus()
  let compressor = @flate.Compressor(level=6)
  for entry in corpus {
    let (name, data) = entry
    buf.write_string(
      golden_line("L6 \{name} compressor", compressor.compress(data)),
    )
    let out = FixedArray::make(@flate.deflate_bound(data.length()), b'\x00')
    let n = @flate.deflate_into(data, out, level=6).unwrap()
    let into = Bytes::makei(n, i => out[i])
    buf.write_string(golden_line("L6 \{name} into", into))
    for level in [1, 6, 9] {
      buf.write_string(
        golden_line(
          "L\{level} \{name} split",
          @flate.deflate_all_split(data, level~),
        ),
      )
    }
    buf.write_string(
      golden_line(
        "\{name} optimal",
        @flate.deflate_all_optimal(data, iterations=2),
      ),
    )
    buf.write_string(
      golden_line(
        "L6 \{name} fast_store",
        @flate.deflate_all(data, level=6, fast_store=true),
      ),
    )
  }
  inspect(
    buf.to_string(),
    content=(
      #|L6 empty compressor: 2 0835ee07b4ee5316
      #|L6 empty into: 2 0835ee07b4ee5316
      #|L1 empty split: 2 0835ee07b4ee5316
      #|L6 empty split: 2 0835ee07b4ee5316
      #|L9 empty split: 2 0835ee07b4ee5316
      #|empty optimal: 2 0835ee07b4ee5316
      #|L6 empty fast_store: 2 0835ee07b4ee5316
      #|L6 one compressor: 3 51aebd19d2425b1e
      #|L6 one into: 3 51aebd19d2425b1e
      #|L1 one split: 3 51aebd19d2425b1e
      #|L6 one split: 3 51aebd19d2425b1e
      #|L9 one split: 3 51aebd19d2425b1e
      #|one optimal: 3 51aebd19d2425b1e
      #|L6 one fast_store: 3 51aebd19d2425b1e
      #|L6 three compressor: 5 62716ac1520c1ebe
      #|L6 three into: 5 62716ac1520c1ebe
      #|L1 three split: 5 62716ac1520c1ebe
      #|L6 three split: 5 62716ac1520c1ebe
      #|L9 three split: 5 62716ac1520c1ebe
      #|three optimal: 5 62716ac1520c1ebe
      #|L6 three fast_store: 5 62716ac1520c1ebe
      #|L6 five compressor: 4 0e49d6e046c3b723
      #|L6 five into: 4 0e49d6e046c3b723
      #|L1 five split: 4 0e49d6e046c3b723
      #|L6 five split: 4 0e49d6e046c3b723
      #|L9 five split: 4 0e49d6e046c3b723
      #|five optimal: 4 0e49d6e046c3b723
      #|L6 five fast_store: 4 0e49d6e046c3b723
      #|L6 text-259 compressor: 145 a4f84057274745ef
      #|L6 text-259 into: 145 a4f84057274745ef
      #|L1 text-259 split: 145 471346e2e94de027
      #|L6 text-259 split: 145 a4f84057274745ef
      #|L9 text-259 split: 145 a4f84057274745ef
      #|text-259 optimal: 143 96a26507d7e254b8
      #|L6 text-259 fast_store: 145 a4f84057274745ef
      #|L6 text compressor: 28408 88da5468c4f82502
      #|L6 text into: 28408 88da5468c4f82502
      #|L1 text split: 30114 95ee58b8812ba406
      #|L6 text split: 28338 84f4e02c30e8b173
      #|L9 text split: 26070 58a6cb56b58f3ec8
      #|text optimal: 24737 af2f8c9b70be0a7c
      #|L6 text fast_store: 28408 88da5468c4f82502
      #|L6 random compressor: 40005 4f1a98c89138d26f
      #|L6 random into: 40005 4f1a98c89138d26f
      #|L1 random split: 40005 4f1a98c89138d26f
      #|L6 random split: 40005 4f1a98c89138d26f
      #|L9 random split: 40005 4f1a98c89138d26f
      #|random optimal: 40005 4f1a98c89138d26f
      #|L6 random fast_store: 40005 4f1a98c89138d26f
      #|L6 content compressor: 37188 83b532624a592ecc
      #|L6 content into: 37188 83b532624a592ecc
      #|L1 content split: 42593 75af0afe18e3f0cd
      #|L6 content split: 37188 83b532624a592ecc
      #|L9 content split: 37779 576876dee681fabb
      #|content optimal: 35175 f0cbb0fdbaf76be0
      #|L6 content fast_store: 37188 83b532624a592ecc
      #|L6 binary compressor: 43757 5dacaf00847ad871
      #|L6 binary into: 43757 5dacaf00847ad871
      #|L1 binary split: 45086 77279b7a802b40f0
      #|L6 binary split: 43641 e8ead7e11b8e737d
      #|L9 binary split: 42672 e7b063a27972cf06
      #|binary optimal: 42027 1a1d66372eacd713
      #|L6 binary fast_store: 43757 5dacaf00847ad871
      #|L6 repetitive compressor: 25539 1078c30000213d58
      #|L6 repetitive into: 25539 1078c30000213d58
      #|L1 repetitive split: 27579 968888e85d169bb8
      #|L6 repetitive split: 25474 d9d624b6ef848a17
      #|L9 repetitive split: 23923 3890cf82c851a3ef
      #|repetitive optimal: 22462 50fcc47ba74e7782
      #|L6 repetitive fast_store: 25539 1078c30000213d58
      #|L6 mixed compressor: 57938 96b2a23a68019ecf
      #|L6 mixed into: 57938 96b2a23a68019ecf
      #|L1 mixed split: 56035 eecbfd5375991c25
      #|L6 mixed split: 53167 1a7577cdd79f7a07
      #|L9 mixed split: 53541 9c45c4d32d724c6f
      #|mixed optimal: 51371 191c59889a360e9a
      #|L6 mixed fast_store: 57938 96b2a23a68019ecf
      #|
    ),
  )
}

///|
/// Fold one streaming step (status, counts and produced bytes) into a digest.
fn golden_step_digest(
  h : UInt64,
  status : @flate.Status,
  consumed : Int,
  produced : Int,
  out : FixedArray[Byte],
) -> UInt64 {
  let mut h = h
  let code = match status {
    Done => 1
    NeedMoreInput => 2
    NeedMoreOutput => 3
  }
  for value in [code, consumed, produced] {
    h = (h ^ value.to_uint64()) * 0x100000001b3UL
  }
  for i in 0..<produced {
    h = (h ^ out[i].to_uint64()) * 0x100000001b3UL
  }
  h
}

///|
test "deflate output goldens: randomized streaming schedules with reuse" {
  let corpus = golden_corpus()
  let source = Buffer()
  for entry in corpus {
    source.write_bytes(entry.1)
  }
  let source = source.to_bytes()
  let buf = StringBuilder()
  for seed in 0..<24 {
    let rng = GoldenRng::{
      state: seed.reinterpret_as_uint() * 2654435761U + 1,
    }
    let level = rng.next() % 10
    let fast_store = rng.next() % 4 == 0
    let deflater = @flate.Deflater(level~, fast_store~)
    let mut h = 0xcbf29ce484222325UL
    let mut steps = 0
    for stream in 0..<3 {
      if stream > 0 {
        if rng.next() % 2 == 0 {
          let start = rng.next() * 7 % (source.length() - 50000)
          let length = rng.next() % 3 * 17000 + rng.next() % 100
          deflater.reset(dictionary=source[start:start + length])
        } else {
          deflater.reset()
        }
      }
      let start = rng.next() * 13 % (source.length() - 140000)
      let input = source[start:start + rng.next() * 5 % 140000]
      let mut pos = 0
      for ;; {
        let in_chunk = match rng.next() % 4 {
          0 => 0
          1 => rng.next() % 300
          _ => rng.next() % 30000
        }
        let end = (pos + in_chunk).min(input.length())
        let action : @flate.DeflateAction = if end == input.length() {
          Finish
        } else if rng.next() % 6 == 0 {
          SyncFlush
        } else {
          Continue
        }
        let out = FixedArray::make(
          if rng.next() % 8 == 0 {
            0
          } else {
            1 + rng.next() % 9000
          },
          b'\x00',
        )
        let status = deflater.step(input[pos:end], out.mut_view(), action~)
        h = golden_step_digest(
          h,
          status,
          deflater.last_consumed(),
          deflater.last_produced(),
          out,
        )
        pos += deflater.last_consumed()
        steps += 1
        if status is Done {
          break
        }
      }
    }
    let digest = h.to_string(radix=16)
    buf.write_string(
      "seed \{seed} L\{level} fast_store=\{fast_store}: \{steps} steps \{"0".repeat(16 - digest.length())}\{digest}\n",
    )
  }
  inspect(
    buf.to_string(),
    content=(
      #|seed 0 L8 fast_store=false: 77 steps 67887a94f9554bd2
      #|seed 1 L7 fast_store=false: 56 steps bae1a4eb4a92069a
      #|seed 2 L3 fast_store=false: 26 steps aa03948aa6f64ed9
      #|seed 3 L2 fast_store=true: 65 steps 33400cbde3483614
      #|seed 4 L1 fast_store=true: 73 steps 894723c1ed491f98
      #|seed 5 L8 fast_store=false: 51 steps ae2eed9667ee25e6
      #|seed 6 L6 fast_store=false: 66 steps cf7ce7f1eed00e6d
      #|seed 7 L5 fast_store=false: 72 steps c44e3ccd7246f725
      #|seed 8 L2 fast_store=false: 52 steps c10ee741fdc44e9e
      #|seed 9 L1 fast_store=false: 50 steps 2c321ffe42829d1f
      #|seed 10 L9 fast_store=true: 38 steps 8b06ed2cc73e203d
      #|seed 11 L6 fast_store=false: 31 steps 5d1b8f1fd5dbb435
      #|seed 12 L5 fast_store=false: 78 steps fe6dd78aa42b90af
      #|seed 13 L4 fast_store=false: 66 steps 086981f1519a94a4
      #|seed 14 L0 fast_store=false: 87 steps a0b9381511aa6b93
      #|seed 15 L9 fast_store=false: 34 steps d0c7c4c857467c29
      #|seed 16 L8 fast_store=true: 62 steps 4426f6c79731b1b1
      #|seed 17 L5 fast_store=true: 58 steps 20cd80b2f82ec5e7
      #|seed 18 L3 fast_store=false: 64 steps 055c6cadd47a180e
      #|seed 19 L2 fast_store=false: 54 steps 5be4f35c1b65f5b4
      #|seed 20 L9 fast_store=false: 22 steps a2f8832c671a0530
      #|seed 21 L8 fast_store=false: 71 steps 2704f090feb63081
      #|seed 22 L6 fast_store=false: 71 steps ec5502c5057b6263
      #|seed 23 L3 fast_store=true: 76 steps 2041b6c7598f233c
      #|
    ),
  )
}
