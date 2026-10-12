///|
/// Successful completion must retain only the cached transport suffix, not the
/// consumed zlib stream.
test "zlib completion releases consumed input and caches read-ahead" {
  let stream = compress(b"release the completed zlib stream")
  let suffix = b"NEXT-FRAME"
  let combined : Array[Byte] = []
  for byte in stream {
    combined.push(byte)
  }
  for byte in suffix {
    combined.push(byte)
  }
  let decoder = Decoder()
  let output = FixedArray::make(128, b'\x00')
  let status = decoder.step(Bytes::from_array(combined), output.mut_view())
  let consumed = decoder.last_consumed()
  assert_true(status is Done)
  @test.assert_eq(consumed, stream.length() + suffix.length())
  @test.assert_eq(decoder.pending.length(), 0)
  @test.assert_eq(decoder.pending_pos, 0)
  @test.assert_eq(decoder.unused, suffix)
  @test.assert_eq(decoder.unused_input(), suffix)
  @test.assert_eq(decoder.unused_input(), suffix)
}

///|
/// The failure latch is checked before buffering input or advancing either the
/// wrapper cursor.
test "zlib failed state freezes decoder cursors" {
  let malformed : Bytes = [0x78, 0x01, 0x07, 0x00, 0x00, 0x00, 0x01]
  let decoder = Decoder()
  let output = FixedArray::make(1, b'\x00')
  let ZlibError(first_kind, first_error) = @test.expect_error(() => {
    decoder.step(malformed, output.mut_view(), end=true)
  })
  let pending_pos = decoder.pending_pos
  let pending_length = decoder.pending.length()
  let ZlibError(repeated_kind, repeated_error) = @test.expect_error(() => {
    decoder.step(b"must not be accepted", output.mut_view())
  })
  assert_true(first_kind == InvalidDeflate)
  assert_true(repeated_kind == first_kind)
  @test.assert_eq(repeated_error, first_error)
  @test.assert_eq(decoder.pending_pos, pending_pos)
  @test.assert_eq(decoder.pending.length(), pending_length)
}

///|
/// `step_into` and `step` must give the same bytes, the same number of steps
/// and the same verdict for every split of input and output.
test "zlib step_into equals step for every input and output split" {
  let source = Bytes::makei(70000, i => {
    if i % 4096 < 2600 {
      b"streaming decoders must agree. "[i % 31]
    } else {
      ((i * 40503) >> 5).to_byte()
    }
  })
  for level in [0, 6] {
    let compressed = compress(source, level~)
    let damaged = FixedArray::makei(compressed.length(), i => compressed[i])
    damaged[compressed.length() - 1] = (damaged[compressed.length() - 1].to_int() ^
    1).to_byte()
    for stream in [compressed, Bytes::from_array(damaged)] {
      for split in [(1 << 20, 32768), (700, 32768), (9000, 4096), (33, 7)] {
        let (chunk, room) = split
        let outcomes : Array[(Bytes, Int32, String)] = []
        for fixed in [true, false] {
          let decoder = Decoder()
          let output = FixedArray::make(room, b'\x00')
          let decoded = @buffer.Buffer()
          let mut position = 0
          let mut steps = 0
          let mut verdict = "done"
          for ;; {
            let end = (position + chunk).min(stream.length())
            let status = try {
              if fixed {
                decoder.step_into(
                  stream[position:end],
                  output,
                  end=end == stream.length(),
                )
              } else {
                decoder.step(
                  stream[position:end],
                  output.mut_view(),
                  end=end == stream.length(),
                )
              }
            } catch {
              ZlibError(kind, _) => {
                verdict = @debug.to_string(kind)
                break
              }
            }
            position = position + decoder.last_consumed()
            for i in 0..<decoder.last_produced() {
              decoded.write_byte(output[i])
            }
            steps = steps + 1
            if status is Done {
              break
            }
          }
          outcomes.push((decoded.to_bytes(), steps, verdict))
        }
        @test.assert_eq(outcomes[0], outcomes[1])
        if physical_equal(stream, compressed) {
          @test.assert_eq(outcomes[0].0, source)
          @test.assert_eq(outcomes[0].2, "done")
        } else {
          @test.assert_eq(outcomes[0].2, "ChecksumMismatch")
        }
      }
    }
  }
}

///|
test "zlib view checksum batches equal bytewise updates" {
  let storage = FixedArray::makei(3 * CHECKSUM_VIEW_CHUNK + 40, i => {
    (i * 131 + i / 7).to_byte()
  })
  for view_start in [0, 3] {
    let view = storage.mut_view(start=view_start)
    for start in [0, 1, 17] {
      for
        length in [
          0,
          1,
          15,
          16,
          17,
          CHECKSUM_VIEW_CHUNK - 1,
          CHECKSUM_VIEW_CHUNK,
          CHECKSUM_VIEW_CHUNK + 1,
          2 * CHECKSUM_VIEW_CHUNK + 5,
          view.length() - start,
        ] {
        let batched = Decoder()
        let bytewise = Decoder()
        batched.checksum_view(view, start, length)
        for i in 0..<length {
          bytewise.adler.update_byte(view[start + i])
        }
        @test.assert_eq(batched.adler.finish(), bytewise.adler.finish())
      }
    }
    // A range that is not inside the view folds nothing.
    let outside = Decoder()
    outside.checksum_view(view, view.length() - 1, 2)
    outside.checksum_view(view, -1, 1)
    @test.assert_eq(outside.adler.finish(), Decoder().adler.finish())
  }
}
