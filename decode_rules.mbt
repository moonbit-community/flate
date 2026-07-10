///|
/// Validate the one's-complement length pair carried by a stored block.
#inline
fn validate_stored_length(len : Int, nlen : Int) -> Unit raise InflateError {
  if len != (nlen ^ 0xFFFF) {
    raise InflateError(Corrupt, "stored block length mismatch")
  }
}

///|
/// Interpret HLIT while preserving its reserved-value diagnostic before any
/// later dynamic-header fields are read.
#inline
fn dynamic_literal_count(bits : Int) -> Int raise InflateError {
  let count = bits + 257
  if count > max_num_lit {
    raise InflateError(Corrupt, "corrupt: too many literal codes")
  }
  count
}

///|
/// Interpret HDIST and reject the two reserved five-bit encodings.
#inline
fn dynamic_distance_count(bits : Int) -> Int raise InflateError {
  let count = bits + 1
  if count > max_num_dist {
    raise InflateError(Corrupt, "corrupt: too many distance codes")
  }
  count
}

///|
/// Check that a back-reference reaches a byte in the decoder's available
/// history. The caller supplies the history size appropriate to its execution
/// strategy (one-shot output or the streaming circular window), which is
/// always non-negative. Subtracting one as `UInt` turns the inclusive valid
/// interval `1..=available_history` into one upper-bound comparison; zero and
/// negative distances wrap above the bound and are rejected as well.
#inline
fn back_reference_distance_is_valid(
  distance : Int,
  available_history : Int,
) -> Bool {
  distance.reinterpret_as_uint() - 1U < available_history.reinterpret_as_uint()
}
