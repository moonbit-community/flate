// Block planning for the streaming encoder. Input lives in a fixed mirrored
// ring: the first half is indexed by absolute position modulo 64 KiB and the
// second half mirrors it for branch-free SIMD comparisons across the wrap.
// The parser and its 32 KiB matchfinder survive every block boundary.

///|
/// Bytes of unconsumed lookahead reserved beyond a non-final block boundary so
/// matches there see their full extent.
pub const MIN_LOOKAHEAD : Int = 258

///|
fn Deflater::pending_bytes(self : Deflater) -> Int {
  self.pending_end - self.parse_pos
}

///|
fn Deflater::push_pending_byte(self : Deflater, byte : Byte) -> Unit {
  let offset = self.pending_end & STREAM_RING_MASK
  self.pending[offset] = byte
  self.pending[offset + STREAM_RING_SIZE] = byte
  self.pending_end = self.pending_end + 1
}

///|
fn Deflater::write_stored_pending(self : Deflater, is_final~ : Bool) -> Unit {
  write_stored_window(
    self.w,
    self.pending,
    self.parse_pos,
    self.pending_end,
    is_final~,
  )
  self.parse_pos = self.pending_end
}

///|
// The final two bytes of an earlier accepted chunk could not yet form a
// 3-byte hash. Insert them once new lookahead makes them hashable; all older
// history is already present in the persistent chain.
fn Deflater::chain_ready_history(self : Deflater) -> Unit {
  let ready_end = self.parse_pos.min((self.pending_end - 2).max(0))
  while self.hashed_through < ready_end {
    insert_window_pos(
      self.pending,
      self.finder,
      self.hashed_through,
      self.pending_end,
    )
    self.hashed_through = self.hashed_through + 1
  }
}

///|
fn Deflater::record_chained_positions(self : Deflater, processed : Int) -> Unit {
  let chained_end = processed.min((self.pending_end - 2).max(0))
  if chained_end > self.hashed_through {
    self.hashed_through = chained_end
  }
}

///|
/// Emit one non-final parsed block. `pending` already includes the lookahead
/// tail, and `tokenize_window` only commits `DEFLATE_BLOCK_SIZE` bytes except
/// for an ordinary 258-byte match overhang.
fn Deflater::emit_capped(self : Deflater) -> Unit {
  let target = (self.parse_pos + DEFLATE_BLOCK_SIZE).min(self.pending_end)
  let tokens : Array[Int] = []
  let ll_freq = FixedArray::make(286, 0)
  let d_freq = FixedArray::make(30, 0)
  self.chain_ready_history()
  let processed = tokenize_window(
    self.pending,
    self.finder,
    self.parse_pos,
    target,
    self.pending_end,
    self.cfg,
    tokens,
    ll_freq,
    d_freq,
  )
  emit_window_block(
    self.w,
    self.pending,
    self.parse_pos,
    processed,
    tokens[:],
    ll_freq,
    d_freq,
    is_final=false,
  )
  self.parse_pos = processed
  self.record_chained_positions(processed)
  self.maybe_rebase()
}

///|
/// Level 0 bypasses parsing entirely and writes buffered bytes straight out of
/// the ring. With no matches, neither matchfinder nor history needs updates.
fn Deflater::emit_stored_all(self : Deflater, is_final~ : Bool) -> Unit {
  self.write_stored_pending(is_final~)
  self.parse_pos = 0
  self.pending_end = 0
}

///|
fn Deflater::emit_one(self : Deflater) -> Unit {
  guard self.level != 0 else {
    self.emit_stored_all(is_final=false)
    return
  }
  self.emit_capped()
}

///|
/// Tokenize all remaining input into one trailing block. The end bound removes
/// the non-final lookahead restriction while preserving the same parse policy.
fn Deflater::emit_trailing_block(self : Deflater, is_final~ : Bool) -> Int {
  let tokens : Array[Int] = []
  let ll_freq = FixedArray::make(286, 0)
  let d_freq = FixedArray::make(30, 0)
  self.chain_ready_history()
  let processed = tokenize_window(
    self.pending,
    self.finder,
    self.parse_pos,
    self.pending_end,
    self.pending_end,
    self.cfg,
    tokens,
    ll_freq,
    d_freq,
  )
  emit_window_block(
    self.w,
    self.pending,
    self.parse_pos,
    processed,
    tokens[:],
    ll_freq,
    d_freq,
    is_final~,
  )
  self.parse_pos = processed
  self.record_chained_positions(processed)
  self.maybe_rebase()
  processed
}

///|
/// Keep absolute positions comfortably below backend integer limits. This is
/// amortized over 1 GiB of source and preserves every live 32 KiB chain link.
fn Deflater::maybe_rebase(self : Deflater) -> Unit {
  let rebase_at = 1 << 30
  guard self.parse_pos >= rebase_at else { return }
  let offset = (self.parse_pos / STREAM_RING_SIZE - 1) * STREAM_RING_SIZE
  self.finder.rebase(offset)
  self.parse_pos = self.parse_pos - offset
  self.pending_end = self.pending_end - offset
  self.hashed_through = self.hashed_through - offset
}

///|
fn Deflater::emit_final(self : Deflater) -> Unit {
  if self.level == 0 {
    self.emit_stored_all(is_final=true)
  } else {
    while self.pending_bytes() > DEFLATE_BLOCK_SIZE {
      self.emit_capped()
    }
    ignore(self.emit_trailing_block(is_final=true))
  }
  self.w.flush()
  self.emitted_final = true
}

///|
fn Deflater::flush_stored(self : Deflater) -> Unit {
  if self.pending_bytes() > 0 {
    self.emit_stored_all(is_final=false)
  }
}

///|
fn Deflater::flush_capped(self : Deflater) -> Unit {
  while self.pending_bytes() > DEFLATE_BLOCK_SIZE {
    self.emit_capped()
  }
  if self.pending_bytes() > 0 {
    ignore(self.emit_trailing_block(is_final=false))
  }
}

///|
/// Sync flush (zlib `Z_SYNC_FLUSH`): drain all buffered bytes, then append an
/// empty byte-aligned stored block. The persistent matchfinder retains the
/// preceding window for the stream's next input.
fn Deflater::emit_flush(self : Deflater) -> Unit {
  if self.level == 0 {
    self.flush_stored()
  } else {
    self.flush_capped()
  }
  write_stored(self.w, b"", 0, 0, is_final=false)
}
