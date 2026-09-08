"""Tests for benchmark correctness and comparison boundaries, not codec internals."""

import json
from pathlib import Path
import tempfile
import unittest
import zlib

from run import report, summarize, validate_fixture


class BenchmarkTests(unittest.TestCase):
    def test_independent_validation_rejects_incomplete_wrong_and_trailing_data(self):
        payload = bytes(range(256)) * 4
        for fmt, bits in (("raw", -15), ("zlib", 15), ("gzip", 31)):
            with self.subTest(format=fmt):
                encoder = zlib.compressobj(wbits=bits)
                fixture = encoder.compress(payload) + encoder.flush()
                validate_fixture(payload, fixture, fmt)
                for expected, compressed in ((b"x" + payload[1:], fixture),
                                             (payload, fixture[:len(fixture) // 2]),
                                             (payload, fixture + b"trailing")):
                    with self.assertRaises((ValueError, zlib.error)):
                        validate_fixture(expected, compressed, fmt)

    def samples(self):
        rows = []
        for mode in ("direct", "oneshot"):
            for producer in ("flate", "libdeflate"):
                for impl in ("flate", "libdeflate"):
                    for iterations, seconds in ((2, 0.02), (4, 0.08), (2, 0.20)):
                        rows.append({"corpus": "example", "mode": mode, "format": "raw",
                                     "level": 6, "operation": "decompress", "producer": producer,
                                     "implementation": impl, "iterations": iterations,
                                     "seconds": seconds, "input_bytes": 1024,
                                     "output_bytes": 1024, "fixture_bytes": 100})
        return rows

    def test_summary_uses_per_operation_median_and_keeps_fixture_modes_separate(self):
        summary = summarize(self.samples())
        self.assertEqual(len(summary), 8)
        for row in summary:
            self.assertAlmostEqual(row["median_seconds"], 0.02)
            self.assertAlmostEqual(row["mib_s"], 1024 / 1048576 / 0.02)
            self.assertEqual(row["rounds"], 3)
            self.assertGreater(row["spread_pct"], 10)

    def test_report_preserves_raw_data_and_suppresses_nonparity_multipliers(self):
        metadata = {"profile": "quick", "started_utc": "test", "revision": "test",
                    "libdeflate_version": "test", "milliseconds": 40, "rounds": 3}
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)
            report(path, self.samples(), metadata)
            text = (path / "report.md").read_text()
            self.assertIn("NOISY", text)
            self.assertNotIn("1.00x", text.split("## oneshot")[1])
            self.assertEqual(len(json.loads((path / "summary.json").read_text())), 8)
            report(path, self.samples(), {**metadata, "profile": "smoke"})
            self.assertNotIn("1.00x", (path / "report.md").read_text())


if __name__ == "__main__":
    unittest.main()
