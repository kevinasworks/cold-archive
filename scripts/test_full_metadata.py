# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Full metadata regressions; fixtures only, including non-provenance tags."""
import hashlib
import json
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile

ENGINE = Path(__file__).resolve().parents[1] / 'Sources/ColdArchive/Resources/Engine'
sys.path.insert(0, str(ENGINE))
from test_answer_fixture import fixture_args

with tempfile.TemporaryDirectory(prefix='coldarchive-full-metadata-') as temp:
    root = Path(temp)
    source = root / 'source'
    source.mkdir()
    # More than the previous 32-file cap; full report exceeds the log's 2 MB cap.
    for i in range(35):
        text = 'Synthetic description ' + ('x' * 65000) + f' END-{i}'
        (source / f'{i:02}.xmp').write_text(f'''<?xml version="1.0"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
<rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:tiff="http://ns.adobe.com/tiff/1.0/" xmlns:exif="http://ns.adobe.com/exif/1.0/" tiff:Make="Synthetic camera" tiff:Model="Fixture-{i}" exif:GPSLatitude="1,2.3N">
<dc:description><rdf:Alt><rdf:li xml:lang="x-default">{text}</rdf:li></rdf:Alt></dc:description>
</rdf:Description></rdf:RDF></x:xmpmeta>''')
    originals = {p.name: hashlib.sha512(p.read_bytes()).hexdigest() for p in source.iterdir()}
    report = root / 'metadata.json'
    command = [sys.executable, '-B', str(ENGINE / 'inspect_source_metadata.py'), str(source), '--output-json', str(report)]
    result = subprocess.run(command, capture_output=True, text=True, timeout=90)
    assert result.returncode == 0, result.stderr
    data = json.loads(report.read_text())
    assert data['selected_file_count'] == data['attempted_file_count'] == data['inspected_file_count'] == 35
    assert len(data['files']) == 35 and not data['errors']
    assert report.stat().st_size > 2_000_000
    last = data['files'][-1]['metadata'][0]
    assert any(k.endswith(':Description') and str(v).endswith('END-34') for k, v in last.items())
    assert any(k.endswith(':GPSLatitude') for k in last)
    assert any(c['value'] == 'Fixture-34' for c in data['candidates'])
    assert all(len(row['metadata']) for row in data['files'])
    assert originals == {p.name: hashlib.sha512(p.read_bytes()).hexdigest() for p in source.iterdir()}
    repeat = subprocess.run(command, capture_output=True, text=True, timeout=90)
    assert repeat.returncode != 0 and json.loads(report.read_text()) == data
    # Unsupported file is attempted, reported individually, never called metadata-free.
    invalid = root / 'unknown.bin'; invalid.write_bytes(bytes(range(256)))
    failure = subprocess.run([sys.executable, '-B', str(ENGINE / 'inspect_source_metadata.py'), str(invalid)], capture_output=True, text=True, timeout=30)
    failure_report = json.loads(failure.stdout)
    assert failure_report['attempted_file_count'] == 1 and failure_report['errors']
    assert failure_report['coverage'] == 'all_files_attempted_with_errors'
    # End-to-end archive must preserve the full >2MB metadata evidence in documents.
    output = root / 'archives'; output.mkdir()
    details = root / 'details.json'
    raw = report.read_text()
    details.write_text(json.dumps({'metadata_evidence': {'state': 'provided', 'zh': raw, 'en': raw}}))
    archive = subprocess.run([sys.executable, '-B', str(ENGINE / 'desktop_bridge.py'), str(source), '--archive-name', 'FullMetadataFixture', '--output-dir', str(output), *fixture_args([source]), '--source-details-json', str(details)], capture_output=True, text=True, timeout=90)
    assert archive.returncode == 0, archive.stdout[-2000:] + archive.stderr
    info = next(output.glob('*/Documents/SOURCE_INFO.md')).read_text()
    assert 'END-34' in info and 'GPSLatitude' in info
    # Cancellation must stop ExifTool and never publish a partial report.
    cancelled_report = root / 'cancelled.json'
    process = subprocess.Popen(command[:-1] + [str(cancelled_report)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    assert process.stdout.readline().startswith('METADATA_PROGRESS ')
    process.send_signal(signal.SIGTERM)
    process.communicate(timeout=15)
    assert process.returncode == 130 and not cancelled_report.exists()
    print('PASS: 35/35 files; all-tag description and GPS beyond whitelist; >2 MB report; candidate from last file; unchanged sources; exclusive report; explicit failure; complete archive evidence; cancellation')
