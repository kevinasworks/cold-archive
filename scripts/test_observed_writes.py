# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Actual byte accounting and shared read admission, disposable local files."""
import json
import os
from pathlib import Path
import sys
import tempfile

ENGINE = Path(__file__).resolve().parents[1] / 'Sources/ColdArchive/Resources/Engine'
sys.path.insert(0, str(ENGINE))
import write_budget
# Installs instrumentation only within this test process, as in the desktop child.
import desktop_bridge

with tempfile.TemporaryDirectory() as folder:
    root = Path(folder, 'budget'); root.mkdir()
    for pool, count in [(root, 64), (root / 'temporary', 5), (root / 'reading', 64)]:
        pool.mkdir(exist_ok=True)
        for i in range(count): (pool / str(i)).touch()
        (pool / 'limit').write_text('1')
    os.environ['COLD_ARCHIVE_WRITE_BUDGET'] = str(root)
    os.environ['COLD_ARCHIVE_LOCAL_TEMP_DEVICE'] = str(os.stat(folder).st_dev)
    target = Path(folder, 'target')
    text = '中文 ABC123\n'
    with write_budget.writing(target): target.write_text(text, encoding='utf-8', newline='\n')
    with write_budget.writing(target): target.write_bytes(b'\x00\x01\x02')
    rows = [json.loads(p.read_text()) for p in (root / 'observations').iterdir()]
    assert sum(r['bytes'] for r in rows) == len(text.encode()) + 3
    assert sum(r['calls'] for r in rows) == 2
    # Uninstrumented scopes cannot silently pollute the target measurements.
    target.write_text('ignored outside a target write scope')
    assert sum(json.loads(p.read_text())['calls'] for p in (root / 'observations').iterdir()) == 2
    spool = Path(folder, 'spool')
    with spool.open('wb') as stream: write_budget.write(stream, b'abcdef')
    temporary = [json.loads(p.read_text()) for p in (root / 'temporary' / 'observations').iterdir()]
    assert sum(r['bytes'] for r in temporary) == 6
    assert sum(json.loads(p.read_text())['bytes'] for p in (root / 'observations').iterdir()) == len(text.encode()) + 3
    with write_budget.reading(target):
        with write_budget.reading(target): pass
    # Verify the actual SHA-512 implementation can use both new shared pools.
    import hashlib
    assert desktop_bridge.cancellable_sha512(target) == hashlib.sha512(target.read_bytes()).hexdigest()
    assert not list((root / 'reading' / 'waiters').iterdir())
    # Cancellation after a real read must retain its final partial metric and
    # release the admission lease, without emitting source path/content.
    original_checkpoint = desktop_bridge.checkpoint
    original_emit = desktop_bridge.original_print
    original_chunk = desktop_bridge.engine.CHUNK_SIZE
    emitted = []
    checkpoints = [0]
    def cancel_after_first_read():
        checkpoints[0] += 1
        if checkpoints[0] == 3:
            raise SystemExit(130)
    try:
        desktop_bridge.checkpoint = cancel_after_first_read
        desktop_bridge.original_print = lambda line, **kwargs: emitted.append(line)
        desktop_bridge.engine.CHUNK_SIZE = 4
        try:
            desktop_bridge.cancellable_sha512(target)
            raise AssertionError('Expected cooperative cancellation')
        except SystemExit as error:
            assert error.code == 130
    finally:
        desktop_bridge.checkpoint = original_checkpoint
        desktop_bridge.original_print = original_emit
        desktop_bridge.engine.CHUNK_SIZE = original_chunk
    readings = [json.loads(line[10:]) for line in emitted if line.startswith('IO_SAMPLE ')]
    assert sum(row.get('bytes_read', 0) for row in readings) == 4, readings
    assert all(str(target) not in line for line in emitted)
    assert not list((root / 'reading' / 'waiters').iterdir())
    with write_budget.reading(target):
        pass
print('PASS: exact UTF-8/binary write counts, temporary isolation, unscoped writes excluded, read nesting and SHA-512')

# A metrics filesystem failure cannot make a successful data write fail.
with tempfile.TemporaryDirectory() as folder:
    root = Path(folder, 'budget'); root.mkdir()
    for i in range(64): (root / str(i)).touch()
    (root / 'limit').write_text('1')
    (root / 'observations').write_text('blocks only the metrics directory')
    os.environ['COLD_ARCHIVE_WRITE_BUDGET'] = str(root)
    target = Path(folder, 'actual-data')
    with write_budget.writing(target): target.write_bytes(b'first')
    assert target.read_bytes() == b'first'
    (root / 'observations').unlink()
    with write_budget.writing(target): target.write_bytes(b'second')
    rows = [json.loads(p.read_text()) for p in (root / 'observations').iterdir()]
    assert sum(row['bytes'] for row in rows) == 11
    assert all(row['valid'] is False for row in rows)
print('PASS: measurement failure preserves successful data writes and invalidates recovered measurements')
