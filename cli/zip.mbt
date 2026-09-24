///|
priv suberror ArchiveError {
  InvalidName(String)
  EmptySelection
  UnsupportedEntry(String)
  OutputIsInput(String)
  DuplicateName(String)
}

///|
/// Bridge the synchronous ZIP sink to async writes. Drain after every writer
/// operation so file payloads never accumulate beyond one input chunk plus
/// codec buffers. ZIP central-directory metadata still scales with entry count.
priv struct ZipOutput {
  file : @fs.File
  mut pending : Array[Bytes]
}

///|
async fn ZipOutput::flush(self : ZipOutput) -> Unit {
  let pending = self.pending
  self.pending = []
  for bytes in pending {
    self.file.write(bytes)
  }
  // Even a buffered read or a chunk producing no output must yield to other tasks.
  @async.pause()
}

///|
/// A single portable ZIP path component, never a filesystem path.
fn validate_archive_name(name : String) -> Unit raise ArchiveError {
  guard name != "" && name != "." && name != ".." else {
    raise InvalidName(name)
  }
  guard !name.contains_any(chars="/\\:\u0000") else { raise InvalidName(name) }
}

///|
priv struct ArchiveInput {
  path : String
  name : String
}

///|
async fn zip_entries(
  output : String,
  paths : Array[String],
  level~ : Int,
) -> Unit {
  let inputs : Array[ArchiveInput] = []
  for path in paths {
    // Strip trailing separators before lstat so a directory symlink is still
    // rejected. Resolve parents only after checking the selected entry itself.
    let path = path.trim_end(chars="/").to_owned()
    guard path != "" else { raise InvalidName(path) }
    let kind = @fs.kind(path, follow_symlink=false)
    guard kind is (Regular | Directory) else { raise UnsupportedEntry(path) }
    let path = @fs.realpath(path)
    let name = path.rev_after("/").unwrap_or(path[:]).to_owned()
    validate_archive_name(name)
    guard name != ".DS_Store" && name != "__MACOSX" else { continue }
    guard !inputs.any(input => input.name == name) else {
      raise DuplicateName(name)
    }
    inputs.push({ path, name, })
  }
  guard !inputs.is_empty() else { raise EmptySelection }
  let file = @fs.create(output, allow_existing=false)
  defer file.close()
  errdefer {
    file.close()
    @fs.remove(output)
  }
  let output_path = @fs.realpath(output)
  for input in inputs {
    guard output_path != input.path && !output_path.has_prefix(input.path + "/") else {
      raise OutputIsInput(output)
    }
  }
  let sink : ZipOutput = { file, pending: [], }
  let writer = @zip.Writer(bytes => sink.pending.push(bytes.to_owned()), level~)
  for input in inputs {
    add_archive_entry(writer, sink, input.path, input.name)
  }
  writer.finish()
  sink.flush()
}

///|
/// Explicit directory entries preserve empty folders. Never follow symlinks:
/// a link may lead outside the selection or back into its own directory tree.
async fn add_archive_entry(
  writer : @zip.Writer,
  sink : ZipOutput,
  path : String,
  name : String,
) -> Unit {
  let basename = name.rev_after("/").unwrap_or(name[:]).to_owned()
  guard basename != ".DS_Store" && basename != "__MACOSX" else { return }
  let kind = @fs.kind(path, follow_symlink=false)
  match kind {
    Directory => {
      writer.add(name + "/", b"", compression=Store)
      sink.flush()
      let dir = @fs.opendir(path)
      defer dir.close()
      while dir.next(include_hidden=true, include_special=false) is Some(entry) {
        validate_archive_name(entry.name)
        add_archive_entry(
          writer,
          sink,
          path + "/" + entry.name,
          name + "/" + entry.name,
        )
      }
    }
    Regular => {
      let file = @fs.open(path, mode=ReadOnly)
      defer file.close()
      writer.begin_entry(
        name,
        compression=archive_compression(basename),
        size=file.size().reinterpret_as_uint64(),
      )
      sink.flush()
      while file.read_some(max_len=64 * 1024) is Some(data) {
        writer.write(data)
        sink.flush()
      }
      writer.end_entry()
      sink.flush()
    }
    _ => raise UnsupportedEntry(path)
  }
}

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
/// A conservative extension policy: skip recompression for common compressed
/// formats, but keep compressing text and uncompressed containers such as TAR,
/// BMP and WAV. Unknown extensions still use Deflate.
fn archive_compression(name : String) -> @zip.Compression {
  guard name.rev_find(".") is Some(dot) else { return Deflate }
  let extension = name.view(start_offset=dot + 1).to_owned().to_lower()
  guard !stored_archive_extensions.contains(extension) else { Store }
  Deflate
}
