# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Fetch exact runtime inputs for local builds; never install or publish anything."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fetch', action='store_true', help='download missing inputs; default only checks cache')
    parser.add_argument('--cache', type=Path, default=ROOT / 'vendor/downloads')
    args = parser.parse_args()
    records = json.loads((ROOT / 'scripts/runtime-sources.json').read_text())['downloads']
    missing = []
    for name, record in records.items():
        path = args.cache / name
        if path.is_file():
            if digest(path) != record['sha256']:
                parser.exit(1, f'哈希不符，拒绝覆盖现有材料：{name}\n')
            continue
        if not args.fetch:
            missing.append(name)
            continue
        url = record.get('url')
        if url is None:
            endpoint = f"https://pypi.org/pypi/{record['pypi_project']}/{record['version']}/json"
            with urllib.request.urlopen(endpoint, timeout=30) as response:
                release = json.load(response)
            matches = [item for item in release['urls'] if item['filename'] == path.name and item['digests']['sha256'] == record['sha256']]
            if len(matches) != 1:
                parser.exit(1, f'PyPI 固定版本文件或哈希不匹配：{name}\n')
            url = matches[0]['url']
        if not url.startswith('https://'):
            parser.exit(1, f'拒绝非 HTTPS 来源：{name}\n')
        path.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix='.fetch-', delete=False) as temporary:
            staged = Path(temporary.name)
            try:
                with urllib.request.urlopen(url, timeout=30) as response:
                    for chunk in iter(lambda: response.read(1024 * 1024), b''):
                        temporary.write(chunk)
                temporary.flush()
                if digest(staged) != record['sha256']:
                    parser.exit(1, f'下载哈希不符，未接受文件：{name}\n')
                # Do not overwrite a file created concurrently.
                os.link(staged, path)
            finally:
                staged.unlink(missing_ok=True)
        print('Verified:', name)
    if missing:
        parser.exit(1, '缺少固定版本输入（使用 --fetch 获取）：\n' + '\n'.join(missing) + '\n')
    print(f'PASS: {len(records)} pinned runtime inputs verified; no installation performed')


if __name__ == '__main__':
    main()
