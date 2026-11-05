# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Content-free exact logical counters, published at most 5Hz plus safe exits."""
import hashlib
import json
import os
import sys
import threading
import time
import uuid

_lock = threading.Lock()
_identity = str(os.getpid()) + '-' + uuid.uuid4().hex
_totals = {}
_published = {}
_reported_error = False


def _publish(key, row):
    global _reported_error
    root, domain, stage = key
    try:
        folder = os.path.join(root, 'observations')
        os.makedirs(folder, mode=0o700, exist_ok=True)
        bucket = hashlib.sha256((domain + '\0' + stage).encode()).hexdigest()[:24]
        path = os.path.join(folder, _identity + '-' + bucket)
        temporary = path + '.tmp'
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try: os.write(fd, json.dumps(row, separators=(',', ':')).encode())
        finally: os.close(fd)
        os.replace(temporary, path)
        _published[key] = time.monotonic()
    except OSError:
        # Measurement failure is not a failed data write. Future observations
        # explicitly remain incomplete, and the diagnostic has no error text.
        row['valid'] = False
        if not _reported_error:
            _reported_error = True
            try:
                print('IO_SAMPLE {"event":"measurement_error","stage":"target_write","code":"write_observation_failed"}', file=sys.stderr, flush=True)
            except OSError: pass


def record(root, count, seconds, domain='unknown', stage='target_write'):
    if not root or count < 0: return
    with _lock:
        key = root, domain, stage
        row = _totals.setdefault(key, {'bytes': 0, 'calls': 0, 'seconds': 0.0, 'domain': domain, 'stage': stage, 'pid': os.getpid(), 'valid': True})
        row['bytes'] += count
        row['calls'] += 1
        row['seconds'] += max(0.0, seconds)
        if time.monotonic() - _published.get(key, 0) >= .2: _publish(key, row)


def flush(root, domain, stage):
    with _lock:
        key = root, domain, stage
        if key in _totals: _publish(key, _totals[key])
