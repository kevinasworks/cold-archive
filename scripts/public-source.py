# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Review or export an explicit source-only publication set; never access GitHub."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil

ROOT = Path(__file__).resolve().parents[1]
ROOT_FILES = ('.gitignore', 'LICENSE', 'README.md', 'OPEN_SOURCE.md', 'Package.swift', 'THIRD_PARTY_NOTICES.md')
CODE_SUFFIXES = {'.swift', '.c', '.h', '.py', '.pl', '.sh', '.md', '.json', '.config', '.txt'}
PRIVATE_NAMES = {'signing-policy.json', '.DS_Store', '.env'}


def candidates():
    result = {ROOT / name for name in ROOT_FILES}
    for directory in ('Sources', 'Tests', 'scripts', 'Assets'):
        for p in (ROOT / directory).rglob('*'):
            if not p.is_file() or '__pycache__' in p.parts:
                continue
            if p.name in PRIVATE_NAMES or p.name.startswith('.env.') or p.suffix == '.pyc':
                continue
            if directory == 'scripts' and p.suffix == '.json' and p.name not in {'public-source.json', 'signing-policy.example.json', 'runtime-sources.json'}:
                continue
            if p.suffix in CODE_SUFFIXES or (directory == 'Assets' and p.suffix in {'.png', '.icns'}):
                result.add(p)
    policy = json.loads((ROOT / 'vendor/compliance/release-materials.json').read_text())
    # Include only license/attribution files, never runtime code or data snapshots.
    for relative in policy['licenses']:
        if relative.endswith('/vendor.txt'):
            continue
        result.add(ROOT / 'vendor' / relative)
    for name in ('release-materials.json', 'sevenzip-26.03.rb', 'siegfried-1.11.9-gen.go'):
        result.add(ROOT / 'vendor/compliance' / name)
    result.add(ROOT / 'vendor/downloads/sources.json')
    result.add(ROOT / 'QA/Fixture/测试.txt')
    return sorted(result)


def audit():
    errors = []
    config = json.loads((ROOT / 'scripts/public-source.json').read_text())
    files = candidates()
    license_path = ROOT / 'LICENSE'
    if not license_path.is_file() or hashlib.sha256(license_path.read_bytes()).hexdigest() != '3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986':
        errors.append('LICENSE 不匹配已核验 GNU GPLv3 原文')
    for p in files:
        relative = p.relative_to(ROOT).as_posix()
        if not p.is_file() or p.is_symlink():
            errors.append('公开材料缺失或不是普通文件：' + relative)
            continue
        data = p.read_bytes()
        if data[:4] in {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\x7fELF'} or data[:2] == b'MZ':
            errors.append('禁止公开预编译程序：' + relative)
        if p.suffix in {'.png', '.icns'}:
            continue
        text = data.decode('utf-8', 'replace')
        # High-confidence credential patterns, not generic test-fixture words.
        if re.search(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|\bAKIA[A-Z0-9]{16}\b|\bgh[pousr]_[A-Za-z0-9]{30,}\b', text):
            errors.append('疑似真实凭据，需人工核查：' + relative)
        unresolved_engine = 'Engine' in p.parts and any('Resources/Engine' in item for item in config['pending_rights'])
        if p.suffix in {'.swift', '.c', '.h', '.py', '.pl', '.sh'} and not unresolved_engine and not relative.startswith('vendor/'):
            if 'SPDX-License-Identifier: GPL-3.0-only' not in text:
                errors.append('原创代码缺少 SPDX：' + relative)
    return files, errors + config['pending_rights']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--list', action='store_true', help='list proposed public files without exporting')
    output = parser.add_mutually_exclusive_group()
    output.add_argument('--output', type=Path, help='export only after all source-publication checks pass')
    output.add_argument('--verify-output', type=Path, help='verify an already staged source set against this checkout')
    args = parser.parse_args()
    files, errors = audit()
    if args.list:
        for path in files:
            print(path.relative_to(ROOT))
    if errors:
        parser.exit(1, '源码公开检查未通过：\n' + '\n'.join('  - ' + e for e in errors) + '\n')
    if args.verify_output:
        destination = args.verify_output.resolve()
        expected = {p.relative_to(ROOT).as_posix() for p in files}
        actual = {p.relative_to(destination).as_posix() for p in destination.rglob('*') if p.is_file() or p.is_symlink()}
        if expected != actual:
            parser.exit(1, '随包项目源码文件集合与公开清单不一致。\n')
        for source in files:
            target = destination / source.relative_to(ROOT)
            if target.is_symlink() or target.read_bytes() != source.read_bytes():
                parser.exit(1, '随包项目源码不一致：' + str(source.relative_to(ROOT)) + '\n')
    if args.output:
        destination = args.output.resolve()
        if destination.exists() or destination == ROOT or ROOT in destination.parents:
            parser.exit(1, '输出必须是项目目录以外的新目录，不能覆盖现有目录。\n')
        destination.mkdir(parents=True)
        for path in files:
            target = destination / path.relative_to(ROOT)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)
    print(f'PASS: source-only publication set ({len(files)} files); app-runtime gate remains independent')


if __name__ == '__main__':
    main()
