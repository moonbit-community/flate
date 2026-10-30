"""Smoke-test the built CLI with an independent ZIP reader."""
import pathlib
import subprocess
import tempfile
import zipfile

repo = pathlib.Path(__file__).resolve().parent.parent
exe = repo / "cli/_build/native/release/build/flate-cli.exe"
with tempfile.TemporaryDirectory(prefix="flate-cli-smoke-") as directory:
    root = pathlib.Path(directory)
    (root / "tree/empty").mkdir(parents=True)
    files = {
        "tree/hello😀.txt": b"hello " * 1000,
        "tree/.hidden": b"hidden contents",
        "tree/image.PNG": b"already compressed extension",
    }
    for name, contents in files.items():
        (root / name).write_bytes(contents)
    subprocess.run([str(exe), "--level", "9", "tree", "result.zip"], cwd=root, check=True)
    with zipfile.ZipFile(root / "result.zip") as archive:
        assert set(archive.namelist()) == set(files) | {"tree/", "tree/empty/"}
        for name, contents in files.items():
            assert archive.read(name) == contents
        assert archive.getinfo("tree/image.PNG").compress_type == zipfile.ZIP_STORED
        assert archive.getinfo("tree/hello😀.txt").compress_type == zipfile.ZIP_DEFLATED
    original = (root / "result.zip").read_bytes()
    existing = subprocess.run([str(exe), "tree", "result.zip"], cwd=root)
    assert existing.returncode != 0
    assert (root / "result.zip").read_bytes() == original
    invalid = subprocess.run([str(exe), "--level", "10", "tree", "invalid.zip"], cwd=root)
    assert invalid.returncode != 0
    assert not (root / "invalid.zip").exists()
print("CLI ZIP smoke test passed")
