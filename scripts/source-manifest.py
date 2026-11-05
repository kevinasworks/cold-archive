# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Bind one app build to a stable source snapshot; no developer paths in output."""
import hashlib
import json
from pathlib import Path
import sys

ROOT=Path(__file__).resolve().parents[1]


def snapshot():
    paths=[ROOT/'Package.swift',ROOT/'LICENSE',ROOT/'scripts/build-app.sh',ROOT/'scripts/package-runtime.py',ROOT/'scripts/sign-app.py',ROOT/'scripts/source-manifest.py',ROOT/'Assets/ColdArchive.icns']
    if (ROOT/'scripts/signing-policy.json').is_file():
        paths.append(ROOT/'scripts/signing-policy.json')
    paths += [ROOT/'THIRD_PARTY_NOTICES.md', ROOT/'scripts/release-materials.py', ROOT/'vendor/compliance/release-materials.json']
    paths += [ROOT/'OPEN_SOURCE.md',ROOT/'scripts/public-source.py',ROOT/'scripts/public-source.json']
    paths += [ROOT/'README.md',ROOT/'scripts/prepare-runtime.py',ROOT/'scripts/fetch-runtime.py',ROOT/'scripts/runtime-sources.json',ROOT/'Assets/README.md']
    paths += [p for p in (ROOT/'Sources').rglob('*') if p.is_file() and '__pycache__' not in p.parts and p.suffix!='.pyc' and p.name!='.DS_Store']
    return {'schema':1,'files':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(paths)}}


path=Path(sys.argv[2])
if sys.argv[1]=='snapshot':
    path.write_text(json.dumps(snapshot(),indent=2,sort_keys=True)+'\n')
elif sys.argv[1]=='verify':
    assert json.loads(path.read_text())==snapshot(),'Source changed during build; rebuild before delivery'
    print('PASS: stable source snapshot for this build')
else:
    raise SystemExit('Expected snapshot or verify')
