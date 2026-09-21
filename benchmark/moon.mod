name = "moonbit-community/flate-benchmark"

version = "0.0.1"

readme = "README.md"

repository = "https://github.com/moonbit-community/flate"

license = "Apache-2.0"

keywords = [ "benchmark", "compression", "deflate" ]

description = "Benchmark and tooling module for flate. Kept as a separate workspace module so the published library module stays free of external dependencies."

import {
  "moonbitlang/x@0.5.5",
  "moonbit-community/flate@0.8.2",
}
