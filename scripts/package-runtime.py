# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Stage the pinned, project-local runtime; never copy Homebrew dynamic libraries."""
import hashlib,json,os,shutil,subprocess,sys
from pathlib import Path
root=Path(__file__).resolve().parents[1]; src=root/'vendor/runtime'; dest=Path(sys.argv[1])
if dest.exists():shutil.rmtree(dest)
dest.mkdir(parents=True)
for name in ['python','exiftool','bin','Licenses']:
    shutil.copytree(src/name,dest/name,symlinks=True,ignore=shutil.ignore_patterns('__pycache__','*.pyc'))
for name in ['perl/lib','siegfried/data/siegfried']:
    shutil.copytree(src/name,dest/name,symlinks=True)
for name in ['perl/bin/perl','media/bin/ffprobe','mediainfo/mediainfo','siegfried/sf']:
    (dest/name).parent.mkdir(parents=True,exist_ok=True);shutil.copy2(src/name,dest/name)
# Perl modules can include generated .packlist files; these are not runtime code.
for p in (dest/'perl').rglob('.packlist'):p.unlink()
components=[
 {'name':'Python','version':'3.13.16 / PBS 20261003','source':'https://github.com/astral-sh/python-build-standalone/releases/tag/20261003'},
 {'name':'Perl','version':'5.42.0','source':'https://www.cpan.org/src/5.0/perl-5.42.0.tar.gz','build':'relocatableinc; clang; deployment target 14.0'},
 {'name':'ExifTool','version':'13.55','source':'https://github.com/exiftool/exiftool/releases/tag/13.55'},
 {'name':'FFprobe','version':'7.1.1','source':'https://ffmpeg.org/releases/ffmpeg-7.1.1.tar.xz','build':'static; no network/decoders/encoders/avfilter/avdevice; file and pipe protocols'},
 {'name':'MediaInfo','version':'26.05','source':'https://mediaarea.net/download/binary/mediainfo/26.05/MediaInfo_CLI_26.05_Mac.dmg'},
 {'name':'Siegfried','version':'1.11.9 / PRONOM V125','source':'https://github.com/richardlehane/siegfried/releases/tag/v1.11.9'},
 {'name':'7-Zip','version':'26.03','source':'https://www.7-zip.org/','origin':'existing local Homebrew distribution; executable links only system libraries'},
 {'name':'olefile','version':'0.47','source':'https://github.com/decalage2/olefile'},
 {'name':'pypdf','version':'6.1.1','source':'https://github.com/py-pdf/pypdf'},
 {'name':'defusedxml','version':'0.7.1','source':'https://github.com/tiran/defusedxml'},
 {'name':'ijson','version':'3.4.0.post0','source':'https://github.com/ICRAR/ijson'},
 {'name':'Archive::Zip','version':'1.68','source':'https://cpan.metacpan.org/authors/id/P/PH/PHRED/Archive-Zip-1.68.tar.gz'}]
mach_magic={b'\xcf\xfa\xed\xfe',b'\xce\xfa\xed\xfe',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca'}
executable_hashes={}; binaries=[]
for p in dest.rglob('*'):
    if not p.is_file() or p.is_symlink():continue
    with p.open('rb') as f:magic=f.read(4)
    if magic not in mach_magic:continue
    link=subprocess.check_output(['/usr/bin/otool','-L',str(p)],text=True)
    for line in link.splitlines():
        dep=line.strip().split(' (')[0]
        if line.startswith('\t') and dep.startswith('/') and not dep.startswith(('/usr/lib/','/System/Library/')):
            raise RuntimeError(f'External dependency {p}: {dep}')
    subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(p)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
    binaries.append(str(p.relative_to(dest)))
    executable_hashes[str(p.relative_to(dest))]=hashlib.sha256(p.read_bytes()).hexdigest()
archives={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in (root/'vendor/downloads').iterdir() if p.is_file() and p.suffix in {'.gz','.xz','.zip','.dmg'}}
manifest={'architecture':'arm64','minimum_macos':'14.0','network_required':False,'components':components,
          'binaries':executable_hashes,'download_sha256':archives,
          'qualification':'dependency audit and local relocation tests; separate physical Mac not tested'}
(dest/'component-manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2))
print(f'Staged {len(components)} components; audited and signed {len(binaries)} Mach-O files')
