# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Audit a staged runtime and execute it without developer environment variables."""
import hashlib,json,os,subprocess,sys,tempfile
from pathlib import Path
runtime=Path(sys.argv[1]).resolve()
manifest=json.loads((runtime/'component-manifest.json').read_text())
issues=[]
for name,digest in manifest['binaries'].items():
    p=runtime/name
    if hashlib.sha256(p.read_bytes()).hexdigest()!=digest:issues.append('checksum '+name)
    deps=subprocess.check_output(['/usr/bin/otool','-L',str(p)],text=True)
    for line in deps.splitlines():
        if line.startswith('\t'):
            dep=line.strip().split(' (')[0]
            if dep.startswith('/') and not dep.startswith(('/usr/lib/','/System/Library/')):issues.append(name+': '+dep)
    subprocess.run(['/usr/bin/codesign','--verify','--strict',str(p)],check=True,capture_output=True)
with tempfile.TemporaryDirectory(prefix='coldarchive-empty-home-') as home:
    env={'HOME':home,'TMPDIR':home,'PATH':str(runtime/'bin')+':/usr/bin:/bin:/usr/sbin:/sbin','COLDARCHIVE_RUNTIME':str(runtime),'PYTHONDONTWRITEBYTECODE':'1','PYTHONNOUSERSITE':'1','LANG':'en_US.UTF-8'}
    checks=[['python3','-c','import ssl,sqlite3,zlib,olefile,pypdf,defusedxml,ijson; print("Python and all modules OK")'],['perl','-MJSON::PP','-MDigest::SHA','-MMIME::Base64','-e','print "Perl OK\\n"'],['exiftool','-ver'],['ffprobe','-version'],['mediainfo','--Version'],['sf','-home',str(runtime/'siegfried/data/siegfried'),'-version'],['7zz','i']]
    for command in checks:
        p=subprocess.run(command,env=env,capture_output=True,text=True,check=True)
        print(command[0]+': '+p.stdout.splitlines()[0] if p.stdout.splitlines() else command[0]+': OK')
    dec=subprocess.check_output(['ffprobe','-v','quiet','-decoders'],env=env,text=True)
    assert not any(line.startswith(' V') or line.startswith(' A') or line.startswith(' S') for line in dec.splitlines()[10:]),dec
if issues:raise SystemExit('\n'.join(issues))
print(f'PASS: {len(manifest["binaries"])} binary hashes/signatures/dependencies and clean-environment launches')
