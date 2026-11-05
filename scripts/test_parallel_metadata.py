# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Disk-backed worker/merge equivalence, ACL and archive directory coverage."""
import json, os, subprocess, tempfile, sys, hashlib
from pathlib import Path
root=Path(__file__).resolve().parents[1];engine=root/'Sources/ColdArchive/Resources/Engine'
env=os.environ.copy();env['COLDARCHIVE_RUNTIME']=str(root/'vendor/runtime');env['PATH']=str(root/'vendor/runtime/bin')+':'+env.get('PATH','')
python=root/'vendor/runtime/python/bin/python3'
def run(args):
    p=subprocess.run([str(python),'-B',str(engine/'inspect_source_metadata.py'),*map(str,args)],env=env,capture_output=True,text=True,timeout=90)
    assert p.returncode==0,p.stderr+p.stdout
with tempfile.TemporaryDirectory(prefix='worker-equivalence-') as tmp:
    base=Path(tmp);source=base/'source';source.mkdir();workers=base/'workers';workers.mkdir()
    (source/'one.xmp').write_text('<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/" dc:description="Metadata fixture"/></rdf:RDF></x:xmpmeta>')
    (source/'unknown.bin').write_bytes(bytes(range(255)))
    (source/'link').symlink_to(source/'one.xmp')
    payload=base/'payload.txt';payload.write_text('BODY_NOT_METADATA_SENTINEL')
    subprocess.run([str(root/'vendor/runtime/bin/7zz'),'a',str(source/'fixture.7z'),str(payload)],check=True,env=env,stdout=subprocess.DEVNULL)
    before={p.name:hashlib.sha512(p.read_bytes()).hexdigest() for p in source.iterdir() if not p.is_symlink()}
    run([source,'--output-json',base/'serial.json'])
    run([source,'--enumerate-only','--manifest',base/'manifest.json'])
    manifest=json.loads((base/'manifest.json').read_text())
    for i,p in enumerate(manifest['file_paths']):run(['--worker-file',p,'--output-json',workers/f'{i}.json'])
    run(['--manifest',base/'manifest.json','--merge-directory',workers,'--output-json',base/'merged.json'])
    serial=json.loads((base/'serial.json').read_text());merged=json.loads((base/'merged.json').read_text())
    def normalized(value):
        if isinstance(value,dict):
            return {k:normalized(v) for k,v in value.items() if k not in {'st_atime_ns','scandate'} and not k.endswith((':FileAccessDate',':ProcessingTime',':Now',':NewGUID'))}
        if isinstance(value,list):
            items=[normalized(v) for v in value if not (isinstance(v,dict) and v.get('tag') in {'FileAccessDate','ProcessingTime','Now','NewGUID'})]
            # ExifTool Perl hash enumeration order varies across worker processes.
            if items and all(isinstance(v,dict) and 'tag' in v for v in items):items.sort(key=lambda v:json.dumps(v,sort_keys=True))
            return items
        return value
    if normalized(serial)!=normalized(merged):
        import difflib
        print(''.join(difflib.unified_diff(json.dumps(normalized(serial),sort_keys=True,indent=2).splitlines(True),json.dumps(normalized(merged),sort_keys=True,indent=2).splitlines(True)))[:10000])
        raise AssertionError('Serial and worker reports differ')
    archive=next(x for x in merged['files'] if x['path'].endswith('.7z'))
    assert 'payload.txt' in archive['archive_directory']['listing']
    assert 'BODY_NOT_METADATA_SENTINEL' not in json.dumps(merged)
    assert 'acl' in archive['filesystem_metadata']
    assert before=={p.name:hashlib.sha512(p.read_bytes()).hexdigest() for p in source.iterdir() if not p.is_symlink()}
    print('PASS: serial/worker equivalence, stable mapping, failed file and symlink coverage, native ACL, 7z directory without content, unchanged sources')
