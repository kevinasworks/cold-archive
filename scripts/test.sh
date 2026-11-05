#!/bin/bash
# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export PYTHONDONTWRITEBYTECODE=1
if [[ -x "$PWD/vendor/runtime/bin/python3" ]]; then
    export COLDARCHIVE_RUNTIME="$PWD/vendor/runtime"
    export PATH="$COLDARCHIVE_RUNTIME/bin:$PATH"
fi
swift test --disable-sandbox
ENGINE="Sources/ColdArchive/Resources/Engine"
for test in test_provenance_answers.py test_file_inputs.py test_system_exclusions.py test_output_directory.py test_smb_recovery_stability.py; do
    python3 -B "$ENGINE/$test"
done
python3 -B "$ENGINE/test_compatibility_workspace.py" --source-dir "$PWD/QA/Fixture" --verify-failure-cleanup
python3 -B scripts/test_desktop_bridge.py

python3 -B scripts/test_full_metadata.py

python3 -B scripts/test_metadata_candidates.py

python3 -B scripts/test_failure_scenarios.py

python3 -B scripts/test_media_metadata.py

# Cross-process scheduler and exact-observation regressions.
for test in test_write_budget.py test_dynamic_write_budget.py test_split_write_budget.py test_domain_budget.py test_pause_budget.py test_io_observation.py test_observed_writes.py test_budgeted_archive.py; do
    python3 -B "scripts/$test"
done
