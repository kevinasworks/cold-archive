# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Prepare the pinned macOS runtime in a clean source checkout, without installers."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
DOWNLOADS = ROOT / 'vendor/downloads'
RUNTIME = ROOT / 'vendor/runtime'
SOURCE = ROOT / 'vendor/src'


def extract_tar(name, destination):
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(DOWNLOADS / name) as archive:
        archive.extractall(destination, filter='data')


def extract_zip(path, destination):
    destination.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path) as archive:
        for member in archive.infolist():
            relative = Path(member.filename)
            if relative.is_absolute() or '..' in relative.parts:
                raise RuntimeError('Unsafe ZIP entry: ' + member.filename)
            archive.extract(member, destination)


def run(command, **kwargs):
    subprocess.run([str(x) for x in command], check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepare', action='store_true', help='expand and build in this clean checkout')
    parser.add_argument('--fetch', action='store_true', help='also download missing pinned archives')
    args = parser.parse_args()
    if not args.prepare:
        print('Plan: verify pinned inputs; build 7zz, FFprobe and Perl; expand Python, wheels, ExifTool, Archive::Zip, MediaInfo and Siegfried; create relative launchers.')
        print('Use --prepare in a clean source checkout. Existing executable runtimes are never overwritten.')
        return
    if sys.platform != 'darwin' or os.uname().machine != 'arm64':
        parser.exit(1, 'This pinned runtime recipe targets macOS arm64.\n')
    if not hasattr(tarfile, 'data_filter'):
        parser.exit(1, 'Use Python 3.12+ (or a Python release with tarfile.data_filter); no automatic installation is performed.\n')
    if any(p.exists() for p in [RUNTIME/'bin/7zz', RUNTIME/'python/bin/python3', RUNTIME/'perl/bin/perl', RUNTIME/'siegfried/sf']):
        parser.exit(1, 'Existing executable runtime detected; use a clean source checkout. No files changed.\n')
    fetch = [sys.executable, '-B', ROOT/'scripts/fetch-runtime.py']
    if args.fetch:
        fetch.append('--fetch')
    run(fetch)
    (ROOT/'QA/components').mkdir(parents=True, exist_ok=True)
    (RUNTIME/'bin').mkdir(parents=True, exist_ok=True)
    extract_tar('7z2603-src.tar.xz', SOURCE/'7zip-26.03')
    seven_source = SOURCE/'7zip-26.03/CPP/7zip/Bundles/Alone2'
    env = {**os.environ, 'MACOSX_DEPLOYMENT_TARGET': '14.0'}
    run(['make', '-C', seven_source, '-f', '../../cmpl_mac_arm64.mak', 'DISABLE_RAR_COMPRESS=1', '-j6'], env=env)
    seven = RUNTIME/'bin/7zz'
    shutil.copy2(seven_source/'b/m_arm64/7zz', seven)
    seven.chmod(0o755)
    extract_tar('ffmpeg.tar.xz', SOURCE)
    run([sys.executable, '-B', ROOT/'scripts/build-native-tools.py'])
    extract_tar('python.tar.gz', RUNTIME)
    site = RUNTIME/'python/lib/python3.13/site-packages'
    for wheel in sorted((DOWNLOADS/'wheels').glob('*.whl')):
        extract_zip(wheel, site)
    extract_tar('exiftool-source.tar.gz', SOURCE)
    extract_tar('archive-zip.tar.gz', SOURCE)
    exif = RUNTIME/'exiftool'
    shutil.copytree(SOURCE/'exiftool-13.55/lib', exif, dirs_exist_ok=True)
    shutil.copy2(SOURCE/'exiftool-13.55/exiftool', exif/'exiftool')
    shutil.copytree(SOURCE/'Archive-Zip-1.68/lib', exif, dirs_exist_ok=True)
    extract_zip(DOWNLOADS/'sf.zip', RUNTIME/'siegfried')
    extract_zip(DOWNLOADS/'sf-data.zip', RUNTIME/'siegfried/data')
    (RUNTIME/'siegfried/sf').chmod(0o755)
    (RUNTIME/'siegfried/roy').chmod(0o755)
    with tempfile.TemporaryDirectory(prefix='cold-mediainfo-expand-') as directory:
        temporary = Path(directory)
        run([seven, 'x', DOWNLOADS/'mediainfo.dmg', 'MediaInfo/mediainfo.pkg', '-o'+str(temporary), '-y'])
        # Expand the package without executing installer scripts or installing it.
        expanded = temporary/'expanded'
        run(['/usr/sbin/pkgutil', '--expand-full', temporary/'MediaInfo/mediainfo.pkg', expanded])
        matches = [p for p in expanded.rglob('mediainfo') if p.is_file() and p.parent.name == 'bin']
        if len(matches) != 1:
            raise RuntimeError('Expected exactly one official MediaInfo CLI payload')
        (RUNTIME/'mediainfo').mkdir(parents=True, exist_ok=True)
        shutil.copy2(matches[0], RUNTIME/'mediainfo/mediainfo')
    targets = {'python3':'python/bin/python3', 'perl':'perl/bin/perl', 'ffprobe':'media/bin/ffprobe', 'mediainfo':'mediainfo/mediainfo', 'sf':'siegfried/sf'}
    for name, target in targets.items():
        wrapper = RUNTIME/'bin'/name
        wrapper.write_text('#!/bin/sh\n# SPDX-License-Identifier: GPL-3.0-only\nbase="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"\nexec "$base/'+target+'" "$@"\n')
        wrapper.chmod(0o755)
    wrapper = RUNTIME/'bin/exiftool'
    wrapper.write_text('#!/bin/sh\n# SPDX-License-Identifier: GPL-3.0-only\nbase="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"\nexec "$base/perl/bin/perl" -I"$base/exiftool" "$base/exiftool/exiftool" "$@"\n')
    wrapper.chmod(0o755)
    print('Prepared local runtime. Rebuilt binaries require fresh review before formal release; known licensing gates remain active.')


if __name__ == '__main__':
    main()
