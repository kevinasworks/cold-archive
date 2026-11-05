# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Regression tests for role-aware brand mapping and full enumeration."""
import json, sys, subprocess, tempfile
from pathlib import Path
ENGINE = Path(__file__).resolve().parents[1] / 'Sources/ColdArchive/Resources/Engine'
sys.path.insert(0, str(ENGINE))
from metadata_candidates import candidates
from media_metadata import suggestions

def c(tags): return candidates([dict(SourceFile='fixture', **tags)])
assert {x['value'] for x in c({'Keys:AndroidMake':'Samsung','Keys:AndroidModel':'SM-test'})} == {'Samsung','SM-test'}
assert c({'DICOM:Manufacturer':'SIEMENS'})[0]['value']=='SIEMENS'
assert not c({'Custom:Make':'fake','IFD0:Doc1:Make':'Nikon','QuickTime:MajorBrand':'qt'})
assert [x['value'] for x in c({'IFD0:Make':'Canon','IFD0:Doc1:Make':'Nikon'})]==['Canon']
assert not c({'XMP-aux:LensMake':'Sony','ICC_Profile:DeviceManufacturer':'Apple'})
assert any(x['field']=='capture_device_make' for x in suggestions({'format':{'tags':{'com.android.manufacturer':'Samsung'}}},Path('fixture')))
with tempfile.TemporaryDirectory() as t:
    root=Path(t); source=root/'source'; source.mkdir()
    for name in ['keep.xmp','hidden.bak','._sidecar','.DS_Store']:
        (source/name).write_text('<x:xmpmeta xmlns:x="adobe:ns:meta/"/>')
    (source/'link').symlink_to(source/'keep.xmp')
    report=root/'report.json'
    subprocess.run([sys.executable,'-B',str(ENGINE/'inspect_source_metadata.py'),str(source),'--output-json',str(report)],check=True,capture_output=True)
    data=json.loads(report.read_text())
    assert data['attempted_file_count']==5
    assert {Path(x['path']).name for x in data['files']}=={'keep.xmp','hidden.bak','._sidecar','.DS_Store','link'}
    assert next(x for x in data['files'] if x['path'].endswith('/link'))['status']=='failed'
print('PASS: Android, DICOM, embedded scope, namespace, lens/profile rejection, FFprobe Android, excluded-name enumeration, symlink reporting')
# A source changing after parsers run must not leak staged candidates.
import inspect_source_metadata as inspector
from unittest.mock import patch
with tempfile.TemporaryDirectory() as t:
    source=Path(t)/'fixture.xmp';source.write_text('before')
    output=Path(t)/'report.json'
    def changed(tool, path):
        path.write_text('changed-after-read')
        return ([{'SourceFile':str(path),'IFD0:Make':'Should not survive'}],[],[],'')
    with patch.object(sys,'argv',['inspect',str(source),'--output-json',str(output)]), patch.object(inspector,'inspect_file',side_effect=changed), patch.object(inspector.media_metadata,'needed',return_value=False):
        inspector.main()
    data=json.loads(output.read_text())
    assert data['files'][0]['status']=='failed' and not data['candidates']
print('PASS: source mutation rolls back staged candidates')
