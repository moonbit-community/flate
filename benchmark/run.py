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
    paths = sorted((ROOT / "flate").glob("*.mbt")) + sorted((ROOT / "flate" / "inspect").glob("*.mbt"))
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


def configurations(manifest, profile, include_oneshot=False):
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
        if wrappers and include_oneshot:
            for fmt in ("raw", "zlib", "gzip"):
                configs.append((corpus, "oneshot", fmt, 6))
    return configs


def runner_args(binary, implementation, operation, mode, fmt, level, source, fixture, ms,
                capacity=0):
    prefix = [binary, "--sample"] if implementation == "libdeflate" else [binary]
    return prefix + [operation, mode, fmt, str(level), source, fixture, str(ms), str(capacity)]


def replay_corpora(manifest_path, directory):
    """Copy a saved corpus after verifying its bytes; never regenerate it."""
    manifest = json.loads(manifest_path.read_text())
    names = set()
    for row in manifest:
        name = row["name"]
        if not name or Path(name).name != name or name in {".", ".."} or name in names:
            raise ValueError("invalid or duplicate corpus name")
        names.add(name)
        payload = (manifest_path.parent / row["file"]).read_bytes()
        if len(payload) != row["bytes"] or digest(payload) != row["sha256"]:
            raise ValueError(f"corpus hash/size mismatch: {name}")
        target = directory / (name + ".bin")
        target.write_bytes(payload)
        row["file"] = str(target.relative_to(directory.parent))
    if not manifest:
        raise ValueError("empty corpus manifest")
    return manifest


def paired_ratios(samples):
    """Pair by round and exact fixture, not by independent throughput medians."""
    fields = ("corpus", "mode", "format", "level", "operation", "producer")
    groups = {}
    for sample in samples:
        key = tuple(sample[f] for f in fields)
        pair = groups.setdefault(key, {}).setdefault(sample["round"], {})
        impl = sample["implementation"]
        if impl in pair:
            raise ValueError("duplicate implementation in paired round")
        pair[impl] = sample
    result = {}
    for key, rounds in groups.items():
        ratios = []
        for pair in rounds.values():
            if set(pair) != {"flate", "libdeflate"}:
                raise ValueError("incomplete paired round")
            m, c = pair["flate"], pair["libdeflate"]
            for field in ("input_sha256", "output_capacity"):
                if m[field] != c[field] and (field != "output_capacity" or key[1] == "direct"):
                    raise ValueError(f"paired {field} mismatch")
            if key[4] == "decompress" and m["fixture_sha256"] != c["fixture_sha256"]:
                raise ValueError("paired decode fixture mismatch")
            ratios.append((m["seconds"] / m["iterations"]) / (c["seconds"] / c["iterations"]))
        result[key] = {"median": statistics.median(ratios), "min": min(ratios),
                       "max": max(ratios), "rounds": len(ratios)}
    return result


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
    ratios = paired_ratios(samples)
    fields = ("corpus", "mode", "format", "level", "operation", "producer")
    write_json(directory / "comparisons.json", [dict(zip(fields, key), **value)
               for key, value in ratios.items() if key[1] == "direct"])
    write_json(directory / "summary.json", summary)
    lines = ["# Paired native benchmark", "",
             f"Profile: `{metadata['profile']}`. Started: {metadata['started_utc']}.",
             f"flate: `{metadata['revision']}`; libdeflate: `{metadata['libdeflate_version']}`.",
             f"Minimum batch: {metadata['milliseconds']} ms; rounds: {metadata['rounds']}.", "",
             "Each rate uses the median seconds/operation. Spread is (max-min)/median.",
             "A spread above 10% is marked `NOISY`; rerun before drawing conclusions.",
             "Compression rows compare the same level, not equal compressed size.",
             "Decode rows always use the same exact fixture for both implementations.",
             "Direct: reused codecs; equal preallocated output capacities. Both decoders receive N bytes.",
             "Direct compression capacity is the maximum of both codec bounds, computed outside timing.",
             "Speed ratios are median paired per-round flate time / libdeflate time; range is min..max.",
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
        if not any(key[0] == mode for key in index):
            continue
        lines += [f"## {mode}", "",
                  "| Format / corpus | L | Operation / fixture | flate MiB/s | C MiB/s | C / flate speed (paired range) | Compressed bytes (flate / C, or shared fixture) | Spread flate / C |",
                  "| --- | ---: | --- | ---: | ---: | ---: | ---: | --- |"]
        for key, pair in index.items():
            if key[0] != mode or set(pair) != {"flate", "libdeflate"}:
                continue
            m, c = pair["flate"], pair["libdeflate"]
            ratio = ratios[tuple(m[f] for f in fields)]
            comparable = mode == "direct" and metadata["rounds"] >= 3 and metadata["profile"] != "smoke"
            noisy = " NOISY" if max(m["spread_pct"], c["spread_pct"]) > 10 else ""
            multiplier = (f"{ratio['median']:.2f}x ({ratio['min']:.2f}..{ratio['max']:.2f})"
                          if comparable and not noisy else "n/a")
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
    parser.add_argument("--include-oneshot", action="store_true",
                        help="also measure allocation-inclusive, nonparity application APIs")
    parser.add_argument("--corpus-manifest", type=Path,
                        help="replay exact inputs from an existing corpus.json (verify hashes)")
    parser.add_argument("--validate-only", action="store_true",
                        help="build and cross-validate once, without warmup, calibration, or timing")
    args = parser.parse_args()
    defaults = {"smoke": (1, 2), "quick": (7, 150), "full": (7, 150)}
    rounds = args.rounds if args.rounds is not None else defaults[args.profile][0]
    ms = args.milliseconds if args.milliseconds is not None else defaults[args.profile][1]
    if rounds < 1 or ms < 1:
        parser.error("rounds and milliseconds must be positive")
    if args.corpus_manifest and args.corpus:
        parser.error("--corpus-manifest cannot be combined with --corpus")
    if args.validate_only:
        rounds, ms = 1, 0
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
    build_moon = ["moon", "-C", str(ROOT / "benchmark"), "build", "--release",
                  "--target", "native", "--verbose",
                  "--target-dir", directory / "build", "runner"]
    print(f"Building runners; results: {directory}", flush=True)
    (directory / "build-moon-commands.log").write_text(command(build_moon + ["--dry-run"]) + "\n")
    for name, cmd in (("c", build_c), ("moon", build_moon)):
        result = subprocess.run([str(v) for v in cmd], cwd=ROOT, text=True,
                                capture_output=True, timeout=180)
        (directory / f"build-{name}.log").write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"build failed; see {directory / ('build-' + name + '.log')}")
    candidates = list((directory / "build").glob(
        "native/release/build/moonbit-community/flate-benchmark/runner/*.exe"))
    if len(candidates) != 1:
        raise RuntimeError(f"expected one MoonBit executable, got {candidates}")
    binaries = {"flate": candidates[0], "libdeflate": c_binary}
    metadata = {"schema": 2, "profile": args.profile, "started_utc": stamp,
                "validate_only": args.validate_only, "include_oneshot": args.include_oneshot,
                "corpus_manifest": str(args.corpus_manifest.resolve()) if args.corpus_manifest else None,
                "direct_policy": {"decode_capacity": "exact uncompressed size for both",
                                  "compress_capacity": "max of both codec bounds",
                                  "workspace": "reused; per-stream reset and table building timed",
                                  "cache": "warm reused buffers"},
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
    source_files = (list((ROOT / "flate").glob("*.mbt")) + list((ROOT / "flate").glob("*.pkg"))
                    + [ROOT / "flate" / "moon.mod"])
    for package in ("benchmark", "flate/checksum", "flate/gzip", "flate/zlib"):
        source_files += [p for p in (ROOT / package).rglob("*") if p.is_file() and
                         p.suffix in {".mbt", ".pkg", ".c", ".py"}]
    metadata["source_sha256"] = {str(p.relative_to(ROOT)): digest(p.read_bytes()) for p in sorted(source_files)}
    for path in source_files:
        snapshot = directory / "source" / path.relative_to(ROOT)
        snapshot.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, snapshot)
    manifest = (replay_corpora(args.corpus_manifest.resolve(), directory / "corpus")
                if args.corpus_manifest else corpora(directory / "corpus", args.profile, args.corpus))
    write_json(directory / "corpus.json", manifest)
    write_json(directory / "metadata.json", metadata)
    configs = configurations(manifest, args.profile, args.include_oneshot)
    samples = []
    fixtures = []
    results_name = "validation.jsonl" if args.validate_only else "samples.jsonl"
    with (directory / results_name).open("w") as raw:
        for number, (corpus, mode, fmt, level) in enumerate(configs, 1):
            name = corpus["name"]
            source = directory / corpus["file"]
            payload = source.read_bytes()
            capacity = 0
            if mode == "direct":
                capacity = max(int(command(runner_args(binary, impl, "bound", mode,
                    fmt, level, source, source, 0))) for impl, binary in binaries.items())
                if not 0 < capacity <= 2147483647:
                    raise ValueError("shared compression capacity exceeds MoonBit buffer limits")
            paths = {}
            for impl, binary in binaries.items():
                fixture = directory / "fixtures" / f"{name}-{mode}-{fmt}-L{level}-{impl}.bin"
                command(runner_args(binary, impl, "export", mode, fmt, level, source, fixture, 0, capacity))
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
                        output_capacity = len(payload) if operation == "decompress" else capacity
                        sample = json.loads(command(runner_args(binaries[impl], impl, operation,
                            mode, fmt, level, source, fixture, ms, output_capacity)))
                        if args.validate_only:
                            if sample["iterations"] != 0 or sample["seconds"] != 0:
                                raise ValueError("validation unexpectedly timed work")
                        elif sample["iterations"] < 1 or sample["seconds"] <= 0:
                            raise ValueError("invalid timing sample")
                        expected_size = len(payload) if operation == "decompress" else fixture.stat().st_size
                        if sample["output_bytes"] != expected_size:
                            raise ValueError("timed output size differs from validated fixture")
                        sample.update({"corpus": name, "mode": mode, "format": fmt, "level": level,
                                       "operation": operation, "producer": producer,
                                       "implementation": impl, "round": round_index,
                                       "input_sha256": corpus["sha256"],
                                       "fixture_sha256": digest(fixture.read_bytes()),
                                       "output_capacity": output_capacity if mode == "direct" else None,
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
    if args.validate_only:
        write_json(directory / "validation.json", {"passed": True, "cases": len(samples)})
        print(f"Validation: {directory / 'validation.json'} (no timing)", flush=True)
    else:
        report(directory, samples, metadata)
        print(f"Report: {directory / 'report.md'}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        sys.exit(str(error))
