# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Real child-process pause/resume/cancel and admission-wait regression."""
import fcntl
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

ENGINE = Path(__file__).resolve().parents[1] / 'Sources/ColdArchive/Resources/Engine'


def count(root, waiters=False):
    folder = root / 'waiters' if waiters else root
    if not folder.exists(): return 0
    gate = os.open(root / 'admission', os.O_CREAT | os.O_RDWR, 0o600)
    result = 0
    try:
        fcntl.flock(gate, fcntl.LOCK_EX)
        for path in folder.iterdir():
            if not waiters and not path.name.isdecimal(): continue
            fd = os.open(path, os.O_RDWR)
            try:
                try: fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError: result += 1
            finally: os.close(fd)
    finally: os.close(gate)
    return result


def wait_for(predicate):
    end = time.monotonic() + 5
    while time.monotonic() < end:
        if predicate(): return
        time.sleep(.01)
    raise AssertionError('Timed out waiting for real permit state')


with tempfile.TemporaryDirectory() as folder:
    root = Path(folder)
    budget = root / 'budget'; budget.mkdir()
    reads = budget / 'reading'; reads.mkdir()
    for pool in [budget, reads]:
        for i in range(64): (pool / str(i)).touch(mode=0o600)
        (pool / 'limit').write_text('1')
    pause, proceed = root / 'pause', root / 'proceed'
    env = dict(os.environ, PYTHONPATH=str(ENGINE), COLD_ARCHIVE_WRITE_BUDGET=str(budget), COLD_ARCHIVE_PAUSE_FILE=str(pause), PROCEED=str(proceed))
    code = """import os,time
import write_budget,desktop_bridge
with write_budget.reading('fixture'):
    with write_budget.writing():
        print('HELD',flush=True)
        while not os.path.exists(os.environ['PROCEED']): time.sleep(.01)
        desktop_bridge.checkpoint()
        print('RESUMED',flush=True)
"""
    for cancel in [False, True]:
        proceed.unlink(missing_ok=True)
        child = subprocess.Popen([sys.executable, '-B', '-c', code], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            assert child.stdout.readline().strip() == 'HELD'
            pause.touch(); proceed.touch()
            wait_for(lambda: count(budget) == 0 and count(reads) == 0)
            assert count(budget, True) == count(reads, True) == 0
            peer = subprocess.run([sys.executable, '-B', '-c', "import write_budget\nwith write_budget.reading('peer'),write_budget.writing(): print('PEER')"], env=env, capture_output=True, text=True, timeout=3)
            assert peer.returncode == 0 and 'PEER' in peer.stdout, peer.stderr
            if cancel:
                child.send_signal(signal.SIGTERM)
                out, err = child.communicate(timeout=5)
                assert child.returncode == 130, (child.returncode, out, err)
            else:
                pause.unlink()
                out, err = child.communicate(timeout=5)
                assert child.returncode == 0 and 'RESUMED' in out, (out, err)
            assert count(budget) == count(reads) == 0
        finally:
            pause.unlink(missing_ok=True)
            if child.poll() is None: child.kill(); child.wait()
    # Pause after reserving a read slot but while waiting for a target writer.
    sys.path.insert(0, str(ENGINE))
    import write_budget
    os.environ['COLD_ARCHIVE_WRITE_BUDGET'] = str(budget)
    waiting_code = """import write_budget,desktop_bridge
with write_budget.reading('fixture'):
    print('READ_HELD',flush=True)
    with write_budget.writing(): print('DONE',flush=True)
"""
    with write_budget.writing():
        child = subprocess.Popen([sys.executable, '-B', '-c', waiting_code], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        assert child.stdout.readline().strip() == 'READ_HELD'
        wait_for(lambda: count(budget, True) == 1)
        pause.touch()
        wait_for(lambda: count(reads) == 0 and count(budget, True) == 0)
        pause.unlink()
    out, err = child.communicate(timeout=5)
    assert child.returncode == 0 and 'DONE' in out, (out, err)
    assert count(budget) == count(reads) == 0
print('PASS: paused holders release read/write permits; peer proceeds; resume reacquires; cancel cleans up; paused waiters are not demand')
