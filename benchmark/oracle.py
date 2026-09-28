"""Standard-library reference for deterministic inputs and independent zlib checks."""

import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import sys
import zlib


def main():
    operation, *args = sys.argv[1:]
    if operation == "info":
        print(json.dumps({
            "started_utc": datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ"),
            "platform": platform.platform(), "machine": platform.machine(),
            "cpu_count": os.cpu_count(), "python": sys.version,
            "zlib_version": zlib.ZLIB_RUNTIME_VERSION,
        }))
    elif operation == "shake":
        seed, size = args
        sys.stdout.buffer.write(hashlib.shake_256(seed.encode()).digest(int(size)))
    elif operation == "compress":
        source, target, fmt = args
        compressor = zlib.compressobj(6, wbits={"raw": -15, "zlib": 15, "gzip": 31}[fmt])
        data = Path(source).read_bytes()
        Path(target).write_bytes(compressor.compress(data) + compressor.flush())
    elif operation == "validate":
        source, fixture, fmt = args
        decoder = zlib.decompressobj({"raw": -15, "zlib": 15, "gzip": 31}[fmt])
        data = Path(fixture).read_bytes()
        decoded = decoder.decompress(data) + decoder.flush()
        if decoded != Path(source).read_bytes() or not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:
            raise ValueError("fixture failed independent full-stream validation")
    else:
        raise ValueError("unknown oracle operation")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, zlib.error) as error:
        sys.exit(str(error))
