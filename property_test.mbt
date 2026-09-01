// Property-based tests for the core DEFLATE engine, driven by
// `moonbitlang/core/quickcheck`.
//
// Every property has a fixed `seed` so a failure is exactly reproducible, and
// uses `max_size` schedules that push past the engine's internal boundaries
// (258-byte match cap, 16 KiB block, 32 KiB window) as well as the ordinary
// literal/stored/dynamic block mix.

///|
priv enum PropInflateOutcome {
  PropOk(Bytes)
  PropErr(InflateErrorKind)
} derive(Eq)

///|
fn prop_inflate_all(input : Bytes) -> PropInflateOutcome {
  try PropOk(inflate_all(input)) catch {
    InflateError(kind, _) => PropErr(kind)
  } noraise {
    ok => ok
  }
}

///|
fn prop_inflate_exact(input : Bytes) -> PropInflateOutcome {
  try PropOk(inflate_exact(input)) catch {
    InflateError(kind, _) => PropErr(kind)
  } noraise {
    ok => ok
  }
}

///|
fn prop_inflate_exact_preallocated(input : Bytes) -> PropInflateOutcome {
  try PropOk(inflate_exact(input, preallocated=true)) catch {
    InflateError(kind, _) => PropErr(kind)
  } noraise {
    ok => ok
  }
}

///| Deterministic per-step chunk size in `[1, modulus]`, cycling through a

///|
/// varied schedule as `step` grows.
fn prop_chunk_size(step : Int, modulus : Int) -> Int {
  1 + (step * 37 + step * step * 11) % modulus
}

///| Drive a streaming `Inflater` over `input` one arbitrary chunk schedule at a

///|
/// time, mirroring how an async reader feeds it.
fn prop_inflate_streaming_loop(
  input : Bytes,
) -> PropInflateOutcome raise InflateError {
  let inflater = Inflater()
  let output = FixedArray::make(64, b'\x00')
  let decoded = Buffer()
  let mut input_pos = 0
  let mut available = 0
  let mut steps = 0
  for ;; {
    if available == input_pos && available < input.length() {
      let chunk_size = if steps % 7 == 0 {
        1
      } else {
        prop_chunk_size(steps, 17)
      }
      available = (available + chunk_size).min(input.length())
    }
    let output_size = if steps % 5 == 0 {
      1
    } else {
      prop_chunk_size(steps, 23)
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
    if steps > 200000 {
      abort(
        "property: streaming inflate stalled (input_length=\{input.length()})",
      )
    }
    if status is Done {
      return PropOk(decoded.to_bytes())
    }
  }
}

///|
fn prop_inflate_streaming(input : Bytes) -> PropInflateOutcome {
  try prop_inflate_streaming_loop(input) catch {
    InflateError(kind, _) => PropErr(kind)
  } noraise {
    ok => ok
  }
}

///| Run a `Deflater` to completion over `data`, re-presenting the unconsumed

///|
/// suffix with `action=Finish` until it reports `Done`.
fn prop_deflate_finish(deflater : Deflater, data : Bytes) -> Bytes {
  let output = FixedArray::make(4096, b'\x00')
  let compressed = Buffer()
  let mut pos = 0
  for ;; {
    let st = deflater.step(data[pos:], output.mut_view(), action=Finish)
    let consumed = deflater.last_consumed()
    let produced = deflater.last_produced()
    for i in 0..<produced {
      compressed.write_byte(output[i])
    }
    pos = pos + consumed
    if st is Done {
      return compressed.to_bytes()
    }
  }
}

///| Decode a whole stream with a caller-supplied `Inflater`, collecting the

///|
/// output.
fn prop_inflate_drive(
  inflater : Inflater,
  input : Bytes,
) -> Bytes raise InflateError {
  let output = FixedArray::make(4096, b'\x00')
  let decoded = Buffer()
  let mut pos = 0
  for ;; {
    let st = inflater.step(input[pos:], output.mut_view(), end=true)
    let consumed = inflater.last_consumed()
    let produced = inflater.last_produced()
    pos = pos + consumed
    for i in 0..<produced {
      decoded.write_byte(output[i])
    }
    if st is Done {
      return decoded.to_bytes()
    }
  }
}

// ---------------------------------------------------------------------------
// Structured, compressible input generator
// ---------------------------------------------------------------------------
//
// Plain `Bytes` via `Arbitrary` is incompressible noise, which only forces the
// stored-block path. To exercise LZ77 hash chains, lazy matching, dynamic
// Huffman trees, and the 258/16 KiB/32 KiB boundaries, generate text-like,
// run-heavy, and pattern-repeating data instead.

///|
priv struct Compressible(Bytes) derive(Debug)

///|
fn prop_text_byte(rs : @quickcheck.RandomState) -> Byte {
  let text = b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 the quick brown fox jumps over lazy dog. "
  text[rs.next_positive_int() % text.length()]
}

///|
impl @quickcheck.Arbitrary for Compressible with fn arbitrary(size, rs) {
  let b = Buffer()
  let target = match rs.next_uint() % 3 {
    0 => size
    1 => size / 2
    _ => if size == 0 { 0 } else { rs.next_positive_int() % size }
  }
  let mut remaining = target
  while remaining > 0 {
    let style = rs.next_uint() % 6
    match style {
      0 => {
        let n = (1 + rs.next_positive_int() % 64).min(remaining)
        for _ in 0..<n {
          b.write_byte(prop_text_byte(rs))
        }
        remaining = remaining - n
      }
      1 => {
        let n = (1 + rs.next_positive_int() % 300).min(remaining)
        let byte = prop_text_byte(rs)
        for _ in 0..<n {
          b.write_byte(byte)
        }
        remaining = remaining - n
      }
      2 => {
        let plen = (1 + rs.next_positive_int() % 24).min(remaining)
        let pat = Array::make(plen, b'\x00')
        for i in 0..<plen {
          pat[i] = prop_text_byte(rs)
        }
        let reps = if remaining / plen > 0 {
          (1 + rs.next_positive_int() % (remaining / plen + 1)).min(
            remaining / plen,
          )
        } else {
          0
        }
        for _ in 0..<reps {
          for p in pat {
            b.write_byte(p)
          }
          remaining = remaining - plen
        }
      }
      3 => {
        let byte = prop_text_byte(rs)
        for _ in 0..<remaining {
          b.write_byte(byte)
        }
        remaining = 0
      }
      4 =>
        if remaining >= 258 {
          let pat = Array::make(258, b'\x00')
          for i in 0..<258 {
            pat[i] = prop_text_byte(rs)
          }
          let reps = remaining / 258
          for _ in 0..<reps {
            for p in pat {
              b.write_byte(p)
            }
          }
          remaining = remaining % 258
        } else {
          let byte = prop_text_byte(rs)
          for _ in 0..<remaining {
            b.write_byte(byte)
          }
          remaining = 0
        }
      _ => {
        let n = (1 + rs.next_positive_int() % 64).min(remaining)
        for _ in 0..<n {
          b.write_byte(rs.next_positive_int().to_byte())
        }
        remaining = remaining - n
      }
    }
  }
  Compressible(b.to_bytes())
}

///|
impl @quickcheck.Shrink for Compressible with fn shrink(self) {
  @quickcheck.Shrink::shrink(self.0).map(b => Compressible(b))
}

// ---------------------------------------------------------------------------
// Properties
// ---------------------------------------------------------------------------

///|
/// Property: `deflate_all` round-trips arbitrary bytes at every level 0-9.
test "property: deflate_all round-trips at every level" {
  @quickcheck.check(
    (data : Bytes) => {
      for level in 0..<10 {
        let compressed = deflate_all(data, level~)
        if inflate_all(compressed) != data {
          return false
        }
      }
      true
    },
    count=60,
    max_size=3000,
    max_shrinks=300,
    seed=0xA11CE001,
  )
}

///|
/// Property: the optimal (zopfli-style) and content-splitting parsers both
/// round-trip arbitrary bytes.
test "property: optimal and split parsers round-trip" {
  @quickcheck.check(
    (data : Bytes) => {
      if inflate_all(deflate_all_optimal(data, iterations=4)) != data {
        return false
      }
      if inflate_all(deflate_all_split(data)) != data {
        return false
      }
      true
    },
    count=40,
    max_size=2000,
    max_shrinks=200,
    seed=0xA11CE002,
  )
}

///|
/// Property: compressible data round-trips at several levels, with sizes
/// growing past the 258-byte match cap, the 16 KiB block size, and the 32 KiB
/// sliding-window limit.
test "property: compressible data round-trips across boundaries" {
  @quickcheck.check(
    (data : Compressible) => {
      let source = data.0
      let levels = [0, 1, 6, 9]
      for level in levels {
        if inflate_all(deflate_all(source, level~)) != source {
          return false
        }
      }
      true
    },
    count=40,
    max_size=40000,
    max_shrinks=200,
    seed=0xA11CE003,
  )
}

///|
/// Property: the streaming `Inflater` (fed one chunk at a time through a small
/// output buffer) agrees with one-shot `inflate_all`, on both valid and
/// malformed input, including the reported error kind.
test "property: streaming Inflater agrees with inflate_all" {
  @quickcheck.check(
    (data : Bytes) => prop_inflate_all(data) == prop_inflate_streaming(data),
    count=60,
    max_size=2000,
    max_shrinks=200,
    seed=0xA11CE004,
  )
}

///|
/// Property: the streaming `Deflater` (small output buffer, input re-presented
/// with `Finish` across `NeedMoreOutput`) produces a stream that decodes back
/// to the original input.
test "property: streaming Deflater round-trips arbitrary input" {
  @quickcheck.check(
    (data : Bytes) => {
      let deflater = Deflater()
      let output = FixedArray::make(64, b'\x00')
      let compressed = Buffer()
      let mut pos = 0
      let mut steps = 0
      for ;; {
        steps = steps + 1
        if steps > 200000 {
          return false
        }
        let out_size = prop_chunk_size(steps, 64)
        let st = deflater.step(
          data[pos:],
          output.mut_view(end=out_size),
          action=Finish,
        )
        let consumed = deflater.last_consumed()
        let produced = deflater.last_produced()
        for i in 0..<produced {
          compressed.write_byte(output[i])
        }
        pos = pos + consumed
        if st is Done {
          break
        }
      }
      inflate_all(compressed.to_bytes()) == data
    },
    count=50,
    max_size=2000,
    max_shrinks=200,
    seed=0xA11CE005,
  )
}

///|
/// Property: `inflate_exact` (both the grow and preallocated paths) agrees with
/// `inflate_all` on valid streams, rejects trailing bytes with `TrailingData`
/// where `inflate_all` succeeds, and reports the same error kind otherwise.
test "property: inflate_exact agrees with inflate_all" {
  @quickcheck.check(
    (data : Bytes) => {
      let all = prop_inflate_all(data)
      let exact = prop_inflate_exact(data)
      let preallocated = prop_inflate_exact_preallocated(data)
      let exact_ok = match (all, exact) {
        (PropOk(x), PropOk(y)) => x == y
        (PropOk(_), PropErr(TrailingData)) => true
        (PropErr(k), PropErr(k2)) => k == k2
        _ => false
      }
      let preallocated_ok = match (all, preallocated) {
        (PropOk(x), PropOk(y)) => x == y
        (PropOk(_), PropErr(TrailingData)) => true
        (PropErr(k), PropErr(k2)) => k == k2
        _ => false
      }
      exact_ok && preallocated_ok
    },
    count=60,
    max_size=2000,
    max_shrinks=200,
    seed=0xA11CE006,
  )
}

///|
/// Property: `inflate_all_limited` returns exactly `inflate_all`'s output when
/// it fits under `max_output`, raises `OutputLimitExceeded` when the decoded
/// output is larger, and rejects a negative limit outright.
test "property: inflate_all_limited respects max_output" {
  @quickcheck.check(
    (data : Bytes) => {
      let all = prop_inflate_all(data)
      let limit = data.length()
      let limited = try
        PropOk(inflate_all_limited(data, max_output=limit))
      catch {
        InflateError(kind, _) => PropErr(kind)
      } noraise {
        ok => ok
      }
      match (all, limited) {
        (PropOk(x), PropOk(y)) => x == y && x.length() <= limit
        (PropOk(x), PropErr(OutputLimitExceeded)) => x.length() > limit
        (PropErr(k), PropErr(k2)) => k == k2
        _ => false
      }
    },
    count=60,
    max_size=2000,
    max_shrinks=200,
    seed=0xA11CE007,
  )
  @quickcheck.check(
    (data : Bytes) => {
      try {
        ignore(inflate_all_limited(data, max_output=-1))
        false
      } catch {
        InflateError(OutputLimitExceeded, _) => true
        _ => false
      }
    },
    count=20,
    max_size=200,
    seed=0xA11CE008,
  )
}

///|
/// Property: decoding arbitrary bytes never panics and is deterministic — the
/// same input produces the same outcome (bytes or error) every time, through
/// both the one-shot and the exact streaming decoders.
test "property: inflate never panics and is deterministic" {
  @quickcheck.check(
    (data : Bytes) => {
      let a = prop_inflate_all(data)
      let b = prop_inflate_all(data)
      let c = prop_inflate_exact(data)
      let d = prop_inflate_exact(data)
      a == b && c == d
    },
    count=80,
    max_size=2000,
    max_shrinks=100,
    seed=0xA11CE009,
  )
}

///|
/// Property: an always-true cancellation callback cancels every stream with
/// `Cancelled`; an always-false callback behaves exactly like no callback.
test "property: cancellation semantics" {
  @quickcheck.check(
    (data : Bytes) => {
      let cancelled = try {
        ignore(inflate_all(data, cancelled=() => true))
        false
      } catch {
        InflateError(Cancelled, _) => true
        _ => false
      }
      if !cancelled {
        return false
      }
      let quiet = try Some(inflate_all(data, cancelled=() => false)) catch {
        InflateError(_, _) => None
      } noraise {
        ok => ok
      }
      quiet ==
      (match prop_inflate_all(data) {
        PropOk(decoded) => Some(decoded)
        PropErr(_) => None
      })
    },
    count=30,
    max_size=500,
    seed=0xA11CE010,
  )
}

///|
/// Property: with the correct preset dictionary the compressed stream decodes
/// back to the message; decoding it without the dictionary never panics and is
/// deterministic (it cleanly succeeds or raises `Corrupt`).
test "property: preset dictionary round-trips and unknown-dictionary decode never panics" {
  @quickcheck.check(
    (pair : (Compressible, Compressible)) => {
      let (dict, msg) = pair
      let dictionary = dict.0
      let message = msg.0
      let deflater = Deflater(dictionary=dictionary[:])
      let compressed = prop_deflate_finish(deflater, message)
      let with_dict = try {
        let inflater = Inflater(dictionary=dictionary[:])
        prop_inflate_drive(inflater, compressed) == message
      } catch {
        InflateError(_, _) => false
      }
      if !with_dict {
        return false
      }
      prop_inflate_all(compressed) == prop_inflate_all(compressed)
    },
    count=40,
    max_size=3000,
    max_shrinks=200,
    seed=0xA11CE011,
  )
}
