///|
/// Common compressed formats that do not benefit from recompression.
let stored_archive_extensions : ReadOnlyArray[String] = [
  "7z", "aac", "apk", "apng", "avif", "br", "bz2", "docx", "ear", "epub", "flac",
  "gif", "gz", "heic", "heif", "ipa", "jar", "jfif", "jp2", "jpe", "jpeg", "jpg",
  "lz", "lz4", "lzma", "m4a", "m4v", "mkv", "mov", "mp3", "mp4", "odp", "ods", "odt",
  "ogg", "opus", "png", "pptx", "rar", "svgz", "tbz", "tbz2", "tgz", "txz", "tzst",
  "war", "webm", "webp", "woff", "woff2", "xlsx", "xz", "zip", "zst",
]

///|
/// Suggest a ZIP compression method from a file's base name (without directories).
/// The final extension is matched ignoring ASCII case: common compressed formats
/// use `Store`; unknown or absent extensions use `Deflate`, as do TAR, BMP and WAV.
/// This is an optional filename heuristic; it does not inspect file contents or
/// change the default compression method of `Archive` or `Writer`.
fn compression_for_filename(name : String) -> @zip.Compression {
  guard name.rev_find(".") is Some(dot) else { return Deflate }
  let extension = name.view(start_offset=dot + 1).to_owned().to_lower()
  guard !stored_archive_extensions.contains(extension) else { Store }
  Deflate
}
