# ZIP CLI

Install from the workspace root:

```sh
moon install ./cli
```

Then run `flate-cli` directly:

```sh
flate-cli file.txt directory archive.zip
flate-cli --level 9 file.txt directory archive.zip
flate-cli -l 1 file.txt archive.zip
flate-cli --help
```

The last positional argument is the output ZIP path; at least one input is required.
Relative and absolute input paths are accepted. Each input is stored under its
base name, with directory contents included recursively. Use `--` before paths
that begin with `-`.

`--level N` (or `-l N`) selects compression level 0–9, defaulting to 6.
Level 0 emits uncompressed Deflate blocks; known compressed extensions still use
ZIP Store at every level. Non-integer and out-of-range levels are rejected.

- Streams files in 64 KiB chunks; central-directory metadata grows with the
  number of entries.
- Uses Deflate for ordinary files and Store for known compressed extensions
  (case-insensitive).
- Preserves empty directories and hidden files, except `.DS_Store` and
  `__MACOSX`, which are skipped.
- Rejects symlinks, special files, duplicate input base names, and names that
  cannot be stored as portable ZIP path components.
- Creates new archives only. Existing output is never overwritten, and output
  inside an input directory is rejected. Failed writes remove partial output.

This frontend archives file contents and directory structure; it does not
preserve filesystem timestamps or permissions. Paths currently use Unix syntax.
