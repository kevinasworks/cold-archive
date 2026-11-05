# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Bounded, content-free measurements for operations we directly perform.

Only bytes returned by read() count. This is logical I/O, not physical disk or
network traffic. No file names, paths, data, or credentials enter the records.
"""
import json
import time


class ReadObservation:
    def __init__(self, emit, clock=time.monotonic):
        self.emit, self.clock = emit, clock
        self.started = self.last = clock()
        self.count = self.calls = 0
        self.wait = self.maximum = 0.0
        self.excluded = 0.0

    def exclude_idle(self, elapsed):
        self.excluded += max(0.0, elapsed)

    def record(self, count, elapsed):
        self.count += count
        self.calls += 1
        self.wait += elapsed
        self.maximum = max(self.maximum, elapsed)
        if self.clock() - self.last >= 1:
            self.flush()

    def flush(self):
        now = self.clock()
        if self.calls:
            self.emit('IO_SAMPLE ' + json.dumps({
                'event': 'logical_io', 'stage': 'hash', 'metric_source': 'logical_bytes',
                'bytes_read': self.count, 'io_calls': self.calls,
                'io_seconds': self.wait, 'max_io_seconds': self.maximum,
                'window_seconds': max(0.0, now - self.last - self.excluded),
            }, separators=(',', ':')))
        self.last = now
        self.count = self.calls = 0
        self.wait = self.maximum = 0.0
        self.excluded = 0.0
