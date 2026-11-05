# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Independent cross-process target and verified-local temporary write pools.

Native and Python writers share permits within each pool. Locks cover write
and flush and are released on process exit; nested writes reuse their permit.
"""
import contextlib
import fcntl
import os
import time
import threading
import json
import uuid
import write_observation
_local = threading.local()

def pool_root(destination=None, temporary=False):
    root = os.environ.get('COLD_ARCHIVE_WRITE_BUDGET')
    device = os.environ.get('COLD_ARCHIVE_LOCAL_TEMP_DEVICE')
    if not root or not temporary or not device or destination is None:
        return root
    try:
        if hasattr(destination, 'fileno'):
            actual = os.fstat(destination.fileno()).st_dev
        elif isinstance(destination, int):
            actual = os.fstat(destination).st_dev
        else:
            path = os.path.realpath(os.fspath(destination))
            while not os.path.exists(path):
                parent = os.path.dirname(path)
                if parent == path: return root
                path = parent
            actual = os.stat(path).st_dev
        local = os.path.join(root, 'temporary')
        if actual == int(device) and os.path.isdir(local): return local
    except (OSError, ValueError, TypeError):
        pass
    return root

checkpoint = lambda: None


@contextlib.contextmanager
def temporary_stage():
    previous = getattr(_local, 'temporary_stage', False)
    _local.temporary_stage = True
    try: yield
    finally: _local.temporary_stage = previous


def observed_pool(destination):
    root = pool_root(destination)
    return root if root in getattr(_local, 'held_pools', set()) else None


def record_write(root, count, seconds):
    lease = getattr(_local, 'leases', {}).get(root)
    if lease is not None:
        write_observation.record(root, count, seconds, lease.domain, lease.stage)


def domain_for(destination):
    try:
        path = os.path.realpath(os.fspath(destination))
        mappings = json.loads(os.environ.get('COLD_ARCHIVE_STORAGE_DOMAINS', '[]'))
        for prefix, domain in mappings:
            if path == prefix or path.startswith(prefix.rstrip('/') + '/'):
                return domain
    except (ValueError, TypeError):
        pass
    return os.environ.get('COLD_ARCHIVE_WRITE_DOMAIN', 'unknown')


@contextlib.contextmanager
def writing(destination=None, temporary=False, stage="target_write"):
    with permit(pool_root(destination, temporary), domain_for(destination), stage):
        yield


class _Marker:
    def __init__(self, root, domain, stage):
        self.domain, self.stage = domain, stage
        self.path = os.path.join(root, 'waiters', uuid.uuid4().hex)
        self.fd = None
        self.queued = 0.0
        self.waited = 0.0
        self.opened = None
        os.makedirs(os.path.dirname(self.path), mode=0o700, exist_ok=True)

    def ensure(self):
        if self.fd is None:
            self.fd = os.open(self.path, os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o600)
            fcntl.flock(self.fd, fcntl.LOCK_EX)
            self.queued=time.monotonic()
            self.opened=self.queued
            os.write(self.fd, json.dumps({'pid': os.getpid(), 'domain': self.domain, 'stage': self.stage, 'queued_at':self.queued}).encode())

    def close(self):
        if self.fd is not None:
            self.waited += time.monotonic()-(self.opened or time.monotonic())
            self.opened=None
            os.close(self.fd)
            self.fd = None
        try: os.unlink(self.path)
        except FileNotFoundError: pass


def _acquire(root, domain, stage):
    marker = _Marker(root, domain, stage)
    waiters = getattr(_local, 'waiters', [])
    _local.waiters = [*waiters, marker]
    failures = 0
    try:
        while True:
            checkpoint()
            marker.ensure()
            gate = os.open(os.path.join(root, 'admission'), os.O_RDWR | os.O_CREAT, 0o600)
            free = []
            try:
                fcntl.flock(gate, fcntl.LOCK_EX)
                try:
                    with open(os.path.join(root, 'policy.json')) as settings: policy = json.load(settings)
                except FileNotFoundError:
                    with open(os.path.join(root, 'limit')) as settings: limit = max(1, min(64, int(settings.read())))
                    policy = {'limit': limit, 'default_limit': limit}
                limit = max(0, min(64, int(policy['limit'])))
                aliases = policy.get('aliases', {})
                canonical = aliases.get(domain, domain)
                domain_limit = max(0, min(64, int(policy.get('domain_limits', {}).get(canonical, policy['default_limit']))))
                occupied = domain_occupied = 0
                owners = {}
                for i in range(64):
                    try: fd = os.open(os.path.join(root, str(i)), os.O_RDWR)
                    except FileNotFoundError: continue
                    try: fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except BlockingIOError:
                        occupied += 1
                        try:
                            owner = json.loads(os.pread(fd, 4096, 0)).get('domain', 'unknown')
                            key=aliases.get(owner, owner)
                            owners[key]=owners.get(key,0)+1
                            if key == canonical: domain_occupied += 1
                        except (ValueError, OSError): domain_occupied += 1
                        os.close(fd)
                    except BaseException:
                        os.close(fd)
                        raise
                    else:
                        if not free: free.append(fd)
                        else: os.close(fd)
                eligible = occupied < limit and domain_occupied < domain_limit and bool(free)
                if eligible:
                    waiting=[]
                    for name in os.listdir(os.path.join(root,'waiters')):
                        try: fd=os.open(os.path.join(root,'waiters',name),os.O_RDWR)
                        except OSError: continue
                        try:
                            try: fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
                            except BlockingIOError:
                                try:
                                    row=json.loads(os.pread(fd,4096,0))
                                    waiting.append((float(row['queued_at']),name,aliases.get(row['domain'],row['domain'])))
                                except (ValueError,KeyError,OSError): pass
                        finally: os.close(fd)
                    virtual=dict(owners)
                    reserved=occupied
                    for queued,name,key in sorted(waiting):
                        if (queued,name)>=(marker.queued,os.path.basename(marker.path)): break
                        cap=max(0,min(64,int(policy.get('domain_limits',{}).get(key,policy['default_limit']))))
                        if reserved<limit and virtual.get(key,0)<cap:
                            virtual[key]=virtual.get(key,0)+1;reserved+=1
                    eligible = reserved<limit and virtual.get(canonical,0)<domain_limit
                if eligible:
                    held = free[0]
                    os.ftruncate(held, 0)
                    os.write(held, json.dumps({'pid': os.getpid(), 'domain': domain, 'stage': stage}).encode())
                    free.pop(0)
                    return held,marker.waited+(time.monotonic()-(marker.opened or time.monotonic()))
            finally:
                for fd in free: os.close(fd)
                os.close(gate)
            failures += 1
            time.sleep(min(.05, .005 * (1 + failures)))
    finally:
        marker.close()
        _local.waiters = waiters


class _Lease:
    def __init__(self, root, domain, stage):
        self.root, self.domain, self.stage = root, domain, stage
        self.fd = None
        self.last_wait = 0.0

    def acquire(self):
        if self.fd is None:
            self.fd,self.last_wait = _acquire(self.root, self.domain, self.stage)
            if self.last_wait>.05 and os.environ.get('COLD_ARCHIVE_IO_DIAGNOSTICS')=='1':
                print('IO_SAMPLE '+json.dumps({'event':'permit_wait','stage':self.stage,'metric_source':'admission_wait','seconds':self.last_wait},separators=(',',':')),file=__import__('sys').stderr,flush=True)

    def release(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None


def pause_current():
    # Called only at cooperative checkpoints, outside active read/write syscalls
    # and after running child tools finish. Paused waiters are not demand.
    leases = [lease for lease in getattr(_local, 'leases', {}).values() if lease.fd is not None]
    for lease in leases:
        write_observation.flush(lease.root, lease.domain, lease.stage)
        lease.release()
    for marker in getattr(_local, 'waiters', []): marker.close()
    return leases


def resume_current(leases):
    for lease in leases: lease.acquire()


@contextlib.contextmanager
def reading(destination):
    base = os.environ.get('COLD_ARCHIVE_WRITE_BUDGET')
    root = os.path.join(base, 'reading') if base else None
    if root and not os.path.isdir(root): root = None
    with permit(root, domain_for(destination), 'read') as lease:
        yield lease


@contextlib.contextmanager
def permit(root, domain='unknown', stage='target_write'):
    if not root:
        yield None
        return
    leases = getattr(_local, 'leases', {})
    if root in leases:
        yield leases[root]
        return
    lease = _Lease(root, domain, stage)
    lease.acquire()
    held_pools = getattr(_local, 'held_pools', set())
    _local.leases = {**leases, root: lease}
    _local.held_pools = held_pools | {root}
    try:
        yield lease
    finally:
        write_observation.flush(lease.root, lease.domain, lease.stage)
        lease.release()
        _local.leases = leases
        _local.held_pools = held_pools

def write(stream, data):
    # This helper is used by metadata spools/tool output, never archive outputs.
    with writing(stream, temporary=True):
        started = time.monotonic()
        count = stream.write(data)
        stream.flush()
        written = data if count is None else data[:count]
        encoded = written.encode(getattr(stream, 'encoding', None) or 'utf-8') if isinstance(written, str) else written
        record_write(pool_root(stream, temporary=True), len(encoded), time.monotonic() - started)

def limited(function):
    import functools
    @functools.wraps(function)
    def wrapped(*args, **kwargs):
        with writing():
            return function(*args, **kwargs)
    return wrapped
