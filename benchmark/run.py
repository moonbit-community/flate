#!/usr/bin/env python3
"""Build and run paired native benchmarks; no third-party Python dependencies."""

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import statistics
import subprocess
import sys
import time
import zlib

ROOT = Path(__file__).resolve().parents[1]


def command(args, *, timeout=180):
    result = subprocess.run([str(a) for a in args], cwd=ROOT, text=True,
                            capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"Command failed: {shlex.join(map(str, args))}\n"
                           f"{result.stdout}{result.stderr}")
    return result.stdout.strip()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def corpora(directory, profile, extra):
    """Persist exact input bytes, including repository text as it exists now."""
    size = 262144
    phrase = b"The quick brown fox jumps over the lazy dog. Pack my box. "
    repetitive = (phrase * (size // len(phrase) + 1))[:size]
    random = hashlib.shake_256(b"flate-bench-v2/random/seed-1").digest(size)
    paths = sorted(ROOT.glob("*.mbt")) + sorted((ROOT / "inspect").glob("*.mbt"))
    source = b"\n".join(p.read_bytes() for p in paths)
    records = []
    for i in range(4000):
        records.append({"id": i, "status": ["open", "closed", "pending"][i % 3],
                        "name": f"record-{i}", "group": i % 97,
                        "value": (i * 2654435761) % 1000003,
                        "tags": [f"tag-{i % 31}", f"tag-{i % 17}"]})
    structured = json.dumps(records, separators=(",", ":")).encode()[:size]
    data = {
        "repetitive-256k": repetitive,
        "random-256k": random,
        "mixed-256k": repetitive[:size // 2] + random[:size // 2],
        "source": source[:size],
        "json-256k": structured,
        "precompressed": zlib.compress(source, 6),
        "source-4k": source[:4096],
        "repetitive-512": repetitive[:512],
        "repetitive-1m": repetitive * 4,
    }
    if profile == "smoke":
        data = {"empty": b"", "single": b"x", "source-4k": source[:4096],
                "mixed-256k": data["mixed-256k"]}
    if profile == "full":
        data.update({"random-4k": random[:4096], "source-64k": source[:65536],
                     "random-1m": hashlib.shake_256(b"flate-bench-v2/large").digest(1048576),
                     "distance-one-256k": b"a" * size})
    for i, path in enumerate(extra):
        data[f"external-{i}-{path.stem}"] = path.read_bytes()
    manifest = []
    for name, payload in data.items():
        path = directory / (name + ".bin")
        path.write_bytes(payload)
        manifest.append({"name": name, "bytes": len(payload), "sha256": digest(payload),
                         "file": str(path.relative_to(directory.parent))})
    return manifest


def configurations(manifest, profile):
    configs = []
    for corpus in manifest:
        name = corpus["name"]
        levels = [0, 1, 6, 9] if profile == "full" else [1, 6, 9]
        if profile == "quick" and name in {"source-4k", "repetitive-512", "repetitive-1m"}:
            levels = [6]
        if profile == "smoke":
            levels = [0, 6]
        for level in levels:
            configs.append((corpus, "direct", "raw", level))
        # L0 isolates stored output from matching and Huffman work.
        if profile == "quick" and name in {"random-256k", "source"}:
            configs.append((corpus, "direct", "raw", 0))
        wrappers = profile != "quick" or name in {"repetitive-256k", "random-256k", "source"}
        if wrappers:
            for fmt in ("raw", "zlib", "gzip"):
                configs.append((corpus, "oneshot", fmt, 6))
    return configs


def runner_args(binary, implementation, operation, mode, fmt, level, source, fixture, ms):
    prefix = [binary, "--sample"] if implementation == "libdeflate" else [binary]
    return prefix + [operation, mode, fmt, str(level), source, fixture, str(ms)]


def validate_fixture(payload, fixture, fmt):
    decoder = zlib.decompressobj({"raw": -15, "zlib": 15, "gzip": 31}[fmt])
    decoded = decoder.decompress(fixture) + decoder.flush()
    if decoded != payload or not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:
        raise ValueError("fixture failed independent full-stream validation")


def summarize(samples):
    groups = {}
    fields = ("corpus", "mode", "format", "level", "operation", "producer", "implementation")
    for sample in samples:
        key = tuple(sample[f] for f in fields)
        groups.setdefault(key, []).append(sample)
    summary = []
    for key, group in groups.items():
        values = [s["seconds"] / s["iterations"] for s in group]
        median = statistics.median(values)
        row = dict(zip(fields, key))
        row.update({"median_seconds": median,
                    "min_seconds": min(values), "max_seconds": max(values),
                    "spread_pct": 100 * (max(values) - min(values)) / median,
                    "mib_s": group[0]["input_bytes"] / 1048576 / median,
                    "input_bytes": group[0]["input_bytes"],
                    "output_bytes": group[0]["output_bytes"],
                    "fixture_bytes": group[0]["fixture_bytes"], "rounds": len(values)})
        summary.append(row)
    return summary


def report(directory, samples, metadata):
    summary = summarize(samples)
    write_json(directory / "summary.json", summary)
    lines = ["# Paired native benchmark", "",
             f"Profile: `{metadata['profile']}`. Started: {metadata['started_utc']}.",
             f"flate: `{metadata['revision']}`; libdeflate: `{metadata['libdeflate_version']}`.",
             f"Minimum batch: {metadata['milliseconds']} ms; rounds: {metadata['rounds']}.", "",
             "Each rate uses the median seconds/operation. Spread is (max-min)/median.",
             "A spread above 10% is marked `NOISY`; rerun before drawing conclusions.",
             "Compression rows compare the same level, not equal compressed size.",
             "Decode rows always use the same exact fixture for both implementations.",
             "One-shot includes codec/output allocation and release. C decode knows output size;",
             "MoonBit grows output. One-shot is an application comparison; no parity multiplier is shown.",
             "Wrapper inputs contain one member and no trailing bytes. Both verify checksums.",
             "These are warm-buffer, single-process-at-a-time runs without CPU pinning or thermal isolation.",
             "Build logs, binary hashes, source diff, fixture hashes and raw samples accompany this report.", ""]
    if metadata["profile"] == "smoke" or metadata["rounds"] < 3:
        lines += ["VALIDATION ONLY: fewer than three rounds or smoke profile; multipliers suppressed.", ""]
    index = {}
    for row in summary:
        key = tuple(row[k] for k in ("mode", "format", "corpus", "level", "operation", "producer"))
        index.setdefault(key, {})[row["implementation"]] = row
    for mode in ("direct", "oneshot"):
        lines += [f"## {mode}", "",
                  "| Format / corpus | L | Operation / fixture | flate MiB/s | C MiB/s | C / flate speed | Compressed bytes (flate / C, or shared fixture) | Spread flate / C |",
                  "| --- | ---: | --- | ---: | ---: | ---: | ---: | --- |"]
        for key, pair in index.items():
            if key[0] != mode or set(pair) != {"flate", "libdeflate"}:
                continue
            m, c = pair["flate"], pair["libdeflate"]
            ratio = c["mib_s"] / m["mib_s"] if m["mib_s"] else m["median_seconds"] / c["median_seconds"]
            comparable = mode == "direct" and metadata["rounds"] >= 3 and metadata["profile"] != "smoke"
            multiplier = f"{ratio:.2f}x" if comparable else "n/a"
            noisy = " NOISY" if max(m["spread_pct"], c["spread_pct"]) > 10 else ""
            byte_field = f"{m['output_bytes']} / {c['output_bytes']}" if key[4] == "compress" else str(m["fixture_bytes"])
            lines.append(f"| {key[1]} / {key[2]} | {key[3]} | {key[4]} / {key[5]} | "
                         f"{m['mib_s']:.1f} | {c['mib_s']:.1f} | {multiplier} | {byte_field} | "
                         f"{m['spread_pct']:.1f}% / {c['spread_pct']:.1f}%{noisy} |")
        lines.append("")
    lines += ["Empty-input throughput is zero; use summary.json median_seconds for latency.", "",
              "Full-stream validation uses Python zlib in addition to both benchmark decoders.",
              "Synthetic SHAKE bytes are deterministic; source is a snapshot of this repository,",
              "JSON is synthetic structured data, and precompressed is zlib-compressed source.",
              "Use --corpus FILE to add actual application data. Inspect time and size together",
              "across levels; the tables do not assert equal quality or a universal aggregate speedup.", ""]
    (directory / "report.md").write_text("\n".join(lines))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=("smoke", "quick", "full"), default="quick")
    parser.add_argument("--rounds", type=int)
    parser.add_argument("--milliseconds", type=int)
    parser.add_argument("--corpus", type=Path, action="append", default=[])
    parser.add_argument("--output", type=Path, help="new output directory (must not exist)")
    args = parser.parse_args()
    defaults = {"smoke": (1, 2), "quick": (3, 40), "full": (7, 150)}
    rounds = args.rounds if args.rounds is not None else defaults[args.profile][0]
    ms = args.milliseconds if args.milliseconds is not None else defaults[args.profile][1]
    if rounds < 1 or ms < 1:
        parser.error("rounds and milliseconds must be positive")
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    directory = (args.output or ROOT / ".local" / "bench" / stamp).resolve()
    directory.mkdir(parents=True, exist_ok=False)
    (directory / "corpus").mkdir()
    (directory / "fixtures").mkdir()
    started = time.monotonic()
    cc = shlex.split(os.environ.get("CC", "cc"))
    cflags = shlex.split(command(["pkg-config", "--cflags", "--libs", "libdeflate"]))
    c_binary = directory / "bench_libdeflate"
    build_c = cc + ["-O3", "-DNDEBUG", "-Wall", "-Wextra", "-Werror",
                    ROOT / "benchmark/bench_libdeflate.c"] + cflags + ["-o", c_binary]
    build_moon = ["moon", "build", "--release", "--target", "native", "--verbose",
                  "--target-dir", directory / "build", "benchmark/runner"]
    print(f"Building runners; results: {directory}", flush=True)
    (directory / "build-moon-commands.log").write_text(command(build_moon + ["--dry-run"]) + "\n")
    for name, cmd in (("c", build_c), ("moon", build_moon)):
        result = subprocess.run([str(v) for v in cmd], cwd=ROOT, text=True,
                                capture_output=True, timeout=180)
        (directory / f"build-{name}.log").write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"build failed; see {directory / ('build-' + name + '.log')}")
    candidates = list((directory / "build").glob("native/release/build/benchmark/runner/*.exe"))
    if len(candidates) != 1:
        raise RuntimeError(f"expected one MoonBit executable, got {candidates}")
    binaries = {"flate": candidates[0], "libdeflate": c_binary}
    metadata = {"schema": 1, "profile": args.profile, "started_utc": stamp,
                "rounds": rounds, "milliseconds": ms,
                "revision": command(["git", "rev-parse", "HEAD"]),
                "git_status": command(["git", "status", "--short"]),
                "moon": command(["moon", "version", "--all"]),
                "cc": command(cc + ["--version"]),
                "libdeflate_version": command(["pkg-config", "--modversion", "libdeflate"]),
                "libdeflate_prefix": command(["pkg-config", "--variable=prefix", "libdeflate"]),
                "platform": platform.platform(), "machine": platform.machine(),
                "cpu_count": os.cpu_count(), "python": sys.version,
                "zlib_version": zlib.ZLIB_RUNTIME_VERSION,
                "build_commands": [[str(x) for x in cmd] for cmd in (build_c, build_moon)],
                "binary_sha256": {k: digest(v.read_bytes()) for k, v in binaries.items()},
                "command": sys.argv}
    libdir = Path(command(["pkg-config", "--variable=libdir", "libdeflate"]))
    metadata["libdeflate_library_sha256"] = {
        str(p.resolve()): digest(p.read_bytes()) for p in libdir.glob("libdeflate.*") if p.is_file()
    }
    if sys.platform == "darwin":
        metadata["cpu"] = command(["sysctl", "-n", "machdep.cpu.brand_string"])
        metadata["linked_libraries"] = command(["otool", "-L", c_binary])
    (directory / "source.diff").write_text(command(["git", "diff", "HEAD", "--", "."]))
    # Includes untracked runner files, which git diff alone cannot preserve.
    source_files = list(ROOT.glob("*.mbt")) + list(ROOT.glob("*.pkg")) + [ROOT / "moon.mod"]
    for package in ("benchmark", "checksum", "gzip", "zlib"):
        source_files += [p for p in (ROOT / package).rglob("*") if p.is_file() and
                         p.suffix in {".mbt", ".pkg", ".c", ".py"}]
    metadata["source_sha256"] = {str(p.relative_to(ROOT)): digest(p.read_bytes()) for p in sorted(source_files)}
    for path in source_files:
        snapshot = directory / "source" / path.relative_to(ROOT)
        snapshot.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, snapshot)
    manifest = corpora(directory / "corpus", args.profile, args.corpus)
    write_json(directory / "corpus.json", manifest)
    write_json(directory / "metadata.json", metadata)
    configs = configurations(manifest, args.profile)
    samples = []
    fixtures = []
    with (directory / "samples.jsonl").open("w") as raw:
        for number, (corpus, mode, fmt, level) in enumerate(configs, 1):
            name = corpus["name"]
            source = directory / corpus["file"]
            payload = source.read_bytes()
            paths = {}
            for impl, binary in binaries.items():
                fixture = directory / "fixtures" / f"{name}-{mode}-{fmt}-L{level}-{impl}.bin"
                command(runner_args(binary, impl, "export", mode, fmt, level, source, fixture, ms))
                data = fixture.read_bytes()
                validate_fixture(payload, data, fmt)
                paths[impl] = fixture
                fixtures.append({"corpus": name, "mode": mode, "format": fmt, "level": level,
                                 "producer": impl, "bytes": len(data), "sha256": digest(data),
                                 "file": str(fixture.relative_to(directory))})
            jobs = [("compress", "none"), ("decompress", "flate"), ("decompress", "libdeflate")]
            for round_index in range(rounds):
                # Reverse both operation and implementation order on alternating rounds.
                for operation, producer in (jobs if round_index % 2 == 0 else list(reversed(jobs))):
                    order = ["flate", "libdeflate"]
                    if (round_index + number) % 2:
                        order.reverse()
                    for impl in order:
                        fixture = paths[impl if operation == "compress" else producer]
                        sample = json.loads(command(runner_args(binaries[impl], impl, operation,
                            mode, fmt, level, source, fixture, ms)))
                        if sample["iterations"] < 1 or sample["seconds"] <= 0:
                            raise ValueError("invalid timing sample")
                        expected_size = len(payload) if operation == "decompress" else fixture.stat().st_size
                        if sample["output_bytes"] != expected_size:
                            raise ValueError("timed output size differs from validated fixture")
                        sample.update({"corpus": name, "mode": mode, "format": fmt, "level": level,
                                       "operation": operation, "producer": producer,
                                       "implementation": impl, "round": round_index,
                                       "input_bytes": len(payload), "fixture_bytes": fixture.stat().st_size})
                        raw.write(json.dumps(sample, sort_keys=True) + "\n")
                        raw.flush()
                        samples.append(sample)
            print(f"[{number}/{len(configs)}] {name} {mode} {fmt} L{level} "
                  f"({time.monotonic() - started:.1f}s)", flush=True)
    current_hashes = {str(p.relative_to(ROOT)): digest(p.read_bytes()) for p in sorted(source_files)}
    if current_hashes != metadata["source_sha256"]:
        raise RuntimeError("source changed during benchmark; results are incomplete")
    metadata["elapsed_seconds"] = time.monotonic() - started
    write_json(directory / "metadata.json", metadata)
    write_json(directory / "fixtures.json", fixtures)
    report(directory, samples, metadata)
    print(f"Report: {directory / 'report.md'}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        sys.exit(str(error))
