///|
priv enum InflateDifferentialOutcome {
  InflateDifferentialOk(Bytes)
  InflateDifferentialErr(InflateErrorKind)
} derive(Eq, Debug)

///|
priv struct InflateDifferentialRng {
  mut state : UInt
}

///|
fn InflateDifferentialRng::new(seed : UInt) -> InflateDifferentialRng {
  { state: seed }
}

///|
fn InflateDifferentialRng::next(self : InflateDifferentialRng) -> UInt {
  self.state = self.state * 1664525 + 1013904223
  self.state
}

///|
fn InflateDifferentialRng::size(
  self : InflateDifferentialRng,
  maximum : Int,
) -> Int {
  (self.next() >> 1).reinterpret_as_int() % maximum + 1
}

///|
fn inflate_differential_random_bytes(
  seed : UInt,
  length : Int,
  alphabet : Int,
) -> Bytes {
  let rng = InflateDifferentialRng::new(seed)
  let bytes = Array::make(length, b'\x00')
  for i in 0..<length {
    bytes[i] = (rng.size(alphabet) - 1).to_byte()
  }
  Bytes::from_array(bytes)
}

///|
fn inflate_differential_pattern(pattern : Bytes, length : Int) -> Bytes {
  let bytes = Array::make(length, b'\x00')
  for i in 0..<length {
    bytes[i] = pattern[i % pattern.length()]
  }
  Bytes::from_array(bytes)
}

///|
fn inflate_differential_sources() -> Array[Bytes] {
  [
    b"",
    b"a",
    Bytes::from_array(Array::make(258, b'a')),
    inflate_differential_pattern(b"moonbit-flate-", 777),
    inflate_differential_random_bytes(0xA11CE001U, 257, 2),
    inflate_differential_random_bytes(0xA11CE002U, 513, 17),
    inflate_differential_random_bytes(0xA11CE003U, 1025, 4),
    inflate_differential_random_bytes(0xA11CE004U, 1536, 256),
  ]
}

///|
fn inflate_differential_one_shot(input : Bytes) -> InflateDifferentialOutcome {
  try inflate_all(input) catch {
    InflateError(kind, _) => InflateDifferentialErr(kind)
  } noraise {
    decoded => InflateDifferentialOk(decoded)
  }
}

///|
fn inflate_differential_stream_bytes(
  input : Bytes,
  schedule_seed : UInt,
  one_byte_only : Bool,
) -> Bytes raise {
  let inflater = Inflater::new()
  let rng = InflateDifferentialRng::new(schedule_seed)
  let output = FixedArray::make(23, b'\x00')
  let decoded = Buffer()
  let mut input_pos = 0
  let mut available = 0
  let mut steps = 0
  for ;; {
    if available == input_pos && available < input.length() {
      let chunk_size = if one_byte_only || steps % 7 == 0 {
        1
      } else {
        rng.size(17)
      }
      available = if available + chunk_size < input.length() {
        available + chunk_size
      } else {
        input.length()
      }
    }
    let output_size = if one_byte_only || steps % 5 == 0 {
      1
    } else {
      rng.size(23)
    }
    let status = inflater.step(
      input[input_pos:available],
      output.mut_view(end=output_size),
      end=available == input.length(),
    )
    let consumed = inflater.last_consumed()
    let produced = inflater.last_produced()
    input_pos = input_pos + consumed
    for i in 0..<produced {
      decoded.write_byte(output[i])
    }
    steps = steps + 1
    if steps > 1000000 {
      fail(
        "streaming differential driver stalled: schedule_seed=\{to_repr(schedule_seed)}, input_length=\{input.length()}",
      )
    }
    match status {
      Done => return decoded.to_bytes()
      NeedMoreInput => ()
      NeedMoreOutput => ()
    }
  }
}

///|
fn inflate_differential_streaming(
  input : Bytes,
  schedule_seed : UInt,
  one_byte_only : Bool,
) -> InflateDifferentialOutcome raise {
  try
    inflate_differential_stream_bytes(input, schedule_seed, one_byte_only)
  catch {
    InflateError(kind, _) => InflateDifferentialErr(kind)
    error => raise error
  } noraise {
    decoded => InflateDifferentialOk(decoded)
  }
}

///|
fn inflate_differential_compare(
  input : Bytes,
  schedule_seed : UInt,
  corpus : String,
  one_byte_only : Bool,
) -> Unit raise {
  let one_shot = inflate_differential_one_shot(input)
  let streaming = inflate_differential_streaming(
    input, schedule_seed, one_byte_only,
  )
  if one_shot != streaming {
    fail(
      "inflate differential mismatch: corpus=\{corpus}, schedule_seed=\{to_repr(schedule_seed)}, input_length=\{input.length()}, one_shot=\{to_repr(one_shot)}, streaming=\{to_repr(streaming)}",
    )
  }
}

///|
fn inflate_differential_flip(input : Bytes, index : Int, mask : Int) -> Bytes {
  let mutated = input.to_array()
  mutated[index] = (mutated[index].to_int() ^ mask).to_byte()
  Bytes::from_array(mutated)
}

///|
test "inflate_all and streaming Inflater agree under deterministic fuzz" {
  let sources = inflate_differential_sources()
  let levels = [0, 1, 6, 9]
  let mut schedule_seed = 0xD1FF2026U
  for source_index in 0..<sources.length() {
    let source = sources[source_index]
    for level_index in 0..<levels.length() {
      let level = levels[level_index]
      let compressed = deflate_all(source, level~)
      let corpus = "source-\{source_index}/level-\{level}"
      let expected = InflateDifferentialOk(source)
      let one_shot = inflate_differential_one_shot(compressed)
      if one_shot != expected {
        fail(
          "valid differential corpus failed: corpus=\{corpus}, expected=\{to_repr(expected)}, one_shot=\{to_repr(one_shot)}",
        )
      }

      schedule_seed = schedule_seed * 1664525 + 1013904223
      inflate_differential_compare(
        compressed,
        schedule_seed,
        "\{corpus}/valid-random-chunks",
        false,
      )
      // Keep a small explicit 1-byte-only matrix in addition to the 1-byte
      // chunks periodically injected into every randomized schedule.
      if source_index == level_index {
        schedule_seed = schedule_seed * 1664525 + 1013904223
        inflate_differential_compare(
          compressed,
          schedule_seed,
          "\{corpus}/valid-1-byte-only",
          true,
        )
      }

      let truncation_points = [
        0,
        compressed.length() / 2,
        compressed.length() - 1,
      ]
      for mutation_index in 0..<truncation_points.length() {
        let end = truncation_points[mutation_index]
        let truncated = compressed[:end].to_owned()
        schedule_seed = schedule_seed * 1664525 + 1013904223
        inflate_differential_compare(
          truncated,
          schedule_seed,
          "\{corpus}/truncate-\{mutation_index}-at-\{end}",
          false,
        )
      }

      let flip_positions = [
        0,
        compressed.length() / 3,
        compressed.length() * 2 / 3,
        compressed.length() - 1,
      ]
      for mutation_index in 0..<flip_positions.length() {
        let position = flip_positions[mutation_index]
        let bit = (mutation_index * 3 + source_index + level_index) % 8
        let mask = 1 << bit
        let mutated = inflate_differential_flip(compressed, position, mask)
        schedule_seed = schedule_seed * 1664525 + 1013904223
        inflate_differential_compare(
          mutated,
          schedule_seed,
          "\{corpus}/flip-\{mutation_index}-byte-\{position}-bit-\{bit}",
          false,
        )
      }
    }
  }
}

///|
/// Arbitrary raw bytes exercise malformed states that mutations around streams
/// produced by our own compressor may never reach. The seed is part of every
/// corpus label so a failing case is exactly reproducible.
test "inflate_all and streaming Inflater agree on deterministic raw noise" {
  let corpus_rng = InflateDifferentialRng::new(0xBAD5EEDU)
  let mut schedule_seed = 0x51A7E202U
  for case_index in 0..<128 {
    let corpus_seed = corpus_rng.next()
    let length = corpus_rng.size(96)
    let input = inflate_differential_random_bytes(corpus_seed, length, 256)
    schedule_seed = schedule_seed * 1664525 + 1013904223
    inflate_differential_compare(
      input,
      schedule_seed,
      "raw-noise-\{case_index}/seed-\{to_repr(corpus_seed)}",
      false,
    )
  }
}
