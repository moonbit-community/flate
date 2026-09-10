// Benchmark CLI plumbing is outside the library coverage gate.

///|
#coverage.skip
fn fixture_args() -> ArrayView[String] {
  match @env.args() {
    [_, .. args] => args
    [] => []
  }
}

///|
#coverage.skip
fn parse_fixture_level(value : String) -> Int {
  @string.parse_int(value) catch {
    _ => abort("fixture level must be an integer")
  }
}

///|
#coverage.skip
fn main {
  let args = fixture_args()
  guard args.length() == 3 else {
    abort("usage: fixture_export INPUT OUTPUT LEVEL")
  }
  let input = @fs.read_file_to_bytes(args[0]) catch {
    _ => abort("could not read fixture input")
  }
  let level = parse_fixture_level(args[2])
  let output = FixedArray::make(@flate.deflate_bound(input.length()), b'\x00')
  guard @flate.deflate_into(input, output, level~) is Some(written) else {
    abort("deflate_bound did not fit its fixture input")
  }
  let compressed = Bytes::from_array(output[:written])
  @fs.write_bytes_to_file(args[1], compressed) catch {
    _ => abort("could not write MoonBit DEFLATE fixture")
  }
  println("wrote \{written} bytes")
}
