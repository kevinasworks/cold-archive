# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
from test_answer_fixture import fixture_args
"""Exercise native file selections and directory regression in a local workspace."""
from pathlib import Path
import hashlib
import subprocess
import sys
import tempfile

HELPER = Path(__file__).with_name("create_archive_bundle.py")

def main():
    with tempfile.TemporaryDirectory(prefix="archive-file-inputs-") as temp:
        root = Path(temp)
        source = root / "source"
        source.mkdir()
        (source / "sub").mkdir()
        for name in ["a.csv", "sub/a.csv", "x*.txt", "xyz.txt", "@名字.txt", "-file.txt"]:
            (source / name).write_text(name + "\n", encoding="utf-8")
        output = root / "output"
        output.mkdir()
        original = {str(p): hashlib.sha512(p.read_bytes()).hexdigest() for p in source.rglob("*") if p.is_file()}
        def run(name, paths, success=True):
            result = subprocess.run([sys.executable, "-B", str(HELPER), *map(str, paths), *fixture_args(paths), "--archive-name", name, "--output-dir", str(output)], capture_output=True, text=True)
            if success:
                assert result.returncode == 0, result.stdout + result.stderr
                assert "FINAL_BUNDLE_STRUCTURE PASS" in result.stdout
                bundle = next(output.glob("*_" + name + "_归档_*"))
                import re
                for doc in [bundle / "README.md", *[d for d in (bundle / "Documents").glob("*.md") if d.name != "SHA512.md"]]:
                    text = doc.read_text()
                    zh = re.search(r"^#{1,2} 中文$", text, re.M)
                    en = re.search(r"^#{1,2} English$", text, re.M)
                    assert zh and en and zh.start() < en.start(), doc
                    if doc.name == "ARCHIVE_CONTENTS.md":
                        assert "This index was generated" not in text[zh.end():en.start()]
                compression = (bundle / "Documents/COMPRESSION_INFO.md").read_text()
                assert "Observed archive properties" in compression and "Full executed command" in compression
                if name != "directory":
                    assert "-spd" in compression and "-i!" in compression
                assert "Completion Time: not recorded" not in (bundle / "Documents/verification-log.md").read_text()
                return bundle
            assert result.returncode != 0, name
            assert not list(output.glob("*_" + name + "_归档_*")), name
        single = run("single", [source / "a.csv"])
        assert "<code>a.csv</code>" in (single / "Documents/ARCHIVE_CONTENTS.md").read_text()
        names = ["a.csv", "sub/a.csv", "x*.txt", "@名字.txt", "-file.txt"]
        multi = run("multiple", [source / name for name in names])
        index = (multi / "Documents/ARCHIVE_CONTENTS.md").read_text()
        for name in names:
            assert "<code>" + name + "</code>" in index
        assert "xyz.txt" not in index
        info = (multi / "Documents/SOURCE_INFO.md").read_text()
        for name in names:
            assert str(source / name) in info
        run("directory", [source])
        run("duplicate", [source / "a.csv", source / "a.csv"], False)
        run("mixed", [source / "a.csv", source / "sub"], False)
        link = source / "link.csv"
        link.symlink_to(source / "a.csv")
        run("symlink", [link], False)
        excluded = source / "excluded.tmp"
        excluded.write_text("excluded")
        run("excluded", [excluded], False)
        assert original == {name: hashlib.sha512(Path(name).read_bytes()).hexdigest() for name in original}
        assert not list(output.glob(".cold-archive-*"))
        print("PASS: single file, explicit files, directory, original-source preservation, rejection and cleanup")

if __name__ == "__main__":
    main()
