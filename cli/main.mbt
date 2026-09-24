///|
priv suberror CliError {
  InvalidCompressionLevel(String)
}

///|
fn parse_level(value : String) -> Int raise CliError {
  let level = @string.parse_int(value, base=10) catch {
    _ => raise InvalidCompressionLevel(value)
  }
  guard level >= 0 && level <= 9 else { raise InvalidCompressionLevel(value) }
  level
}

///|
fn zip_command() -> @argparse.Command {
  @argparse.Command(
    "flate-cli",
    about=(
      #|Create a ZIP archive from files and directories (recursively).
      #|Inputs are stored under their base names. Existing output is never overwritten.
      #|Skips .DS_Store and __MACOSX; rejects symlinks and special files.
      #|The output must be outside the selected directories.
    ),
    options=[
      @argparse.OptionArg(
        "level",
        short='l',
        about="compression level 0–9 (0 disables Deflate compression; default: 6)",
        default_values=["6"],
      ),
    ],
    positionals=[
      @argparse.PositionArg(
        "input",
        about="file or directory to archive",
        num_args=@argparse.ValueRange(lower=1),
      ),
      @argparse.PositionArg(
        "output",
        about="ZIP file to create",
        num_args=@argparse.ValueRange::single(),
      ),
    ],
  )
}

///|
async fn main {
  let matches = zip_command().parse()
  guard matches.values
    is { "output": [output], "input": inputs, "level": [value], .. } else {
    // Required arguments and the level default are guaranteed by the definition.
    panic()
  }
  zip_entries(output, inputs, level=parse_level(value))
}
