# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ENGINE = Path(__file__).resolve().parents[1] / 'Sources/ColdArchive/Resources/Engine'
sys.path.insert(0, str(ENGINE))
import media_metadata

path = Path('misnamed.mp4')
data = {'format': {'format_name': 'mpeg', 'tags': {'make': 'TestBrand', 'model': 'TestModel', 'author': 'Not a device'}},
        'streams': [{'codec_type': 'video', 'codec_name': 'mpeg2video', 'tags': {'encoder': 'Test encoder'}}]}
values = media_metadata.suggestions(data, path)
assert {v['field'] for v in values} == {'source_type', 'capture_device_make', 'capture_device_model', 'creation_or_editing_software'}
assert all(v['tool'] == 'ffprobe' for v in values)
assert not media_metadata.suggestions({'format': {'tags': {'handler_name': 'Fake camera', 'author': 'Someone'}}}, path)
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    media = root / 'misnamed.mp4'
    subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'color=size=64x48:rate=25',
                    '-t', '0.2', '-c:v', 'mpeg2video', '-f', 'mpeg', str(media)], check=True)
    # A nonstandard prefix reproduces a readable PS stream rejected by ExifTool.
    media.write_bytes(b'IMKH' + bytes(1020) + media.read_bytes())
    output = root / 'report.json'
    subprocess.run([sys.executable, '-B', str(ENGINE / 'inspect_source_metadata.py'), str(media), '--output-json', str(output)], check=True)
    report = json.loads(output.read_text())
    entry = report['files'][0]
    assert entry['media_status'] == 'read', entry
    assert entry['media_metadata']['format']['format_name'] == 'mpeg'
    assert entry['media_metadata']['streams'][0]['width'] == 64
    assert report['inspected_file_count'] == 1
    assert any(c['tool'] == 'ffprobe' and c['field'] == 'source_type' for c in report['candidates'])
    if report['errors']:
        assert entry['status'] == 'partial'
        assert report['coverage'] == 'all_files_attempted_with_errors'
print('PASS: misnamed prefixed MPEG-PS, full raw media report, provenance, conservative tags and partial-read semantics')
