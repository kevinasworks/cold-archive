#!/usr/bin/env python3
# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Regression tests for bounded smbfs recovery-hash stability retries."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
from unittest.mock import patch


def load_archive_helper():
    helper_path = Path(__file__).with_name("create_archive_bundle.py")
    spec = importlib.util.spec_from_file_location(
        "sha512_7z_archive_smb_recovery_regression", helper_path
    )
    if spec is None or spec.loader is None:
        raise SystemExit(f"Cannot load archive helper: {helper_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def main() -> int:
    helper = load_archive_helper()
    root = Path("/synthetic/recovery")
    successful_scan = ({}, set(), {})
    transient = SystemExit("File changed while hashing: /synthetic/recovery/file")

    with (
        patch.object(helper, "scan_hashes", side_effect=[transient, successful_scan]) as scan,
        patch.object(helper.time, "sleep") as sleep,
    ):
        result = helper.scan_recovered_hashes_with_smb_stability(root, "smbfs")
        assert result.attempts == 2
        assert result.mode == "bounded smbfs retry"
        assert scan.call_count == 2
        sleep.assert_called_once_with(helper.SMB_RECOVERY_STABILITY_DELAY_SECONDS)
    print("SMB_TRANSIENT_RETRY PASS", flush=True)

    with (
        patch.object(helper, "scan_hashes", return_value=successful_scan) as scan,
        patch.object(helper.time, "sleep") as sleep,
    ):
        result = helper.scan_recovered_hashes_with_smb_stability(root, "apfs")
        assert result.attempts == 1
        assert result.mode == "not required"
        scan.assert_called_once_with(root)
        sleep.assert_not_called()
    print("NON_SMB_NO_RETRY PASS", flush=True)

    non_transient = SystemExit("Unsupported source entry (special file): synthetic")
    with (
        patch.object(helper, "scan_hashes", side_effect=non_transient) as scan,
        patch.object(helper.time, "sleep") as sleep,
    ):
        try:
            helper.scan_recovered_hashes_with_smb_stability(root, "smbfs")
        except SystemExit as error:
            assert str(error) == str(non_transient)
        else:
            raise AssertionError("Non-transient recovery failure was suppressed.")
        assert scan.call_count == 1
        sleep.assert_not_called()
    print("NON_TRANSIENT_FAILURE_NOT_RETRIED PASS", flush=True)

    failures = [
        SystemExit(f"File changed while hashing: /synthetic/recovery/file-{index}")
        for index in range(helper.SMB_RECOVERY_STABILITY_MAX_ATTEMPTS)
    ]
    with (
        patch.object(helper, "scan_hashes", side_effect=failures) as scan,
        patch.object(helper.time, "sleep") as sleep,
    ):
        try:
            helper.scan_recovered_hashes_with_smb_stability(root, "smbfs")
        except SystemExit as error:
            assert str(error) == str(failures[-1])
        else:
            raise AssertionError("Retry limit did not preserve the final failure.")
        assert scan.call_count == helper.SMB_RECOVERY_STABILITY_MAX_ATTEMPTS
        assert sleep.call_count == helper.SMB_RECOVERY_STABILITY_MAX_ATTEMPTS - 1
    print("SMB_RETRY_LIMIT_ENFORCED PASS", flush=True)
    print("SMB_RECOVERY_STABILITY_REGRESSION PASS", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
