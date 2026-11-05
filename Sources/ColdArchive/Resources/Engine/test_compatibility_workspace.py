#!/usr/bin/env python3
# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Regression-check the local filename-compatibility workspace policy."""

from __future__ import annotations

import argparse
import importlib.util
from pathlib import Path
import sys


def load_archive_helper():
    helper_path = Path(__file__).with_name("create_archive_bundle.py")
    spec = importlib.util.spec_from_file_location(
        "sha512_7z_archive_compatibility_regression", helper_path
    )
    if spec is None or spec.loader is None:
        raise SystemExit(f"Cannot load archive helper: {helper_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def compatibility_directories(parent: Path) -> set[Path]:
    return set(parent.glob(".cold-archive-compatibility-*"))


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Verify that filename compatibility fixtures use a local temporary "
            "directory and never write beside the supplied source directory."
        )
    )
    parser.add_argument("--source-dir", required=True, type=Path)
    parser.add_argument("--seven-zip")
    parser.add_argument("--verify-failure-cleanup", action="store_true")
    args = parser.parse_args()

    source = args.source_dir.expanduser().resolve()
    if not source.is_dir():
        raise SystemExit(f"Source context is not a directory: {source}")

    helper = load_archive_helper()
    source_filesystem = helper.filesystem_type(source)
    source_parent = source.parent
    local_parent, local_filesystem = helper.local_compatibility_temp_parent()
    if helper.is_network_filesystem(local_filesystem):
        raise SystemExit(
            f"Selected compatibility workspace is not local: {local_parent} "
            f"({local_filesystem})"
        )

    source_before = compatibility_directories(source_parent)
    local_before = compatibility_directories(local_parent)
    available = helper.detect_7zip()
    seven_zip, version = helper.select_7zip(args.seven_zip, available)
    result = helper.run_filename_compatibility_test(seven_zip)

    if Path(result.location).parent != local_parent:
        raise SystemExit(
            f"Compatibility workspace used unexpected parent: {result.location}"
        )
    if Path(result.location).exists():
        raise SystemExit(f"Compatibility workspace remains after success: {result.location}")
    if compatibility_directories(source_parent) != source_before:
        raise SystemExit(
            f"Compatibility test created an entry beside the source: {source_parent}"
        )
    if compatibility_directories(local_parent) != local_before:
        raise SystemExit(
            f"Compatibility workspace cleanup left an entry in: {local_parent}"
        )

    if args.verify_failure_cleanup:
        try:
            helper.run_filename_compatibility_test(
                "/definitely/missing/7zz-for-cleanup-regression"
            )
        except OSError:
            pass
        else:
            raise SystemExit("Forced compatibility-test failure unexpectedly succeeded.")
        if compatibility_directories(source_parent) != source_before:
            raise SystemExit(
                "Forced failure created a compatibility entry beside the source."
            )
        if compatibility_directories(local_parent) != local_before:
            raise SystemExit(
                "Forced failure left a local compatibility workspace behind."
            )
        print("FAILURE_CLEANUP_REGRESSION PASS", flush=True)

    print(f"SOURCE_CONTEXT {source}", flush=True)
    print(f"SOURCE_FILESYSTEM {source_filesystem}", flush=True)
    print(f"SELECTED_7ZIP {version} ({seven_zip})", flush=True)
    print(f"LOCAL_TEMPORARY_PARENT {local_parent}", flush=True)
    print(f"LOCAL_TEMPORARY_FILESYSTEM {local_filesystem}", flush=True)
    print("SOURCE_PARENT_COMPATIBILITY_WRITES 0", flush=True)
    print("COMPATIBILITY_WORKSPACE_REGRESSION PASS", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
