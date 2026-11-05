#!/usr/bin/env python3
# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Regression test for explicit and default cold-archive output placement."""

from __future__ import annotations
from test_answer_fixture import fixture_args

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


SCRIPT = Path(__file__).with_name("create_archive_bundle.py")
DOCUMENT_NAMES = {
    "ARCHIVE_FORMAT.md",
    "COMPRESSION_INFO.md",
    "SHA512.md",
    "archive-info.md",
    "verification-log.md",
    "ARCHIVE_CONTENTS.md",
    "SOURCE_INFO.md",
    "STATISTICS.md",
}


def run_archive(source: Path, archive_name: str, output_dir: Path | None) -> Path:
    command = [
        sys.executable,
        str(SCRIPT),
        str(source),
        *fixture_args([source]),
        "--archive-name",
        archive_name,
    ]
    if output_dir is not None:
        command.extend(("--output-dir", str(output_dir)))
    result = subprocess.run(
        command,
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
    return Path(bundle_lines[0]).resolve()


def verify_bundle(bundle: Path, archive_name: str, output_dir: Path) -> None:
    archive_filename = f"{archive_name}.7z"
    checksum_filename = f"{archive_filename}.sha512.md"
    expected_root = {
        "README.md",
        archive_filename,
        checksum_filename,
        "Documents",
    }
    actual_root = {entry.name for entry in bundle.iterdir()}
    if actual_root != expected_root:
        raise AssertionError(
            f"Unexpected bundle root: expected {expected_root!r}, got {actual_root!r}"
        )
    actual_documents = {entry.name for entry in (bundle / "Documents").iterdir()}
    if actual_documents != DOCUMENT_NAMES:
        raise AssertionError(
            "Unexpected Documents layout: "
            f"expected {DOCUMENT_NAMES!r}, got {actual_documents!r}"
        )
    archive_info = (bundle / "Documents" / "archive-info.md").read_text(
        encoding="utf-8"
    )
    expected_output = f"Output Directory: {output_dir.resolve()}"
    if expected_output not in archive_info:
        raise AssertionError(
            f"Archive information does not record {expected_output!r}"
        )


def make_source(path: Path) -> None:
    path.mkdir(parents=True)
    (path / "中文 空格 😀 & [test].txt").write_text(
        "cold archive output directory regression\n", encoding="utf-8"
    )
    (path / "empty-directory").mkdir()


def main() -> int:
    workspace = Path(tempfile.mkdtemp(prefix="cold-archive-output-dir-test-"))
    try:
        explicit_input_parent = workspace / "explicit-input"
        explicit_output = workspace / "explicit-output"
        explicit_source = explicit_input_parent / "source"
        explicit_output.mkdir()
        make_source(explicit_source)

        explicit_name = "output_dir_explicit_regression"
        explicit_bundle = run_archive(
            explicit_source, explicit_name, explicit_output
        )
        if explicit_bundle.parent != explicit_output.resolve():
            raise AssertionError(
                f"Explicit bundle parent is {explicit_bundle.parent}, "
                f"expected {explicit_output.resolve()}"
            )
        misplaced = [
            entry
            for entry in explicit_input_parent.iterdir()
            if entry.resolve() != explicit_source.resolve()
        ]
        if misplaced:
            raise AssertionError(
                f"Explicit-output archive was also created beside source: {misplaced!r}"
            )
        verify_bundle(explicit_bundle, explicit_name, explicit_output)

        default_input_parent = workspace / "default-input"
        default_source = default_input_parent / "source"
        make_source(default_source)
        default_name = "output_dir_default_regression"
        default_bundle = run_archive(default_source, default_name, None)
        if default_bundle.parent != default_input_parent.resolve():
            raise AssertionError(
                f"Default bundle parent is {default_bundle.parent}, "
                f"expected {default_input_parent.resolve()}"
            )
        verify_bundle(default_bundle, default_name, default_input_parent)

        print("EXPLICIT_OUTPUT_DIRECTORY PASS")
        print("SOURCE_PARENT_REMAINS_EMPTY_OF_FINAL_ARCHIVE PASS")
        print("DEFAULT_SOURCE_PARENT_COMPATIBILITY PASS")
        print("OUTPUT_DIRECTORY_REGRESSION PASS")
        return 0
    finally:
        shutil.rmtree(workspace)
        if workspace.exists():
            raise AssertionError(f"Regression workspace cleanup failed: {workspace}")


if __name__ == "__main__":
    raise SystemExit(main())
