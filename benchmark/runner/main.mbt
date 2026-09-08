///|
fn read_input(path : String) -> Bytes {
  @fs.read_file_to_bytes(path) catch {
    _ => abort("cannot read input")
  }
}

///|
fn parse_number(value : String) -> Int {
  @string.parse_int(value) catch {
    _ => abort("invalid integer argument")
  }
}

///|
fn compress(input : Bytes, format : String, level : Int) -> Bytes {
  match format {
    "raw" => @flate.deflate_all(input, level~)
    "zlib" => @zlib.zlib_compress(input, level~)
    "gzip" => @gzip.gzip_compress(input, level~)
    _ => abort("invalid format")
  }
}

///|
fn decompress(input : Bytes, format : String) -> Bytes {
  match format {
    "raw" =>
      @flate.inflate_all(input) catch {
        _ => abort("raw decompression failed")
      }
    "zlib" =>
      @zlib.zlib_decompress(input) catch {
        _ => abort("zlib decompression failed")
      }
    "gzip" =>
      @gzip.gunzip(input) catch {
        _ => abort("gzip decompression failed")
      }
    _ => abort("invalid format")
  }
}

///|
fn compress_direct(
  codec : @flate.Compressor,
  input : Bytes,
  output : FixedArray[Byte],
) -> Int {
  codec
  .compress_into(input, output)
  .unwrap_or_else(() => abort("compression output exhausted"))
}

///|
fn decompress_direct(
  codec : @flate.Decompressor,
  input : Bytes,
  output : FixedArray[Byte],
) -> Int {
  let written = codec.decompress_into(input, output) catch {
    _ => abort("direct decompression failed")
  }
  guard written == output.length() else { abort("decoded length mismatch") }
  written
}

///|
fn verify(expected : Bytes, actual : Bytes) -> Unit {
  guard expected == actual else { abort("decoded payload mismatch") }
}

///|
// The result dies before returning, so allocation and reclamation are timed.
fn consume_result(bytes : Bytes, expected_size : Int) -> Int {
  guard bytes.length() == expected_size else { abort("output length changed") }
  let last = if bytes.length() == 0 {
    0
  } else {
    bytes[bytes.length() - 1].to_int()
  }
  bytes.length() + last
}

///|
fn measure(
  operation : () -> Int,
  milliseconds : Int,
  output_size : Int,
) -> Unit {
  let mut sink = 0
  for _ in 0..<3 {
    sink = sink + operation()
  }
  // Discard calibration batches. Only the final batch contributes a sample.
  let (iterations, seconds) = for count = 1 {
    let started = @bench.monotonic_clock_start()
    for _ in 0..<count {
      sink = sink + operation()
    }
    let seconds = @bench.monotonic_clock_end(started) / 1000000.0
    if seconds * 1000.0 >= milliseconds.to_double() {
      break (count, seconds)
    }
    guard count < 536870912 else { abort("calibration iteration limit") }
    continue count * 2
  }
  println(
    "{\"iterations\":\{iterations},\"seconds\":\{seconds},\"output_bytes\":\{output_size},\"sink\":\{sink}}",
  )
}

///|
fn main {
  let args = @env.args()
  guard args.length() == 8 else {
    abort(
      "usage: runner export|compress|decompress direct|oneshot raw|zlib|gzip LEVEL INPUT FIXTURE MILLISECONDS",
    )
  }
  let operation = args[1]
  let mode = args[2]
  let format = args[3]
  let level = parse_number(args[4])
  let input = read_input(args[5])
  let fixture_path = args[6]
  let milliseconds = parse_number(args[7])
  guard level >= 0 && level <= 9 && milliseconds > 0 else {
    abort("level must be 0..9 and duration must be positive")
  }
  guard mode == "oneshot" || (mode == "direct" && format == "raw") else {
    abort("direct mode supports only raw DEFLATE")
  }
  if mode == "direct" {
    if operation == "decompress" {
      let fixture = read_input(fixture_path)
      let codec = @flate.Decompressor()
      let output = FixedArray::make(input.length(), b'\x00')
      let run = () => decompress_direct(codec, fixture, output)
      guard run() == input.length() else { abort("decoded length mismatch") }
      verify(input, Bytes::from_array(output[:]))
      measure(run, milliseconds, input.length())
      verify(input, Bytes::from_array(output[:]))
    } else {
      let codec = @flate.Compressor(level~)
      let output = FixedArray::make(
        @flate.deflate_bound(input.length()),
        b'\x00',
      )
      let written = compress_direct(codec, input, output)
      let run = () => {
        let actual = compress_direct(codec, input, output)
        guard actual == written else { abort("compressed length changed") }
        actual
      }
      let fixture = Bytes::from_array(output[:written])
      verify(input, decompress(fixture, "raw"))
      match operation {
        "export" =>
          @fs.write_bytes_to_file(fixture_path, fixture) catch {
            _ => abort("cannot write fixture")
          }
        "compress" => {
          measure(run, milliseconds, written)
          verify(fixture, Bytes::from_array(output[:written]))
        }
        _ => abort("invalid operation")
      }
    }
  } else {
    match operation {
      "export" | "compress" => {
        let fixture = compress(input, format, level)
        verify(input, decompress(fixture, format))
        if operation == "export" {
          @fs.write_bytes_to_file(fixture_path, fixture) catch {
            _ => abort("cannot write fixture")
          }
        } else {
          measure(
            () => {
              consume_result(compress(input, format, level), fixture.length())
            },
            milliseconds,
            fixture.length(),
          )
          verify(fixture, compress(input, format, level))
        }
      }
      "decompress" => {
        let fixture = read_input(fixture_path)
        verify(input, decompress(fixture, format))
        measure(
          () => consume_result(decompress(fixture, format), input.length()),
          milliseconds,
          input.length(),
        )
        verify(input, decompress(fixture, format))
      }
      _ => abort("invalid operation")
    }
  }
}
