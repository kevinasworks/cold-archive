# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Two real, fully verified archives competing through the desktop permit pools."""
import concurrent.futures
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ENGINE = Path(__file__).resolve().parents[1] / 'Sources/ColdArchive/Resources/Engine'
sys.path.insert(0, str(ENGINE))
from test_answer_fixture import fixture_args


def occupied(root):
    count = 0
    gate = os.open(root / 'admission', os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(gate, fcntl.LOCK_EX)
        for path in root.iterdir():
            if not path.name.isdecimal(): continue
            fd = os.open(path, os.O_RDWR)
            try:
                try: fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError: count += 1
            finally: os.close(fd)
    finally: os.close(gate)
    return count


with tempfile.TemporaryDirectory(prefix='coldarchive-shared-archive-') as folder:
    root = Path(folder)
    budget = root / 'budget'; budget.mkdir()
    for pool, slots, limit in [(budget, 64, 1), (budget / 'reading', 64, 2), (budget / 'temporary', 5, 5)]:
        pool.mkdir(exist_ok=True)
        for i in range(slots): (pool / str(i)).touch(mode=0o600)
        (pool / 'limit').write_text(str(limit))
    env = dict(os.environ, COLD_ARCHIVE_WRITE_BUDGET=str(budget), COLD_ARCHIVE_LOCAL_TEMP_DEVICE=str(root.stat().st_dev))
    processes = []
    originals = []
    for i in range(2):
        source = root / f'source-{i}'; source.mkdir()
        payload = source / '中文.bin'; payload.write_bytes(os.urandom(2 * 1024 * 1024))
        originals.append((payload, hashlib.sha512(payload.read_bytes()).hexdigest()))
        output = root / f'output-{i}'; output.mkdir()
        command = [sys.executable, '-B', '-u', str(ENGINE / 'desktop_bridge.py'), str(source), '--archive-name', f'fixture-{i}', '--output-dir', str(output), '--require-source-confirmation', *fixture_args([source])]
        processes.append(subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True))
    peak_write = peak_read = 0
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as workers:
            futures = [workers.submit(p.communicate, timeout=90) for p in processes]
            while not all(f.done() for f in futures):
                peak_write = max(peak_write, occupied(budget))
                peak_read = max(peak_read, occupied(budget / 'reading'))
                assert peak_write <= 1 and peak_read <= 2, (peak_write, peak_read)
                time.sleep(.005)
            for process, future in zip(processes, futures):
                text, _ = future.result()
                assert process.returncode == 0, text[-10000:]
                line = next(line for line in text.splitlines() if line.startswith('DESKTOP_RESULT '))
                result = json.loads(line.removeprefix('DESKTOP_RESULT '))
                assert result['state'] == 'completed' and Path(result['bundle']).is_dir()
        assert peak_write == 1 and peak_read > 0
        assert all(hashlib.sha512(path.read_bytes()).hexdigest() == digest for path, digest in originals)
        rows = [json.loads(p.read_text()) for p in (budget / 'observations').iterdir() if not p.name.endswith('.tmp')]
        assert len(rows) == 2 and sum(r['bytes'] for r in rows) > 0
        print(f'PASS: two complete archives and all engine verification gates; write peak {peak_write}, read peak {peak_read}; source hashes unchanged; logical write records {len(rows)}')
    finally:
        for p in processes:
            if p.poll() is None: p.terminate()
