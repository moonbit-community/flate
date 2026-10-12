// The streaming inflater decodes whole units with local state while a step
// has eight bytes of input and 258 bytes of output room in hand (native).
// With less room every unit takes the careful path. Both must give the same
// bytes, the same consumption (bytes behind the stream stay unread) and the
// same verdict on damaged streams.

///|
priv struct FastStreamRun {
  decoded : Bytes
  consumed : Int32
  verdict : String
} derive(Eq, @debug.Debug)

///|
/// Decode `input` in chunks of `chunk` bytes into `room` bytes of output per
/// step, through a fixed array or a view.
fn fast_stream_run(
  input : Bytes,
  chunk : Int32,
  room : Int32,
  fixed : Bool,
) -> FastStreamRun {
  let inflater = Inflater()
  let output = FixedArray::make(room, b'\x00')
  let decoded = @buffer.Buffer()
  let mut position = 0
  let mut verdict = "done"
  for ;; {
    let end = (position + chunk).min(input.length())
    let status = try {
      if fixed {
        inflater.step_into(
          input[position:end],
          output,
          end=end == input.length(),
        )
      } else {
        inflater.step(
          input[position:end],
          output.mut_view(),
          end=end == input.length(),
        )
      }
    } catch {
      InflateError(kind, _) => {
        verdict = @debug.to_string(kind)
        break
      }
    }
    position = position + inflater.last_consumed()
    for i in 0..<inflater.last_produced() {
      decoded.write_byte(output[i])
    }
    if status is Done {
      break
    }
  }
  // What a failed stream produced before failing depends on the schedule.
  {
    decoded: if verdict == "done" {
      decoded.to_bytes()
    } else {
      b""
    },
    consumed: if verdict == "done" {
      position
    } else {
      0
    },
    verdict,
  }
}

///|
#cfg(target="native")
fn fast_stream_sources() -> Array[Bytes] {
  let words : ReadOnlyArray[Bytes] = [
    b"the ", b"window ", b"of ", b"a ", b"stream ", b"literal ", b"match ", b"0123456789 ",
    b"BT /F1 12 Tf ", b"<0A1B2C> ", b"\n",
  ]
  let rng = InflateDifferentialRng(0xFA57D0C5U)
  let text = @buffer.Buffer()
  while text.length() < 100000 {
    text.write_bytes(words[rng.size(words.length()) - 1])
    if rng.size(40) == 1 {
      // a long match far back, and a run of distance one
      text.write_bytes(text.to_bytes()[:rng.size(300)].to_owned())
      text.write_bytes(Bytes::make(rng.size(400), b'='))
    }
  }
  let mixed = @buffer.Buffer()
  mixed.write_bytes(inflate_differential_random_bytes(0xFA57D0C6U, 20000, 256))
  mixed.write_bytes(inflate_differential_pattern(b"moonbit-flate-", 30000))
  mixed.write_bytes(inflate_differential_random_bytes(0xFA57D0C7U, 20000, 7))
  [
    text.to_bytes(),
    mixed.to_bytes(),
    Bytes::make(70000, b'a'),
    // Short inputs are fixed-Huffman blocks.
    b"fixed blocks carry no trees: fixed blocks carry no trees, fixed blocks.",
    inflate_differential_pattern(b"abcdefgh", 300),
    ..inflate_differential_sources(),
  ]
}

///|
#cfg(target="native")
test "streaming decode is independent of output room on intact streams" {
  for source in fast_stream_sources() {
    for level in [0, 1, 6, 9] {
      let compressed = deflate_all(source, level~)
      // Bytes behind the stream (a container's trailer) must stay unread.
      let framed = compressed +
        b"\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF"
      let careful = fast_stream_run(framed, 1 << 20, 257, true)
      @test.assert_eq(careful.verdict, "done")
      @test.assert_eq(careful.decoded, source)
      @test.assert_eq(careful.consumed, compressed.length())
      for room in [258, 259, 300, 4096, 32768, 65536, 200000] {
        for chunk in [1 << 20, 4096, 263, 9, 8, 7] {
          for fixed in [true, false] {
            guard chunk >= 263 || source.length() <= 2000 || room == 300 else {
              continue
            }
            @test.assert_eq(
              fast_stream_run(framed, chunk, room, fixed),
              careful,
            )
          }
        }
      }
    }
  }
}

///|
#cfg(target="native")
test "streaming decode is independent of output room on damaged streams" {
  let rng = InflateDifferentialRng(0xDA3A6EDU)
  for source in fast_stream_sources() {
    for level in [1, 6] {
      let compressed = deflate_all(source, level~)
      let damaged : Array[Bytes] = []
      let cuts = if compressed.length() > 4000 { 12 } else { 30 }
      for _ in 0..<cuts {
        damaged.push(compressed[:rng.size(compressed.length()) - 1].to_owned())
      }
      for k in 0..<(3 * cuts) {
        // Half of the flips fall into the first block header and its trees.
        let index = if k % 2 == 0 {
          rng.size(compressed.length().min(96)) - 1
        } else {
          rng.size(compressed.length()) - 1
        }
        damaged.push(
          inflate_differential_flip(compressed, index, 1 << (rng.size(8) - 1)),
        )
      }
      for stream in damaged {
        let careful = fast_stream_run(stream, 1 << 20, 257, true)
        for
          schedule in [
            (1 << 20, 65536, true),
            (1 << 20, 258, false),
            (263, 4096, true),
          ] {
          let (chunk, room, fixed) = schedule
          @test.assert_eq(fast_stream_run(stream, chunk, room, fixed), careful)
        }
        // The one-shot decoder is the third opinion on the verdict.
        let one_shot = match inflate_differential_one_shot(stream) {
          InflateDifferentialOk(_) => "done"
          InflateDifferentialErr(kind) => @debug.to_string(kind)
        }
        @test.assert_eq(careful.verdict, one_shot)
      }
    }
  }
}

///|
/// Run one schedule on two decoders and compare what every call reports. The
/// first takes each call as it is. The second is given the same input view
/// but its output room in pieces of at most 257 bytes, a room in which no
/// call can hold a whole longest match: it decodes every unit through
/// `decode_unit`. Its pieces, put together, are what one careful call does,
/// so status, consumed and produced counts, the bytes and the error kind of
/// every call must be the same.
#cfg(target="native")
fn assert_calls_agree(
  input : Bytes,
  chunk : Int32,
  room : Int32,
  fixed : Bool,
) -> Unit raise {
  let whole = Inflater()
  let pieces = Inflater()
  let output = FixedArray::make(room, b'\x00')
  let reference = FixedArray::make(room, b'\x00')
  let mut position = 0
  for ;; {
    let end = (position + chunk).min(input.length())
    let view = input[position:end]
    let last = end == input.length()
    let mut verdict = "ok"
    let mut status : Status = Done
    try {
      status = if fixed {
        whole.step_into(view, output, end=last)
      } else {
        whole.step(view, output.mut_view(), end=last)
      }
    } catch {
      InflateError(kind, _) => verdict = @debug.to_string(kind)
    }
    let mut consumed = 0
    let mut produced = 0
    let mut expected_verdict = "ok"
    let mut expected : Status = NeedMoreOutput
    for ;; {
      let piece = (room - produced).min(257)
      let step = pieces.step(
        view[consumed:],
        reference.mut_view(start=produced, end=produced + piece),
        end=last,
      ) catch {
        InflateError(kind, _) => {
          expected_verdict = @debug.to_string(kind)
          break
        }
      }
      consumed = consumed + pieces.last_consumed()
      produced = produced + pieces.last_produced()
      expected = step
      guard step is NeedMoreOutput && produced < room else { break }
    }
    @test.assert_eq(verdict, expected_verdict)
    guard verdict == "ok" else { return }
    @test.assert_eq(status, expected)
    @test.assert_eq(whole.last_consumed(), consumed)
    @test.assert_eq(whole.last_produced(), produced)
    for i in 0..<produced {
      guard output[i] == reference[i] else {
        @test.fail("byte \{i} of a call differs")
      }
    }
    position = position + consumed
    guard !(status is Done) else { return }
  }
}

///|
/// The per-call contract on intact and damaged streams: where a call
/// suspends, what it consumed and produced, and how it fails.
#cfg(target="native")
test "streaming calls report what careful calls report" {
  let rng = InflateDifferentialRng(0x7EACE5U)
  for source in fast_stream_sources() {
    for level in [0, 1, 6] {
      let compressed = deflate_all(source, level~)
      let framed = compressed +
        b"\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF"
      let schedules = [
        (1 << 20, 65536, true),
        (1 << 20, 258, false),
        (4096, 300, false),
        (263, 1000, true),
        (9, 258, true),
        (8, 4096, false),
      ]
      for schedule in schedules {
        let (chunk, room, fixed) = schedule
        guard chunk >= 263 || source.length() <= 2000 else { continue }
        assert_calls_agree(framed, chunk, room, fixed)
      }
      for k in 0..<8 {
        let stream = if k % 2 == 0 {
          compressed[:rng.size(compressed.length()) - 1].to_owned()
        } else {
          inflate_differential_flip(
            compressed,
            rng.size(compressed.length()) - 1,
            1 << (rng.size(8) - 1),
          )
        }
        assert_calls_agree(stream, 1 << 20, 65536, true)
        assert_calls_agree(stream, 263, 1000, false)
      }
    }
  }
}

///|
/// A fixed-Huffman block of `literals` literals, then `unit` written by the
/// caller, then zero padding: enough input behind the unit that a decoder
/// with ample output room reaches it with a full reservoir.
fn fast_stream_malformed(literals : Int32, unit : (BitWriter) -> Unit) -> Bytes {
  let writer = BitWriter()
  writer.write_bit(1)
  writer.write_bits(1, 2)
  for i in 0..<literals {
    let symbol = 0x41 + i % 26
    writer.write_rcode(fixed_ll_val[symbol], fixed_ll_len[symbol])
  }
  unit(writer)
  writer.flush()
  for _ in 0..<16 {
    writer.write_byte(b'\x00')
  }
  Bytes::from_array(writer.out)
}

///|
/// Invalid units deep inside a block, reached with ample input and output:
/// the reserved length symbols 286 and 287, the reserved distance symbols 30
/// and 31, and a distance beyond the history. Every schedule and the one-shot
/// decoder must call them corrupt.
test "malformed units are corrupt for every output room" {
  let length3 = (writer : BitWriter) => {
    writer.write_rcode(fixed_ll_val[257], fixed_ll_len[257])
  }
  let units : Array[(BitWriter) -> Unit] = [
    writer => writer.write_rcode(fixed_ll_val[286], fixed_ll_len[286]),
    writer => writer.write_rcode(fixed_ll_val[287], fixed_ll_len[287]),
    writer => {
      length3(writer)
      writer.write_rcode(reverse_bits(30U, 5), 5)
    },
    writer => {
      length3(writer)
      writer.write_rcode(reverse_bits(31U, 5), 5)
    },
    // Distance 32768 behind fewer bytes than that.
    writer => {
      length3(writer)
      writer.write_rcode(fixed_dist_val[29], 5)
      writer.write_bits(8191, 13)
    },
  ]
  for literals in [20, 400, 5000] {
    for unit in units {
      let stream = fast_stream_malformed(literals, unit)
      for
        schedule in [
          (1 << 20, 257, true),
          (1 << 20, 258, true),
          (1 << 20, 65536, false),
          (64, 4096, true),
          (9, 300, false),
        ] {
        let (chunk, room, fixed) = schedule
        @test.assert_eq(fast_stream_run(stream, chunk, room, fixed), {
          decoded: b"",
          consumed: 0,
          verdict: "Corrupt",
        })
      }
      @test.assert_eq(
        inflate_differential_one_shot(stream),
        InflateDifferentialErr(Corrupt),
      )
    }
  }
}

///|
/// The window cursor counts every byte ever written and wraps. A call that
/// writes a window's worth of literals must leave the window marked full
/// wherever the counter stands afterwards, or the next call rejects a match
/// that reaches back further than the wrapped counter's value. Getting there
/// takes a 2 GiB output array, so the cursor is set by hand: it stands for
/// the middle of such a call, a window short of wrapping past zero.
#cfg(target="native")
test "fast loop marks the window full by what a call wrote" {
  let stream = fast_stream_malformed(40000, writer => {
    // Length 3 at distance 20000 (symbol 28, base 16385), then end of block.
    writer.write_rcode(fixed_ll_val[257], fixed_ll_len[257])
    writer.write_rcode(fixed_dist_val[28], 5)
    writer.write_bits(20000 - 16385, 13)
    writer.write_rcode(fixed_ll_val[256], fixed_ll_len[256])
  })
  let inflater = Inflater()
  inflater.wpos = -30000
  let output = FixedArray::make(40000, b'\x00')
  let first = inflater.step_into(stream, output, end=true)
  assert_true(first is NeedMoreOutput)
  @test.assert_eq(inflater.last_produced(), 40000)
  @test.assert_eq(inflater.wpos, 10000)
  assert_true(inflater.filled)
  let rest = stream[inflater.last_consumed():]
  let second = inflater.step_into(rest, output, end=true)
  assert_true(second is Done)
  @test.assert_eq(inflater.last_produced(), 3)
  for i in 0..<3 {
    @test.assert_eq(output[i], (0x41 + (20000 + i) % 26).to_byte())
  }
}
