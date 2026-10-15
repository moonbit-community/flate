///|
/// Transfers a fully initialized, exclusively owned byte array to immutable
/// Bytes without copying. Both types have the same byte-array representation.
/// SAFETY: the caller must relinquish every mutable alias after this call.
fn owned_zip_buffer_to_bytes(buffer : FixedArray[Byte]) -> Bytes = "%identity"

///|
/// Borrow an output array synchronously for checksum calculation. This alias
/// must never escape the call or survive another write to the output array.
fn borrowed_zip_buffer_bytes(buffer : FixedArray[Byte]) -> Bytes = "%identity"
