# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Fault injection uses only synthetic local files; never fills or disconnects disks."""
from pathlib import Path
import contextlib
import io
import sys
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

ENGINE = Path(__file__).resolve().parents[1] / 'Sources/ColdArchive/Resources/Engine'
sys.path.insert(0, str(ENGINE))
import create_archive_bundle as engine
from test_answer_fixture import fixture_args

with tempfile.TemporaryDirectory(prefix='coldarchive-faults-') as temporary:
    root = Path(temporary)
    source = root / 'source'
    source.mkdir()
    payload = source / 'payload.txt'
    payload.write_text('synthetic original')
    output = root / 'output'
    output.mkdir()
    args = ['archive', str(source), '--archive-name', 'Fault', '--output-dir', str(output), *fixture_args([source])]
    def check_failure(context, expected):
        with patch.object(sys, 'argv', args), context, contextlib.redirect_stdout(io.StringIO()):
            try:
                engine.main()
            except (SystemExit, OSError) as error:
                assert expected in str(error), repr(error)
            else:
                raise AssertionError('Fault was not rejected')
        assert list(output.iterdir()) == [], list(output.iterdir())

    check_failure(patch.object(engine.shutil, 'disk_usage', return_value=SimpleNamespace(free=0)), 'Insufficient target-disk space')
    assert payload.read_text() == 'synthetic original'
    print('PASS: injected insufficient space rejects before publication and leaves no output')

    check_failure(patch.object(engine.tempfile, 'mkdtemp', side_effect=PermissionError('Injected output permission denied')), 'Injected output permission denied')
    assert payload.read_text() == 'synthetic original'
    print('PASS: injected workspace permission failure leaves source and output intact')

    original_print = print
    def mutate_before_source_recheck(*items, **kwargs):
        if items and str(items[0]).startswith('PHASE 11 '):
            payload.write_text('synthetic changed during archival')
        original_print(*items, **kwargs)
    check_failure(patch.object(engine, 'print', mutate_before_source_recheck, create=True), 'hash-changed')
    assert payload.read_text() == 'synthetic changed during archival'
    print('PASS: source modification during archive is rejected and staging is cleaned')
