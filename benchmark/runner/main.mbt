// Benchmark CLI plumbing is outside the library coverage gate.

///|
#coverage.skip
fn read_input(path : String) -> Bytes {
  @fs.read_file_to_bytes(path) catch {
    _ => abort("cannot read input")
  }
}

///|
#coverage.skip
fn parse_number(value : String) -> Int {
  @string.parse_int(value) catch {
    _ => abort("invalid integer argument")
  }
}

///|
#coverage.skip
fn compress(input : Bytes, format : String, level : Int) -> Bytes {
  match format {
    "raw" => @flate.deflate_all(input, level~)
    "zlib" => @zlib.zlib_compress(input, level~)
    "gzip" => @gzip.gzip_compress(input, level~)
    _ => abort("invalid format")
  }
}

///|
#coverage.skip
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
#coverage.skip
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
#coverage.skip
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
#coverage.skip
fn verify(expected : Bytes, actual : Bytes) -> Unit {
  guard expected == actual else { abort("decoded payload mismatch") }
}

///|
// The result dies before returning, so allocation and reclamation are timed.
#coverage.skip
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
#coverage.skip
fn measure(
  operation : () -> Int,
  milliseconds : Int,
  output_size : Int,
) -> Unit {
  // Zero duration validates once without warmup, calibration, or timing.
  if milliseconds == 0 {
    let sink = operation()
    println(
      "{\"iterations\":0,\"seconds\":0,\"output_bytes\":\{output_size},\"sink\":\{sink}}",
    )
    return
  }
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
#coverage.skip
fn main {
  let args = @env.args()
  guard args.length() == 9 || args.length() == 10 else {
    abort(
      "usage: runner bound|export|compress|decompress direct|oneshot raw|zlib|gzip LEVEL INPUT FIXTURE MILLISECONDS OUTPUT_CAPACITY [DECODE_SAMPLES]",
    )
  }
  let operation = args[1]
  let mode = args[2]
  let format = args[3]
  let level = parse_number(args[4])
  let input = read_input(args[5])
  let fixture_path = args[6]
  let milliseconds = parse_number(args[7])
  let capacity = parse_number(args[8])
  let samples = if args.length() == 10 { parse_number(args[9]) } else { 1 }
  guard samples > 0 else { abort("sample count must be positive") }
  guard args.length() == 9 || (operation == "decompress" && mode == "direct") else {
    abort("repeated samples require direct decompression")
  }
  guard level >= 0 && level <= 9 && milliseconds >= 0 && capacity >= 0 else {
    abort("level must be 0..9; duration and capacity must be nonnegative")
  }
  guard mode == "oneshot" || (mode == "direct" && format == "raw") else {
    abort("direct mode supports only raw DEFLATE")
  }
  if operation == "bound" {
    guard mode == "direct" else { abort("bound requires direct mode") }
    println(@flate.deflate_bound(input.length()))
    return
  }
  if mode == "direct" {
    if operation == "decompress" {
      guard capacity == input.length() else {
        abort("decode capacity mismatch")
      }
      let fixture = read_input(fixture_path)
      let codec = @flate.Decompressor()
      let output = FixedArray::make(input.length(), b'\x00')
      let run = () => {
        let written = decompress_direct(codec, fixture, output)
        let last = if written == 0 { 0 } else { output[written - 1].to_int() }
        written + last
      }
      ignore(run())
      verify(input, Bytes::from_array(output[:]))
      // Diagnostic repetitions retain the same codec and buffer addresses.
      // Each sample still includes per-stream reset and table construction.
      for _ in 0..<samples {
        measure(run, milliseconds, input.length())
        verify(input, Bytes::from_array(output[:]))
      }
    } else {
      let codec = @flate.Compressor(level~)
      guard capacity >= @flate.deflate_bound(input.length()) else {
        abort("compression capacity below bound")
      }
      let output = FixedArray::make(capacity, b'\x00')
      let written = compress_direct(codec, input, output)
      let run = () => {
        let actual = compress_direct(codec, input, output)
        guard actual == written else { abort("compressed length changed") }
        let last = if actual == 0 { 0 } else { output[actual - 1].to_int() }
        actual + last
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
