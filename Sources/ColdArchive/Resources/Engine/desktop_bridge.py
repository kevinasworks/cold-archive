# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Desktop adapter: cooperative cancellation at safe engine checkpoints.

Never raise asynchronously between a filesystem mutation and its bookkeeping.
Child tools stop before the engine unwinds its existing cleanup transaction.
"""
import builtins
import hashlib
import json
import os
import time
import signal
import stat
import subprocess
import sys
import weakref
from pathlib import Path
import write_observation
import create_archive_bundle as engine
import write_budget
from io_observation import ReadObservation

children = weakref.WeakSet()
cancelled = False
bundle = None
original_print = builtins.print
OriginalPopen = subprocess.Popen


def checkpoint():
    paused = os.path.exists(os.environ.get("COLD_ARCHIVE_PAUSE_FILE", ""))
    suspended = write_budget.pause_current() if paused else []
    while not cancelled and os.path.exists(os.environ.get("COLD_ARCHIVE_PAUSE_FILE", "")):
        time.sleep(0.1)
    if cancelled:
        raise SystemExit(130)
    write_budget.resume_current(suspended)


def stop_child(child):
    if child.poll() is None:
        child.terminate()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()


class TrackedPopen(OriginalPopen):
    def __init__(self, *args, **kwargs):
        checkpoint()
        command = args[0] if args else kwargs.get('args', [])
        self._observation_stage = None
        if isinstance(command, (list, tuple)) and len(command)>1 and Path(command[0]).name in ('7zz','7z','7za'):
            self._observation_stage = {'a':'compress','x':'restore','t':'archive_test','l':'archive_list'}.get(command[1])
        self._observation_reported = False
        super().__init__(*args, **kwargs)
        self._observation_started = time.monotonic()
        children.add(self)
        if cancelled:
            stop_child(self)

    def wait(self, *args, **kwargs):
        result = super().wait(*args, **kwargs)
        if self._observation_stage and not self._observation_reported:
            self._observation_reported = True
            original_print('IO_SAMPLE '+json.dumps({'event':'tool_operation','stage':self._observation_stage,
                'metric_source':'tool_wall_time','seconds':max(0,time.monotonic()-self._observation_started),
                'exit_code':result},separators=(',',':')),file=sys.stderr,flush=True)
        return result


subprocess.Popen = TrackedPopen


def cancel(signum, frame):
    global cancelled
    cancelled = True
    # Repeated clicks/signals cannot interrupt rollback or cleanup.
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    for child in list(children):
        # The signal may interrupt Popen.wait while it holds its waitpid lock.
        # Let that original wait reap the child and unwind the staging transaction.
        if child.returncode is None:
            try:
                os.kill(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass


def engine_print(*args, **kwargs):
    global bundle
    if args and isinstance(args[0], str):
        if args[0].startswith('PHASE '):
            checkpoint()
        if args[0].startswith('BUNDLE '):
            bundle = args[0][7:]
    original_print(*args, **kwargs)


def cancellable_sha512(path):
    # Same identity/size/mtime and regular-file gates as the frozen helper.
    checkpoint()
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode):
        raise SystemExit(f'Not a regular file while hashing: {path}')
    digest = hashlib.sha512()
    observation = ReadObservation(lambda line: original_print(line, flush=True))
    try:
        with write_budget.reading(path), path.open('rb') as stream:
            while True:
                before_checkpoint = time.monotonic()
                checkpoint()
                observation.exclude_idle(time.monotonic() - before_checkpoint)
                started = time.monotonic()
                chunk = stream.read(engine.CHUNK_SIZE)
                elapsed = time.monotonic() - started
                if not chunk: break
                observation.record(len(chunk), elapsed)
                digest.update(chunk)
    finally:
        # Preserve the final partial measurement on cancellation and read errors.
        observation.flush()
    after = path.lstat()
    stable_before = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
    stable_after = (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
    if stable_before != stable_after or not stat.S_ISREG(after.st_mode):
        raise SystemExit(f'File changed while hashing: {path}')
    checkpoint()
    return digest.hexdigest()


# Path's successful return lets us count encoded bytes actually written rather
# than infer them from file size. Scope this instrumentation to the desktop child.
_original_write_text = Path.write_text
_original_write_bytes = Path.write_bytes

def observed_write_text(path, data, encoding=None, errors=None, newline=None):
    started = time.monotonic()
    count = _original_write_text(path, data, encoding=encoding, errors=errors, newline=newline)
    encoded = data[:count].encode(encoding or 'utf-8', errors or 'strict')
    write_budget.record_write(write_budget.observed_pool(path), len(encoded), time.monotonic() - started)
    return count

def observed_write_bytes(path, data):
    started = time.monotonic()
    count = _original_write_bytes(path, data)
    write_budget.record_write(write_budget.observed_pool(path), count, time.monotonic() - started)
    return count

Path.write_text = observed_write_text
Path.write_bytes = observed_write_bytes

# Archive document writes and the one archive-output stream share the same
# target-file budget. Local metadata temporaries have their own budget.
# Recovery stays a sequential writer;
# compression CPU threads are unrelated to the number of output files.
for name in tuple(vars(engine)):
    if name.startswith('write_') and callable(getattr(engine, name)):
        setattr(engine, name, write_budget.limited(getattr(engine, name)))
original_engine_run = engine.run

def budgeted_engine_run(command, cwd):
    if len(command) < 2:
        return original_engine_run(command, cwd)
    action = command[1]
    operands = [part for part in command[2:] if not part.startswith('-')]
    archive = Path(operands[0]) if operands else Path(cwd)
    if not archive.is_absolute(): archive = Path(cwd) / archive
    read_source = Path(cwd) if action == 'a' else archive
    if action in ('a', 'x'):
        destination = archive
        if action == 'x':
            command = [*command, '-mmt=1']
            output = next((part[2:] for part in command if part.startswith('-o')), None)
            destination = Path(output) if output else Path(cwd)
        temporary = getattr(write_budget._local, 'temporary_stage', False)
        with write_budget.reading(read_source), write_budget.writing(destination, temporary=temporary, stage="compress" if action=="a" else "restore"):
            return original_engine_run(command, cwd)
    if action in ('t', 'l'):
        with write_budget.reading(read_source):
            return original_engine_run(command, cwd)
    return original_engine_run(command, cwd)

_original_compatibility_test = engine.run_filename_compatibility_test

def budgeted_compatibility_test(*args, **kwargs):
    with write_budget.temporary_stage():
        return _original_compatibility_test(*args, **kwargs)

engine.run_filename_compatibility_test = budgeted_compatibility_test

write_budget.checkpoint = checkpoint
engine.run = budgeted_engine_run
engine.print = engine_print
engine.sha512 = cancellable_sha512
signal.signal(signal.SIGTERM, cancel)

if __name__ == '__main__':
    try:
        code = engine.main()
        # Reaching main's successful return means publication and cleanup passed,
        # even if a cancellation arrived after the transaction committed.
        original_print('DESKTOP_RESULT ' + json.dumps({'state': 'completed', 'bundle': bundle}, ensure_ascii=False), flush=True)
        sys.exit(code)
    except subprocess.CalledProcessError as error:
        if cancelled:
            original_print('DESKTOP_RESULT {"state":"cancelled"}', flush=True)
            sys.exit(130)
        original_print(f'Command failed with exit status {error.returncode}', file=sys.stderr)
        sys.exit(error.returncode)
    except SystemExit as error:
        if error.code == 130:
            original_print('DESKTOP_RESULT {"state":"cancelled"}', flush=True)
        raise
