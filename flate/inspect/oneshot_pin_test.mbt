// What the one-shot raw decoders answer, pinned against the streaming
// `Inflater`: `inflate_exact` and `inflate_all` on whole, cut, extended and
// damaged streams, with the kind and the message of every error. The
// expectations are computed from the streaming decoder alone, so they hold
// whichever engine a one-shot decoder runs on.

///|
/// A decode as a value to compare: the bytes, or `Kind: message`.
fn[K : @debug.Debug] pin_failure(
  kind : K,
  message : String,
) -> Result[Bytes, String] {
  Err("\{@debug.to_string(kind)}: \{message}")
}

///|
fn pin_raw(
  decode : () -> Bytes raise @flate.InflateError,
) -> Result[Bytes, String] {
  try decode() catch {
    InflateError(kind, message) => pin_failure(kind, message)
  } noraise {
    bytes => Ok(bytes)
  }
}

///|
fn pin_check(
  label : String,
  got : Result[Bytes, String],
  expected : Result[Bytes, String],
) -> Unit raise {
  guard got != expected else { return }
  fail("\{label}: got \{pin_show(got)}, expected \{pin_show(expected)}")
}

///|
fn pin_show(outcome : Result[Bytes, String]) -> String {
  match outcome {
    Ok(bytes) => "\{bytes.length()} bytes"
    Err(error) => error
  }
}

///|
/// One streaming inflater and one output chunk for every reference decode.
let pin_inflater : @flate.Inflater = Inflater()

///|
let pin_chunk : FixedArray[Byte] = FixedArray::make(1021, b'\x00')

///|
/// The streaming `Inflater` over all of `input`: what it decoded and how many
/// bytes of `input` the stream took, or the kind and the message of its error.
fn pin_streaming(input : BytesView) -> Result[(Bytes, Int32), (String, String)] {
  pin_inflater.reset()
  let decoded = @buffer.Buffer()
  let mut used = 0
  for ;; {
    let status = pin_inflater.step_into(input[used:], pin_chunk, end=true) catch {
      InflateError(kind, message) =>
        return Err((@debug.to_string(kind), message))
    }
    used += pin_inflater.last_consumed()
    decoded.write_bytes(
      Bytes::from_array(pin_chunk[:pin_inflater.last_produced()]),
    )
    if status is Done {
      return Ok((decoded.to_bytes(), used))
    }
  }
}

///|
/// `inflate_exact` and `inflate_all` on a raw stream.
fn pin_raw_case(label : String, input : BytesView) -> Unit raise {
  let (exact, prefix) = match pin_streaming(input) {
    Ok((bytes, used)) =>
      if used == input.length() {
        (Ok(bytes), Ok(bytes))
      } else {
        (Err("TrailingData: trailing data after DEFLATE stream"), Ok(bytes))
      }
    Err((kind, message)) => {
      let error = Err("\{kind}: \{message}")
      (error, error)
    }
  }
  pin_check(
    "\{label} inflate_exact",
    pin_raw(() => @flate.inflate_exact(input)),
    exact,
  )
  pin_check(
    "\{label} inflate_all",
    pin_raw(() => @flate.inflate_all(input)),
    prefix,
  )
  // The controls of `inflate_exact` change how it runs, not what it answers.
  guard input.length() <= 300 else { return }
  pin_check(
    "\{label} inflate_exact with a limit",
    pin_raw(() => @flate.inflate_exact(input, max_output=0x7FFF_FFFF)),
    exact,
  )
  pin_check(
    "\{label} inflate_exact with a callback",
    pin_raw(() => @flate.inflate_exact(input, cancelled=() => false)),
    exact,
  )
  pin_check(
    "\{label} inflate_exact preallocated",
    pin_raw(() => @flate.inflate_exact(input, preallocated=true)),
    exact,
  )
}

///|
/// Where a stream of `length` bytes is cut and damaged: everywhere up to
/// `small` bytes, at both ends and at `spread` places between them beyond.
fn pin_positions(length : Int32, spread : Int32, small : Int32) -> Array[Int32] {
  guard length > small else { return Array::makei(length, i => i) }
  let positions = Array::makei(8, i => i)
  for i in 1..<spread {
    positions.push(
      (length.to_int64() * i.to_int64() / spread.to_int64()).to_int(),
    )
  }
  for i in 0..<8 {
    positions.push(length - 8 + i)
  }
  positions
}

///|
/// Run `check` on `stream` whole, cut at every position of `pin_positions`
/// (as a view of the whole stream: nothing beyond a view may be read), with 1
/// to 9 more bytes behind it (zeros, and the start of a gzip member; 1 and 9
/// bytes behind a stream of more than `small` bytes), and with one bit flipped
/// at each of those positions from `flip_from` up to `flip_to`.
fn pin_mutations(
  label : String,
  stream : Bytes,
  check : (String, BytesView) -> Unit raise,
  spread~ : Int32,
  small~ : Int32 = 300,
  flip_from~ : Int32 = 0,
  flip_to~ : Int32 = stream.length(),
) -> Unit raise {
  check("\{label} whole", stream)
  let positions = pin_positions(stream.length(), spread, small)
  for cut in positions {
    check("\{label} cut at \{cut}", stream[:cut])
  }
  let tails : Array[Bytes] = [
    Bytes::make(9, b'\x00'),
    b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x00",
  ]
  for tail in tails {
    for extra in 1..<=9 {
      guard stream.length() <= small || extra == 1 || extra == 9 else {
        continue
      }
      let longer = stream + tail[:extra].to_owned()
      check("\{label} with \{extra} bytes from \{tail[0]} behind", longer)
    }
  }
  for at in positions {
    guard at >= flip_from && at < flip_to else { continue }
    let damaged = stream.to_fixedarray()
    damaged[at] = damaged[at] ^ (1 << (at % 8)).to_byte()
    check(
      "\{label} bit \{at % 8} of byte \{at} flipped",
      Bytes::from_array(damaged),
    )
  }
}

///|
/// Text in the shape of a typeset PDF content stream: positioned runs of
/// hexadecimal glyph strings with kerning between them.
fn pin_pdf_text(size : Int32) -> Bytes {
  let out = @buffer.Buffer()
  let mut state = 0x9E3779B9U
  while out.length() < size {
    state = lcg(state)
    out.write_string_utf8(
      "q\n1 0 0 -1 \{(state >> 8) % 500}.\{(state >> 3) % 100000} 764.1146 cm\n/c0 cs\n0 scn\nBT\n0 Tr\n/f0 10.5 Tf\n1 0 0 -1 0 0 Tm\n[",
    )
    for _ in 0U..<=(state % 7) {
      out.write_byte(b'<')
      state = lcg(state)
      for _ in 0U..<=(state >> 28) {
        state = lcg(state)
        out.write_string_utf8("00")
        out.write_byte(
          b"0123456789ABCDEF"[((state >> 20) & 3).reinterpret_as_int()],
        )
        out.write_byte(
          b"0123456789ABCDEF"[((state >> 24) & 15).reinterpret_as_int()],
        )
      }
      out.write_string_utf8("> -45.973377 ")
    }
    out.write_string_utf8("] TJ\nET\nQ\n")
  }
  out.to_bytes()[:size].to_owned()
}

///|
/// `data` through one `Deflater` with a sync flush after each third: Huffman
/// blocks with empty stored blocks between them.
fn pin_flushed(data : Bytes) -> Bytes {
  let deflater = @flate.Deflater()
  let output = FixedArray::make(4096, b'\x00')
  let compressed = @buffer.Buffer()
  for part in 0..<3 {
    let end = if part == 2 {
      data.length()
    } else {
      data.length() / 3 * (part + 1)
    }
    let action : @flate.DeflateAction = if part == 2 {
      Finish
    } else {
      SyncFlush
    }
    let mut pos = data.length() / 3 * part
    for ;; {
      let status = deflater.step(data[pos:end], output.mut_view(), action~)
      pos += deflater.last_consumed()
      compressed.write_bytes(
        Bytes::from_array(output[:deflater.last_produced()]),
      )
      if pos == end && !(status is NeedMoreOutput) {
        break
      }
    }
  }
  compressed.to_bytes()
}

///|
/// The corpus of the benchmark and of a PDF, small and large: (name, bytes).
fn pin_sources() -> Array[(String, Bytes)] {
  let phrase = b"The quick brown fox jumps over the lazy dog. Pack my box. "
  let repetitive = Bytes::makei(70000, i => phrase[i % phrase.length()])
  let random = make_bytes(0xF1A7E001U, 70000, 256)
  let pdf = pin_pdf_text(40000)
  [
    ("empty", b""),
    ("single", b"x"),
    ("phrase", phrase),
    ("repetitive-512", repetitive[:512].to_owned()),
    ("random-290", random[:290].to_owned()),
    ("distance-one", Bytes::make(5000, b'a')),
    ("alphabet-12", make_bytes(0xF1A7E002U, 900, 12)),
    ("pdf-2k", pdf[:2000].to_owned()),
    ("pdf-40k", pdf),
    ("mixed-70k", repetitive[:35000].to_owned() + random[:35000].to_owned()),
    ("precompressed", @flate.deflate_all(pdf)),
  ]
}

///|
/// Every source as raw DEFLATE at levels 0 (stored), 1, 6 and 9, split by
/// content, and sync-flushed: (name, plain, raw stream).
fn pin_streams() -> Array[(String, Bytes, Bytes)] {
  let streams = []
  for source in pin_sources() {
    let (name, plain) = source
    for level in [0, 1, 6, 9] {
      streams.push(
        ("\{name} L\{level}", plain, @flate.deflate_all(plain, level~)),
      )
    }
    streams.push(("\{name} split", plain, @flate.deflate_all_split(plain)))
    streams.push(("\{name} flushed", plain, pin_flushed(plain)))
  }
  streams
}

///|
test "one-shot raw decoders answer as the streaming inflater" {
  let first_block_types = FixedArray::make(4, 0)
  for stream in pin_streams() {
    let (name, plain, raw) = stream
    let block_type = (raw[0].to_int() >> 1) & 3
    first_block_types[block_type] += 1
    @test.assert_eq(@flate.inflate_exact(raw), plain)
    pin_mutations(name, raw, pin_raw_case, spread=6)
  }
  // Stored, fixed and dynamic streams are all in the corpus.
  assert_true(first_block_types[0] > 0)
  assert_true(first_block_types[1] > 0)
  assert_true(first_block_types[2] > 0)
}

///|
/// The errors of `inflate_exact`, word for word.
test "inflate_exact reports each malformed stream with its own error" {
  let report = (input : Bytes) => {
    pin_show(pin_raw(() => @flate.inflate_exact(input)))
  }
  @test.assert_eq(report(b""), "Truncated: unexpected end of input")
  @test.assert_eq(report(b"\x07"), "Corrupt: corrupt: reserved block type")
  @test.assert_eq(
    report(b"\x01\x01\x00\x00\x00"),
    "Corrupt: stored block length mismatch",
  )
  @test.assert_eq(
    report(b"\x01\x02\x00\xFD\xFF\xAA"),
    "Truncated: unexpected end of input",
  )
  @test.assert_eq(
    report(b"\x01\x00\x00\xFF\xFF\x00"),
    "TrailingData: trailing data after DEFLATE stream",
  )
  // Fixed block: the reserved literal/length code 286.
  @test.assert_eq(
    report(b"\x1B\x03"),
    "Corrupt: corrupt: invalid literal/length code",
  )
  // Fixed block: length 3 at distance 1 with no history.
  @test.assert_eq(
    report(b"\x03\x02"),
    "Corrupt: corrupt: distance too far back",
  )
  // Fixed block: a literal, then length 3 with the reserved distance code 30.
  @test.assert_eq(
    report(b"\x4B\x04\x3E"),
    "Corrupt: corrupt: invalid distance code",
  )
  // Dynamic block whose code-length alphabet has no symbol.
  @test.assert_eq(
    report(b"\x05\x00\x00\x00\x00"),
    "Corrupt: corrupt: bad Huffman code",
  )
}

///|
/// With a callback or a limit `inflate_exact` steps through the stream 8192
/// bytes of output at a time: the callback is polled at entry and once per
/// step, in both passes of a preallocated decode.
test "inflate_exact polls its callback once per step and enforces its limit" {
  let compressed = (size : Int32) => {
    @flate.deflate_all(Bytes::makei(size, i => (i * 31 + i / 7).to_byte()))
  }
  let polls = (size : Int32, preallocated : Bool, stop_at : Int32) => {
    let input = compressed(size)
    let mut count = 0
    let outcome = pin_raw(() => {
      @flate.inflate_exact(input, preallocated~, cancelled=() => {
        count += 1
        count == stop_at
      })
    })
    "\{count} polls, \{pin_show(outcome)}"
  }
  @test.assert_eq(polls(0, false, 0), "2 polls, 0 bytes")
  @test.assert_eq(polls(8191, false, 0), "2 polls, 8191 bytes")
  @test.assert_eq(polls(8192, false, 0), "3 polls, 8192 bytes")
  @test.assert_eq(polls(8193, false, 0), "3 polls, 8193 bytes")
  @test.assert_eq(polls(20000, false, 0), "4 polls, 20000 bytes")
  @test.assert_eq(polls(20000, true, 0), "7 polls, 20000 bytes")
  @test.assert_eq(
    polls(20000, false, 1),
    "1 polls, Cancelled: cancelled by caller",
  )
  @test.assert_eq(
    polls(20000, false, 3),
    "3 polls, Cancelled: cancelled by caller",
  )
  @test.assert_eq(
    polls(20000, true, 6),
    "6 polls, Cancelled: cancelled by caller",
  )
  let limited = (limit : Int32, preallocated : Bool) => {
    let input = compressed(20000)
    pin_show(
      pin_raw(() => @flate.inflate_exact(input, max_output=limit, preallocated~)),
    )
  }
  @test.assert_eq(limited(20000, false), "20000 bytes")
  @test.assert_eq(
    limited(19999, false),
    "OutputLimitExceeded: decoded output exceeds max_output",
  )
  @test.assert_eq(
    limited(19999, true),
    "OutputLimitExceeded: decoded output exceeds max_output",
  )
  @test.assert_eq(
    limited(-1, false),
    "OutputLimitExceeded: max_output must be non-negative",
  )
}

///|
fn pin_forward(
  input : Bytes,
  cancelled? : () -> Bool,
) -> Bytes raise @flate.InflateError {
  @flate.inflate_exact(input, cancelled?)
}

///|
/// `cancelled` is an optional argument: a caller forwards the callback it may
/// have, and without one nothing is polled.
test "inflate_exact takes the callback its caller may have" {
  let source = Bytes::makei(20000, i => (i * 31 + i / 7).to_byte())
  let input = @flate.deflate_all(source)
  @test.assert_eq(pin_forward(input), source)
  let mut polls = 0
  let counting = () => {
    polls += 1
    false
  }
  @test.assert_eq(pin_forward(input, cancelled=counting), source)
  @test.assert_eq(polls, 4)
}
