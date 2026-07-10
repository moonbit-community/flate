// Block planning stage of the encode pipeline: decides where block boundaries
// fall and what state carries across them. Non-final blocks cover at most
// `deflate_block_size` tokenizable bytes (a cap as well as a floor: one
// Huffman table should not span heterogeneous megabytes, and the token buffer
// stays bounded). `emit_one` reserves a lookahead tail so boundary matches
// see their full extent; `emit_final` settles the remainder block-by-block;
// `emit_flush` is the sync-flush boundary the caller can force at any time.
// Level 0 bypasses parsing entirely and writes stored blocks.
//

///|
/// Bytes of unconsumed lookahead reserved beyond a non-final block boundary so
/// matches there see their full extent.
let min_lookahead = 258

///|
/// Trim `pending` so at most a 32 KB window of already-processed bytes remains
/// as history , and reset `window_carry`.
fn Deflater::trim_window(self : Deflater, processed : Int) -> Unit {
  let newstart = if processed > window_size {
    processed - window_size
  } else {
    0
  }
  if newstart > 0 {
    let kept : Array[Byte] = []
    for j in newstart..<self.pending.length() {
      kept.push(self.pending[j])
    }
    self.pending = kept
  }
  self.window_carry = processed - newstart
}

///|
/// Emit one non-final block covering at most `deflate_block_size` tokenizable
/// bytes (plus up to 257 bytes of match overhang), then trim `pending` back to
/// a 32 KB history window. The caller guarantees enough input is present for
/// matches at the boundary to see their full extent .
fn Deflater::emit_capped(self : Deflater) -> Unit {
  let data = Bytes::from_array(self.pending)
  let cap = self.window_carry + deflate_block_size
  let tok_end = if cap < data.length() { cap } else { data.length() }
  let tokens : Array[Int] = []
  let ll_freq = Array::make(286, 0)
  let d_freq = Array::make(30, 0)
  let processed = tokenize(
    data,
    self.window_carry,
    tok_end,
    self.cfg,
    tokens,
    ll_freq,
    d_freq,
  )
  emit_block(
    self.w,
    data,
    self.window_carry,
    processed,
    tokens[:],
    ll_freq,
    d_freq,
    is_final=false,
  )
  self.trim_window(processed)
}

///|
/// Level 0: no parsing, no Huffman — write everything buffered as stored
/// blocks. History is useless without matches, so `pending` empties entirely.
fn Deflater::emit_stored_all(self : Deflater, is_final~ : Bool) -> Unit {
  let data = Bytes::from_array(self.pending)
  write_stored(self.w, data, self.window_carry, data.length(), is_final~)
  self.pending.clear()
  self.window_carry = 0
}

///|
/// Emit one non-final block for the accrued input (level 0: all of it, as
/// stored blocks).
fn Deflater::emit_one(self : Deflater) -> Unit {
  if self.level == 0 {
    self.emit_stored_all(is_final=false)
  } else {
    self.emit_capped()
  }
}

///|
/// Tokenize all remaining input into final block(s) — capped non-final blocks
/// while more than one block's worth remains — and flush to a byte boundary.
fn Deflater::emit_final(self : Deflater) -> Unit {
  if self.level == 0 {
    self.emit_stored_all(is_final=true)
  } else {
    while self.pending.length() - self.window_carry > deflate_block_size {
      self.emit_capped()
    }
    let data = Bytes::from_array(self.pending)
    let tokens : Array[Int] = []
    let ll_freq = Array::make(286, 0)
    let d_freq = Array::make(30, 0)
    let processed = tokenize(
      data,
      self.window_carry,
      data.length(),
      self.cfg,
      tokens,
      ll_freq,
      d_freq,
    )
    emit_block(
      self.w,
      data,
      self.window_carry,
      processed,
      tokens[:],
      ll_freq,
      d_freq,
      is_final=true,
    )
  }
  self.w.flush()
  self.emitted_final = true
}

///|
/// Sync flush (zlib `Z_SYNC_FLUSH`): compress everything buffered into
/// block(s), then append an empty stored block whose mandatory byte alignment
/// pads the bit stream — after draining, every produced byte is final and
/// transmittable, and the stream continues. The window is kept (levels ≥ 1),
/// so post-flush data may still back-reference pre-flush data.
fn Deflater::emit_flush(self : Deflater) -> Unit {
  if self.level == 0 {
    if self.pending.length() > self.window_carry {
      self.emit_stored_all(is_final=false)
    }
  } else {
    while self.pending.length() - self.window_carry > deflate_block_size {
      self.emit_capped()
    }
    // Capped blocks may have consumed everything (match overhang); only emit
    // a trailing block if un-tokenized input actually remains.
    if self.pending.length() > self.window_carry {
      let data = Bytes::from_array(self.pending)
      let tokens : Array[Int] = []
      let ll_freq = Array::make(286, 0)
      let d_freq = Array::make(30, 0)
      let processed = tokenize(
        data,
        self.window_carry,
        data.length(),
        self.cfg,
        tokens,
        ll_freq,
        d_freq,
      )
      emit_block(
        self.w,
        data,
        self.window_carry,
        processed,
        tokens[:],
        ll_freq,
        d_freq,
        is_final=false,
      )
      self.trim_window(processed)
    }
  }
  write_stored(self.w, b"", 0, 0, is_final=false) // the 00 00 FF FF marker
}
