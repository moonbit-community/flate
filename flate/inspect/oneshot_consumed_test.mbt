// `Decompressor::last_consumed`: the in-memory decoder fills its reservoir
// ahead of what it decodes, eight bytes at a time on native, and must still
// say exactly where the stream ended, as the streaming `Inflater` does.

///|
/// Decode `input` into `output` and check the bytes and the count against a
/// stream of `stream_length` bytes that decodes to `plain`.
fn pin_consumed_case(
  label : String,
  decompressor : @flate.Decompressor,
  input : BytesView,
  output : FixedArray[Byte],
  plain : Bytes,
  stream_length : Int32,
) -> Unit raise {
  let written = decompressor.decompress_into(input, output) catch {
    InflateError(_, message) => fail("\{label}: \{message}")
  }
  guard Bytes::from_array(output[:written]) == plain else {
    fail(
      "\{label}: decoded \{written} bytes, not the \{plain.length()} of the source",
    )
  }
  guard decompressor.last_consumed() == stream_length else {
    fail(
      "\{label}: took \{decompressor.last_consumed()} bytes of a stream of \{stream_length}",
    )
  }
}

///|
test "Decompressor::last_consumed is the length of the stream" {
  let decompressor = @flate.Decompressor()
  @test.assert_eq(decompressor.last_consumed(), 0)
  // Behind the stream: zeros, ones, and the start of another stream that a
  // decoder reading on would decode.
  let tails : Array[Bytes] = [
    Bytes::make(17, b'\x00'),
    Bytes::make(17, b'\xFF'),
    @flate.deflate_all(make_bytes(0xF1A7E003U, 64, 256), level=0)[:17].to_owned(),
  ]
  for stream in pin_streams() {
    let (name, plain, raw) = stream
    guard pin_streaming(raw) is Ok((_, used)) && used == raw.length() else {
      fail("\{name}: the streaming inflater does not end with the stream")
    }
    // An output of the exact size ends on the careful path; with room to
    // spare the native batch decodes the final end-of-block itself, if eight
    // more input bytes are in the view.
    for slack in [0, 300] {
      let output = FixedArray::make(plain.length() + slack, b'\x00')
      for tail in tails {
        for extra in 0..<=17 {
          guard raw.length() <= 300 || extra <= 1 || extra == 8 || extra == 17 else {
            continue
          }
          let label = "\{name}, \{slack} bytes of room, \{extra} bytes from \{tail[0]} behind"
          let input = raw + tail[:extra].to_owned()
          pin_consumed_case(
            label,
            decompressor,
            input,
            output,
            plain,
            raw.length(),
          )
          // The same stream as a view with other bytes around it.
          let around = tail + input + tail
          pin_consumed_case(
            "\{label}, as a view",
            decompressor,
            around[tail.length():tail.length() + input.length()],
            output,
            plain,
            raw.length(),
          )
        }
      }
    }
  }
}

///|
/// One `decompress_into` as text: the bytes written, or `Kind: message`.
fn pin_into(
  decompressor : @flate.Decompressor,
  input : BytesView,
  output : FixedArray[Byte],
  cancelled? : () -> Bool,
) -> String {
  try decompressor.decompress_into(input, output, cancelled?) catch {
    InflateError(kind, message) => "\{@debug.to_string(kind)}: \{message}"
  } noraise {
    written => "\{written} bytes"
  }
}

///|
/// The count belongs to the latest call. Every call replaces it; a call that
/// raises leaves zero, whatever it raised and however far it got, and the
/// decompressor decodes the next stream as a new one would.
test "Decompressor::last_consumed follows every call of one decompressor" {
  let plain = pin_pdf_text(10000)
  let stream = @flate.deflate_all(plain)
  let other = @flate.deflate_all(b"another stream")
  let output = FixedArray::make(plain.length(), b'\x00')
  let decompressor = @flate.Decompressor()
  @test.assert_eq(decompressor.last_consumed(), 0)
  let failures : Array[(String, () -> String)] = [
    (
      "OutputLimitExceeded: decoded output exceeds output buffer",
      () => {
        let short = FixedArray::make(plain.length() - 1, b'\x00')
        pin_into(decompressor, stream, short)
      },
    ),
    (
      "Cancelled: cancelled by caller",
      () => pin_into(decompressor, stream, output, cancelled=() => true),
    ),
    (
      // Not at entry: at the second poll, with 4096 bytes decoded.
      "Cancelled: cancelled by caller",
      () => {
        let mut polls = 0
        pin_into(decompressor, stream, output, cancelled=() => {
          polls += 1
          polls == 2
        })
      },
    ),
    (
      "Truncated: unexpected end of input",
      () => pin_into(decompressor, stream[:stream.length() - 1], output),
    ),
    (
      "Corrupt: corrupt: reserved block type",
      () => pin_into(decompressor, b"\x07", output),
    ),
  ]
  for failure in failures {
    let (expected, call) = failure
    // A stream, then the failure, then another stream and the first again.
    @test.assert_eq(
      pin_into(decompressor, stream + b"behind", output),
      "10000 bytes",
    )
    @test.assert_eq(decompressor.last_consumed(), stream.length())
    @test.assert_eq(call(), expected)
    @test.assert_eq(decompressor.last_consumed(), 0)
    @test.assert_eq(pin_into(decompressor, other, output), "14 bytes")
    @test.assert_eq(decompressor.last_consumed(), other.length())
    @test.assert_eq(pin_into(decompressor, stream, output), "10000 bytes")
    @test.assert_eq(Bytes::from_array(output), plain)
    @test.assert_eq(decompressor.last_consumed(), stream.length())
  }
}

///|
test "Decompressor::last_consumed is zero after a call that raises" {
  let decompressor = @flate.Decompressor()
  let output = FixedArray::make(16, b'\x00')
  // A fixed block, then a final stored block: the bytes read ahead of the
  // first are given back before the lengths of the second are read.
  let stream : Bytes = b"\x4A\x04\x04\x02\x00\xFD\xFF\x62\x63"
  let behind = stream + b"\x4A\x04\x04\x02\x00\xFD\xFF\x62\x63"
  @test.assert_eq(decompressor.decompress_into(behind, output), 3)
  @test.assert_eq(Bytes::from_array(output[:3]), b"abc")
  @test.assert_eq(decompressor.last_consumed(), stream.length())
  for cut in 0..<stream.length() {
    // A view that ends inside the stream is truncated, whatever the buffer
    // holds behind the view.
    let InflateError(kind, message) = @test.expect_error(() => {
      decompressor.decompress_into(behind[:cut], output)
    })
    @test.assert_eq(kind, Truncated)
    @test.assert_eq(message, "unexpected end of input")
    @test.assert_eq(decompressor.last_consumed(), 0)
    @test.assert_eq(decompressor.decompress_into(stream, output), 3)
    @test.assert_eq(decompressor.last_consumed(), stream.length())
  }
}
