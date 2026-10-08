///|
/// Which bounded resource was exceeded during a bounded read or write. The
/// payload-related kinds guard against decompression bombs; `PreservedSourceBytes`
/// bounds the complete source retained for byte-preserving rewrites;
/// `OutputBytes` bounds a serialization's total size.
pub(all) enum LimitKind {
  PackageBytes
  Entries
  EntryUncompressedBytes
  TotalUncompressedBytes
  PreservedSourceBytes
  OutputBytes
} derive(Eq, @debug.Debug)

///|
/// Machine-readable category for a ZIP container failure. The accompanying
/// `ZipError` message is intended for diagnostics rather than branching.
pub(all) enum ZipErrorKind {
  /// The input ended before a complete record, header, payload, or trailer.
  Truncated
  /// A fixed signature (local, central, end-of-central, zip64) was wrong.
  InvalidSignature
  /// No end-of-central-directory record could be located.
  MissingEndOfCentral
  /// The entry uses a compression method this package cannot decode. Carries
  /// the method code from the central directory.
  UnsupportedCompression(Int)
  /// An entry or archive name is not valid UTF-8.
  InvalidUtf8
  /// The archive uses a ZIP feature this package does not support (encryption,
  /// multi-disk, ambiguous or inconsistent records, ...).
  UnsupportedFeature
  /// The entry contains malformed DEFLATE data.
  InvalidDeflate
  /// The entry payload does not match its stored CRC-32.
  ChecksumMismatch
  /// A caller-supplied resource limit was exceeded.
  LimitExceeded(LimitKind, Int, Int)
  /// The caller's cancellation callback returned `true` during a bounded read.
  Cancelled
} derive(Eq, @debug.Debug)

///|
/// Structured ZIP failure: a stable category plus a human-readable diagnostic.
pub suberror ZipError {
  ZipError(ZipErrorKind, String)
}

///|
fn check_cancelled(cancelled : () -> Bool) -> Unit raise ZipError {
  if cancelled() {
    raise ZipError(Cancelled, "zip: cancelled")
  }
}

///|
/// Map a raw DEFLATE failure without losing cooperative cancellation.
fn wrap_inflate_error(err : @flate.InflateError) -> ZipError {
  let InflateError(kind, message) = err
  match kind {
    Cancelled => ZipError(Cancelled, message)
    Truncated => ZipError(Truncated, message)
    _ => ZipError(InvalidDeflate, message)
  }
}
