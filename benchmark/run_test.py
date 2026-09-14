"""Tests for benchmark correctness and comparison boundaries, not codec internals."""

import json
from pathlib import Path
import tempfile
import unittest
import zlib

from run import configurations, digest, paired_ratios, replay_corpora, report, summarize, validate_fixture


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
                    for round_index, (iterations, seconds) in enumerate(((2, 0.02), (4, 0.08), (2, 0.20))):
                        rows.append({"corpus": "example", "mode": mode, "format": "raw",
                                     "level": 6, "operation": "decompress", "producer": producer,
                                     "implementation": impl, "iterations": iterations,
                                     "seconds": seconds, "input_bytes": 1024,
                                     "round": round_index, "input_sha256": "input",
                                     "fixture_sha256": producer, "output_capacity": 1024,
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
            stable = self.samples()
            for row in stable:
                row["seconds"] = row["iterations"] * 0.02
            report(path, stable, metadata)
            text = (path / "report.md").read_text()
            self.assertIn("1.00x (1.00..1.00)", text.split("## oneshot")[0])
            self.assertNotIn("1.00x", text.split("## oneshot")[1])

    def test_default_suite_excludes_asymmetric_apis(self):
        manifest = [{"name": "source"}]
        self.assertTrue(all(row[1:3] == ("direct", "raw")
                            for row in configurations(manifest, "full")))
        self.assertTrue(any(row[1] == "oneshot"
                            for row in configurations(manifest, "quick", True)))

    def test_paired_ratio_uses_rounds_and_rejects_unfair_pairs(self):
        rows = [row for row in self.samples()
                if row["mode"] == "direct" and row["producer"] == "flate"]
        for row in rows:
            row["iterations"] = 1
            row["seconds"] = ({"flate": [1, 10, 100], "libdeflate": [1, 2, 100]}[
                row["implementation"]][row["round"]])
        self.assertEqual(next(iter(paired_ratios(rows).values()))["median"], 1)
        for field, value in (("fixture_sha256", "other"), ("input_sha256", "other"),
                             ("output_capacity", 2048)):
            modified = [dict(row) for row in rows]
            modified[0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                paired_ratios(modified)
        with self.assertRaises(ValueError):
            paired_ratios(rows[:-1])
        with self.assertRaises(ValueError):
            paired_ratios(rows + [rows[0]])

    def test_replay_verifies_hashes_and_preserves_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)
            payload = b"frozen corpus"
            (path / "input.bin").write_bytes(payload)
            manifest = [{"name": "source", "file": "input.bin", "bytes": len(payload),
                         "sha256": digest(payload)}]
            saved = path / "corpus.json"
            saved.write_text(json.dumps(manifest))
            target = path / "copy"
            target.mkdir()
            replayed = replay_corpora(saved, target)
            self.assertEqual((path / replayed[0]["file"]).read_bytes(), payload)
            (path / "input.bin").write_bytes(b"modified")
            with self.assertRaises(ValueError):
                replay_corpora(saved, target)


if __name__ == "__main__":
    unittest.main()
