///|
/// Checksum an entry while polling ZIP's cancellation callback at entry,
/// between 4 KiB chunks, and after the final chunk.
fn crc32_cancellable(
  bytes : BytesView,
  cancelled~ : () -> Bool,
) -> UInt raise ZipError {
  check_cancelled(cancelled)
  let crc = @checksum.Crc32()
  let mut start = 0
  while start < bytes.length() {
    if start > 0 {
      check_cancelled(cancelled)
    }
    let end = start + (bytes.length() - start).min(4096)
    crc.update(bytes[start:end])
    start = end
  }
  check_cancelled(cancelled)
  crc.finish()
}
