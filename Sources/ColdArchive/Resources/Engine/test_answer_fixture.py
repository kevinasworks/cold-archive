# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Synthetic answers for local regression fixtures only; never used by the archive CLI."""
import atexit
import json
from pathlib import Path
import tempfile

def fixture_args(paths):
    with tempfile.NamedTemporaryFile(mode="w",suffix=".json",prefix="archive-test-answers-",delete=False) as f:
        answers={key:{"answer":"不清楚"} for key in ['source_type','device','source_software','purpose']}
        answers['notes']={"answer":"无补充"}
        for record in answers.values():
            record['status'] = 'submitted'
        json.dump({'schema_version':2,'sources':[str(Path(p).resolve()) for p in paths],'answers':answers},f)
        path=Path(f.name)
    atexit.register(path.unlink,missing_ok=True)
    return ['--source-answers-json',str(path)]
