# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Bounded local fixture: real writes plus explicit artificial I/O delay.

Sixteen reusable 2MiB files bound live disk use to 32MiB. Cumulative bytes are
actual successful writes. This fixture measures scheduling under controlled
latency, not physical disk or NAS performance.
"""
import hashlib
import fcntl
import json
import os
from pathlib import Path
import queue
import random
import sys
import threading
import time
import write_budget

root = Path(sys.argv[1])
jobs = int(sys.argv[2])
delay = float(sys.argv[3])
threads = int(sys.argv[4])
devices = int(sys.argv[5])
chunks = int(sys.argv[6]) if len(sys.argv)>6 else 32
uncached = os.environ.get("COLD_ARCHIVE_WRITE_NOCACHE") == "1"
random_data = os.environ.get("COLD_ARCHIVE_WRITE_RANDOM") == "1"
cache_failures=[]
work = queue.Queue()
for i in range(jobs): work.put(i)
completed, errors, digests = [], [], []
lock = threading.Lock()


def worker(index):
    domain = 'fixture-' + str(index % devices)
    path = root / f'writer-{index}'
    budget = os.environ['COLD_ARCHIVE_WRITE_BUDGET']
    while True:
        try: job = work.get_nowait()
        except queue.Empty: return
        payload = bytes([job % 251]) * 65536
        expected = hashlib.sha512()
        generator = random.Random(job)
        try:
            with write_budget.permit(budget, domain, 'fixture_write'):
                with path.open('wb', buffering=0) as stream:
                    if uncached:
                        try: fcntl.fcntl(stream.fileno(),48,1) # Darwin F_NOCACHE
                        except OSError: cache_failures.append(True)
                    for _ in range(chunks):
                        if random_data: payload=generator.randbytes(65536)
                        began = time.monotonic()
                        count = stream.write(payload)
                        assert count == len(payload)
                        expected.update(payload)
                        write_budget.record_write(budget, count, time.monotonic() - began)
                        time.sleep(delay)
            with write_budget.reading(path),path.open('rb',buffering=0) as stream:
                if uncached:
                    try: fcntl.fcntl(stream.fileno(),48,1)
                    except OSError: cache_failures.append(True)
                actual=hashlib.sha512()
                while True:
                    data=stream.read(1024*1024)
                    if not data: break
                    actual.update(data)
                assert actual.digest() == expected.digest()
            with lock:
                completed.append(job)
                digests.append((job,expected.hexdigest()))
        except BaseException as error:
            with lock: errors.append(type(error).__name__)
            return


workers = [threading.Thread(target=worker, args=(i,)) for i in range(threads)]
for thread in workers: thread.start()
for thread in workers: thread.join()
assert not errors and sorted(completed) == list(range(jobs)), (errors, len(completed))
batch=hashlib.sha512(''.join(f'{job}:{digest}\n' for job,digest in sorted(digests)).encode()).hexdigest()
print(json.dumps({'batch_fingerprint':batch,'completed':len(completed),'bytes_written':jobs*chunks*65536,'client_cache_control':('unsupported' if cache_failures else 'enabled') if uncached else 'not_requested','integrity':'passed','devices':devices}), flush=True)
