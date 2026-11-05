# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Live permit changes: wake waiters and drain high-numbered holders safely."""
import fcntl
import os
from pathlib import Path
import sys
import tempfile
import threading

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/ColdArchive/Resources/Engine'))
import write_budget

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    os.environ['COLD_ARCHIVE_WRITE_BUDGET'] = directory
    for i in range(64): (root / str(i)).touch()
    def limit(value):
        (root / 'next-limit').write_text(str(value))
        os.replace(root / 'next-limit', root / 'limit')
    def hold(slot):
        fd = os.open(root / str(slot), os.O_RDWR)
        fcntl.flock(fd, fcntl.LOCK_EX)
        return fd
    def contender(entered, release):
        with write_budget.writing():
            entered.set()
            assert release.wait(5)

    limit(1)
    first = hold(0)
    entered, release = threading.Event(), threading.Event()
    thread = threading.Thread(target=contender, args=(entered, release))
    thread.start()
    assert not entered.wait(.15)
    limit(2)
    assert entered.wait(2), 'waiting writer did not observe increased target'
    release.set(); thread.join(3); os.close(first)
    assert not thread.is_alive()

    # A low-numbered slot is free, but a high-numbered writer is still active.
    # Lowering to one must not admit a second writer through slot zero.
    high = hold(12)
    limit(1)
    entered, release = threading.Event(), threading.Event()
    thread = threading.Thread(target=contender, args=(entered, release))
    thread.start()
    assert not entered.wait(.2), 'reduction refilled while high slot remained active'
    os.close(high)
    assert entered.wait(2)
    release.set(); thread.join(3)
    assert not thread.is_alive()
print('PASS: live increase wakes waiter; decrease drains all occupied slots without cancellation')
