#!/usr/bin/env python3
# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""End-to-end regression for cross-platform system-entry exclusions."""

from __future__ import annotations
from test_answer_fixture import fixture_args

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path, PurePosixPath


SCRIPT = Path(__file__).with_name("create_archive_bundle.py")


def is_required_exclusion(name: str) -> bool:
    return (
        name in {".DS_Store", "Thumbs.db", "ehthumbs.db", "Desktop.ini", "lost+found"}
        or name.startswith("._")
        or name.startswith(".nfs")
        or name.startswith(".Trash-")
        or name.endswith(".tmp")
        or name.endswith(".temp")
        or name.endswith(".bak")
        or name.endswith("~")
    )


def make_fixture(source: Path) -> list[Path]:
    nested = source / "included-directory"
    nested.mkdir(parents=True)
    included = [source / "keep.txt", nested / "keep-nested.txt"]
    for index, path in enumerate(included):
        path.write_text(f"included-{index}\n", encoding="utf-8")

    excluded_files = [
        source / ".DS_Store",
        nested / ".DS_Store",
        nested / "._resource-fork",
        source / "Thumbs.db",
        source / "ehthumbs.db",
        nested / "Desktop.ini",
        source / ".nfs123456",
        source / "draft.tmp",
        nested / "cache.temp",
        source / "previous.bak",
        nested / "editor-save~",
    ]
    for index, path in enumerate(excluded_files):
        path.write_text(f"excluded-{index}\n", encoding="utf-8")

    excluded_directories = [source / ".Trash-1000", nested / "lost+found"]
    for index, directory in enumerate(excluded_directories):
        directory.mkdir()
        (directory / "must-not-be-archived.bin").write_bytes(
            f"excluded-directory-{index}\n".encode()
        )
    return [*excluded_files, *excluded_directories]


def selected_7zip() -> str:
    for command in ("7zz", "7z", "7za"):
        if path := shutil.which(command):
            return path
    raise AssertionError("No 7-Zip executable available for regression test")


def main() -> int:
    workspace = Path(tempfile.mkdtemp(prefix="cold-archive-system-exclusions-"))
    try:
        input_parent = workspace / "input"
        output_parent = workspace / "output"
        source = input_parent / "source"
        output_parent.mkdir(parents=True)
        excluded_paths = make_fixture(source)

        archive_name = "system_exclusions_regression"
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                str(source),
                *fixture_args([source]),
                "--archive-name",
                archive_name,
                "--output-dir",
                str(output_parent),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=True,
        )
        bundle_lines = [
            line.removeprefix("BUNDLE ")
            for line in result.stdout.splitlines()
            if line.startswith("BUNDLE ")
        ]
        if len(bundle_lines) != 1:
            raise AssertionError(f"Expected one BUNDLE line, got {bundle_lines!r}")
        bundle = Path(bundle_lines[0])
        archive = bundle / f"{archive_name}.7z"

        listing = subprocess.run(
            [selected_7zip(), "l", "-slt", str(archive)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=True,
        ).stdout
        archived_paths = [
            line.removeprefix("Path = ")
            for line in listing.splitlines()
            if line.startswith("Path = source")
        ]
        leaked = sorted(
            path
            for path in archived_paths
            if any(is_required_exclusion(part) for part in PurePosixPath(path).parts)
        )
        if leaked:
            raise AssertionError(f"Excluded entries leaked into archive: {leaked!r}")

        manifest = (bundle / "Documents" / "SHA512.md").read_text(encoding="utf-8")
        if "- File Count: 2" not in manifest:
            raise AssertionError("Excluded entries affected SHA-512 manifest count")
        if ".DS_Store" in manifest or "Thumbs.db" in manifest:
            raise AssertionError("Excluded system entry appears in SHA-512 manifest")
        if "keep.txt" not in manifest or "keep-nested.txt" not in manifest:
            raise AssertionError("Included files are missing from SHA-512 manifest")

        archive_info = (bundle / "Documents" / "archive-info.md").read_text(
            encoding="utf-8"
        )
        expected_excluded_count = f"Excluded Source Entries: {len(excluded_paths)}"
        if expected_excluded_count not in archive_info:
            raise AssertionError(
                f"Expected {expected_excluded_count!r} in archive information"
            )
        missing_source_entries = [path for path in excluded_paths if not path.exists()]
        if missing_source_entries:
            raise AssertionError(
                f"Source exclusions were modified or deleted: {missing_source_entries!r}"
            )

        required_passes = (
            "ARCHIVE_TEST PASS",
            "EXTRACTION_VERIFICATION PASS",
            "SOURCE_DATA_VERIFICATION PASS",
            "ARCHIVE_SHA512 PASS",
            "FINAL_BUNDLE_STRUCTURE PASS",
        )
        missing_passes = [item for item in required_passes if item not in result.stdout]
        if missing_passes:
            raise AssertionError(f"Missing end-to-end passes: {missing_passes!r}")

        print("DS_STORE_EXCLUDED_FROM_SHA512 PASS")
        print("DS_STORE_EXCLUDED_FROM_7Z PASS")
        print("CROSS_PLATFORM_EXCLUSIONS_RECURSIVE PASS")
        print("SOURCE_EXCLUSIONS_PRESERVED PASS")
        print("RECOVERY_AND_DIRECTORY_COMPARISON PASS")
        print("SYSTEM_EXCLUSIONS_REGRESSION PASS")
        return 0
    finally:
        shutil.rmtree(workspace)
        if workspace.exists():
            raise AssertionError(f"Regression workspace cleanup failed: {workspace}")


if __name__ == "__main__":
    raise SystemExit(main())
