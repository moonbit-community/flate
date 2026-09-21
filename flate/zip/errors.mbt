///|
/// Which bounded resource was exceeded during a bounded read or write. The
/// payload-related kinds guard against decompression bombs; `PreservedSource`
/// bounds the raw local/central records retained for byte-preserving rewrites;
/// `OutputBytes` bounds a serialization's total size.
pub(all) enum LimitKind {
  PackageBytes
  Entries
  EntryUncompressedBytes
  TotalUncompressedBytes
  PreservedSourceBytes
  OutputBytes
} derive(Eq, Debug)

///|
pub extend LimitKind with Eq::{not_equal, equal}

///|
pub extend LimitKind with Debug::{to_repr}

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
  /// A caller-supplied resource limit was exceeded.
  LimitExceeded(LimitKind, Int, Int)
  /// The caller's cancellation callback returned `true` during a bounded read.
  Cancelled
} derive(Eq, Debug)

///|
pub extend ZipErrorKind with Eq::{not_equal, equal}

///|
pub extend ZipErrorKind with Debug::{to_repr}

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
/// Map a raw DEFLATE failure onto the ZIP error surface.
fn wrap_inflate_error(err : Error) -> ZipError {
  match err {
    @flate.InflateError(_, message) =>
      ZipError(UnsupportedFeature, "zip: invalid DEFLATE stream: \{message}")
    _ => ZipError(UnsupportedFeature, "zip: invalid DEFLATE stream")
  }
}
