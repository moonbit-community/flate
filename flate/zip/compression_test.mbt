///|
test "filename compression stores known compressed formats ignoring case" {
  for name in ["photo.jpg", "photo.JpG", "archive.tar.gz", "report.xlsx"] {
    @test.assert_eq(@zip.Compression::for_filename(name), @zip.Store)
  }
}

///|
test "filename compression deflates uncompressed or unknown final extensions" {
  for
    name in [
      "README", "notes.txt", "archive.tar", "image.bmp", "audio.wav", "data.unknown",
      "trailing.", ".gitignore", "archive.gz.bak",
    ] {
    @test.assert_eq(@zip.Compression::for_filename(name), @zip.Deflate)
  }
}
