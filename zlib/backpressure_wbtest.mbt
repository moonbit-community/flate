///|
test "zlib wrappers bound accepted input under output backpressure" {
  let source = Bytes::from_array(Array::make(200000, b'\xA5'))
  let no_output = FixedArray::make(0, b'\x00')

  let encoder = Encoder::new(level=0)
  let enc_status = encoder.step(source[:], no_output.mut_view(), action=Finish)
  let enc_consumed = encoder.last_consumed()
  let enc_produced = encoder.last_produced()
  assert_true(enc_status is NeedMoreOutput)
  assert_true(enc_consumed > 0)
  assert_true(enc_consumed < source.length())
  assert_eq(enc_produced, 0)

  let compressed = zlib_compress(source, level=0)
  let decoder = Decoder::new()
  assert_eq(decoder.unused_input(), b"")
  let dec_status = decoder.step(compressed[:], no_output.mut_view(), end=true)
  let dec_consumed = decoder.last_consumed()
  let dec_produced = decoder.last_produced()
  assert_true(dec_status is NeedMoreOutput)
  assert_eq(dec_consumed, decoder_input_limit)
  assert_true(dec_consumed < compressed.length())
  assert_eq(dec_produced, 0)
  assert_true(decoder.pending.length() <= decoder_input_limit)
  assert_false(decoder.ending)
  let mut input_pos = dec_consumed
  let mut saw_consumed_prefix = false
  let mut saw_fresh_window = false
  for _ in 0..<8 {
    if decoder.pending.length() == decoder_input_limit {
      if decoder.pending_pos > 0 {
        saw_consumed_prefix = true
      } else {
        saw_fresh_window = true
      }
    }
    let status = decoder.step(
      compressed[input_pos:],
      no_output.mut_view(),
      end=true,
    )
    let consumed = decoder.last_consumed()
    let produced = decoder.last_produced()
    assert_true(status is NeedMoreOutput)
    assert_eq(produced, 0)
    input_pos = input_pos + consumed
  }
  assert_true(saw_consumed_prefix)
  assert_true(saw_fresh_window)
  assert_true(input_pos < compressed.length())
}
