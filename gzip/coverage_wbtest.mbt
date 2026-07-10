///|
priv suberror CoverageOnlyError

///|
test "gzip buffering helper accepts an empty view as a no-op" {
  let decoder = Decoder::new()
  decoder.buffer_input(b""[:])
  assert_eq(decoder.available(), 0)
}

///|
test "gzip inflater error wrapper has a stable fallback" {
  let wrapped = wrap_inflate_error(CoverageOnlyError)
  match wrapped {
    GzipError(kind, message) => {
      assert_true(kind == InvalidDeflate)
      assert_eq(message, "gzip: invalid DEFLATE stream")
    }
  }
}
