# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Real process contention, crash release, and dual-pipe capture regression."""
import importlib.util
import multiprocessing as mp
import os
from pathlib import Path
import sys
import tempfile
import time

ENGINE = Path(__file__).resolve().parents[1] / 'Sources/ColdArchive/Resources/Engine'
sys.path.insert(0, str(ENGINE))
import write_budget

def worker(root, active, peak, guard):
    os.environ['COLD_ARCHIVE_WRITE_BUDGET'] = root
    for _ in range(8):
        with write_budget.writing():
            with guard:
                active.value += 1
                peak.value = max(peak.value, active.value)
            time.sleep(0.02)
            with guard: active.value -= 1

def crash(root):
    os.environ['COLD_ARCHIVE_WRITE_BUDGET'] = root
    with write_budget.writing(): os._exit(7)

if __name__ == '__main__':
    with tempfile.TemporaryDirectory() as root:
        for i in range(64): Path(root, str(i)).touch(mode=0o600)
        ctx = mp.get_context('spawn')
        active, peak, guard = ctx.Value('i', 0), ctx.Value('i', 0), ctx.Lock()
        Path(root, "limit").write_text("1")
        jobs = [ctx.Process(target=worker, args=(root, active, peak, guard)) for _ in range(10)]
        for job in jobs: job.start()
        for job in jobs:
            job.join(15)
            assert not job.is_alive() and job.exitcode == 0
        assert peak.value == 1 and active.value == 0, (peak.value, active.value)
        Path(root, "limit").write_text("5")
        peak.value = 0
        jobs = [ctx.Process(target=worker, args=(root, active, peak, guard)) for _ in range(10)]
        for job in jobs: job.start()
        for job in jobs:
            job.join(15)
            assert not job.is_alive() and job.exitcode == 0
        assert peak.value == 5 and active.value == 0
        Path(root, "limit").write_text("1")
        dead = ctx.Process(target=crash, args=(root,)); dead.start(); dead.join(5)
        assert dead.exitcode == 7
        os.environ['COLD_ARCHIVE_WRITE_BUDGET'] = root
        with write_budget.writing():
            with write_budget.writing(): pass
        import inspect_source_metadata as reader
        data, diagnostics, code = reader.run_json([sys.executable, '-c', 'import sys,json;sys.stderr.write("e"*200000);print(json.dumps({"payload":"x"*200000}))'])
        assert code == 0 and len(data['payload']) == 200000 and len(diagnostics) == 200000
        print('PASS: 10 processes, configured peaks 1 and 5; nested writes reuse permit; crash releases permit; dual-pipe output complete')
