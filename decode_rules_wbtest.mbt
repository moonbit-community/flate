///|
test "shared distance-symbol interpretation follows the RFC table" {
  for symbol in 0..<max_num_dist {
    let info = distance_code_info_table[symbol]
    assert_eq(info >> 4, dist_base[symbol])
    assert_eq(info & 0xF, dist_extra[symbol])
  }
}

///|
test "packed length-symbol interpretation follows the RFC table" {
  for symbol in 257..<286 {
    let info = length_code_info_table[symbol - 257]
    let index = symbol - 257
    assert_eq(info >> 3, len_base[index])
    assert_eq(info & 0x7, len_extra[index])
  }
}

///|
test "shared stored-length validation checks the complement" {
  validate_stored_length(0x1234, 0xEDCB)
  try validate_stored_length(1, 0) catch {
    InflateError(kind, message) => {
      assert_true(kind == Corrupt)
      assert_eq(message, "stored block length mismatch")
    }
  } noraise {
    _ => fail("accepted a mismatched stored-block length")
  }
}

///|
test "shared dynamic counts retain their RFC boundaries" {
  assert_eq(dynamic_literal_count(29), 286)
  try ignore(dynamic_literal_count(30)) catch {
    InflateError(kind, message) => {
      assert_true(kind == Corrupt)
      assert_eq(message, "corrupt: too many literal codes")
    }
  } noraise {
    _ => fail("accepted a reserved HLIT value")
  }
  assert_eq(dynamic_distance_count(29), 30)
  try ignore(dynamic_distance_count(30)) catch {
    InflateError(kind, message) => {
      assert_true(kind == Corrupt)
      assert_eq(message, "corrupt: too many distance codes")
    }
  } noraise {
    _ => fail("accepted a reserved HDIST value")
  }
}

///|
/// HLIT is validated immediately: a reserved value must not be hidden by a
/// missing HDIST field. The byte contains BFINAL=1, BTYPE=dynamic, HLIT=31 and
/// no further input.
test "reserved HLIT wins over a truncated HDIST" {
  let data : Bytes = [0xFD]
  try ignore(inflate_all(data)) catch {
    InflateError(kind, message) => {
      assert_true(kind == Corrupt)
      assert_eq(message, "corrupt: too many literal codes")
    }
  } noraise {
    _ => fail("in-memory decoder read HDIST before validating HLIT")
  }
  let inflater = Inflater::new()
  let output = FixedArray::make(1, b'\x00')
  try ignore(inflater.step(data[:], output.mut_view(), end=true)) catch {
    InflateError(kind, message) => {
      assert_true(kind == Corrupt)
      assert_eq(message, "corrupt: too many literal codes")
    }
  } noraise {
    _ => fail("streaming decoder read HDIST before validating HLIT")
  }
}

///|
test "shared back-reference validation uses available history" {
  assert_true(back_reference_distance_is_valid(1, 1))
  assert_true(back_reference_distance_is_valid(window_size, window_size))
  assert_false(back_reference_distance_is_valid(0, window_size))
  assert_false(back_reference_distance_is_valid(-1, window_size))
  assert_false(back_reference_distance_is_valid(2, 1))
  assert_false(back_reference_distance_is_valid(1, 0))
}
