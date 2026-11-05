# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""End-to-end desktop adapter checks with synthetic, disposable inputs only."""
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

ENGINE = Path(__file__).resolve().parents[1] / 'Sources/ColdArchive/Resources/Engine'
sys.path.insert(0, str(ENGINE))
from test_answer_fixture import fixture_args

def run():
    with tempfile.TemporaryDirectory(prefix='coldarchive-desktop-test-') as temp:
        root = Path(temp)
        source = root / 'source'
        source.mkdir()
        (source / '中文 📦.txt').write_text('Desktop fixture\n' * 20)
        (source / 'empty').mkdir()
        output = root / 'output with\nnewline'
        output.mkdir()
        command = [sys.executable, '-B', '-u', str(ENGINE / 'desktop_bridge.py'), str(source), '--archive-name', '桌面_Test', '--output-dir', str(output), '--require-source-confirmation', *fixture_args([source])]
        result = subprocess.run(command, capture_output=True, text=True, timeout=60)
        assert result.returncode == 0, result.stdout + result.stderr
        samples = [json.loads(line[10:]) for line in result.stderr.splitlines() if line.startswith('IO_SAMPLE ')]
        operations = [row for row in samples if row.get('event') == 'tool_operation']
        assert {'compress', 'restore', 'archive_test'} <= {row['stage'] for row in operations}, samples
        assert all(row['exit_code'] == 0 and row['seconds'] >= 0 and row['metric_source'] == 'tool_wall_time' for row in operations)
        assert all('path' not in row and 'command' not in row for row in operations)
        line = next(line for line in result.stdout.splitlines() if line.startswith('DESKTOP_RESULT '))
        event = json.loads(line.removeprefix('DESKTOP_RESULT '))
        assert event['state'] == 'completed'
        bundle = Path(event['bundle'])
        assert bundle.is_dir() and bundle.parent == output.resolve()
        assert (bundle / '桌面_Test.7z').is_file()
        # Repeat same bytes/name: original destination must survive unchanged.
        archive = bundle / '桌面_Test.7z'
        digest = hashlib.sha512(archive.read_bytes()).hexdigest()
        again = subprocess.run(command, capture_output=True, text=True, timeout=60)
        assert again.returncode != 0 and 'Refusing to overwrite' in again.stderr
        assert hashlib.sha512(archive.read_bytes()).hexdigest() == digest
        assert [p.resolve() for p in output.iterdir()] == [bundle]
        # Signal at hash, compression and final-publication phase boundaries.
        (source / 'payload.bin').write_bytes(os.urandom(8 * 1024 * 1024))
        before = {p.name: hashlib.sha512(p.read_bytes()).hexdigest() for p in source.iterdir() if p.is_file()}
        for phase in ['PHASE 6 ', 'PHASE 7 ', 'PHASE 15 ']:
            out = root / phase.strip().replace(' ', '-')
            out.mkdir()
            cancel_cmd = [sys.executable, '-B', '-u', str(ENGINE / 'desktop_bridge.py'), str(source), '--archive-name', 'Cancel', '--output-dir', str(out), *fixture_args([source])]
            process = subprocess.Popen(cancel_cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            lines = []
            for line in process.stdout:
                lines.append(line)
                if line.startswith(phase):
                    process.send_signal(signal.SIGTERM)
                    break
            rest, _ = process.communicate(timeout=30)
            text = ''.join(lines) + rest
            assert process.returncode == 130, text
            assert 'DESKTOP_RESULT {"state":"cancelled"}' in text, text
            assert not list(out.iterdir()), list(out.iterdir())
        # Interrupt a blocking Popen.wait, after the subprocess has started.
        waiting = subprocess.Popen(
            [sys.executable, '-B', '-u', '-c',
             "import desktop_bridge, subprocess, sys; "
             "subprocess.Popen([sys.executable, '-u', '-c', "
             "'import time; print(123, flush=True); time.sleep(60)']).wait(); "
             "desktop_bridge.checkpoint()"],
            cwd=ENGINE, stdout=subprocess.PIPE, text=True,
        )
        try:
            assert waiting.stdout.readline().strip() == '123'
            time.sleep(0.2)
            waiting.terminate()
            assert waiting.wait(timeout=5) == 130
        finally:
            if waiting.poll() is None:
                waiting.kill()
                waiting.wait()
            waiting.stdout.close()
        after = {p.name: hashlib.sha512(p.read_bytes()).hexdigest() for p in source.iterdir() if p.is_file()}
        assert before == after
        print('PASS: desktop completion protocol, newline path, exclusive publication, cancellation at hashing/compression/publication, cleanup and unchanged sources')

if __name__ == '__main__':
    run()
