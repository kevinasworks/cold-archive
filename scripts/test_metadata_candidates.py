# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Candidate semantics: factual tags, suggestions and unsupported fields."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/ColdArchive/Resources/Engine'))
from metadata_candidates import candidates

def rows(tags): return [{'SourceFile': '/synthetic/file', **tags}]
for kind, expected in [('CSV', 'CSV 数据文件'), ('PDF', 'PDF 文档'), ('JPEG', '图像文件'), ('MP4', '视频文件'), ('FLAC', '音频文件'), ('UNKNOWN-FORMAT', 'UNKNOWN-FORMAT 格式文件')]:
    c = candidates(rows({'File:Main:FileType': kind}))
    assert c[0]['value'] == expected and c[0]['kind'] == 'file_type_suggestion'
    assert c[0]['raw_value'] == kind and c[0]['en']
assert candidates(rows({'File:MIMEType': 'text/csv'}))[0]['value'] == 'CSV 数据文件'
assert not candidates(rows({'XMP:Creator': 'A person', 'System:FileName': 'photo.jpg', 'QuickTime:HandlerDescription': 'Apple media handler'}))
assert not candidates(rows({'File:Doc1:FileType': 'JPEG'}))
assert not candidates(rows({'IFD0:Make': '', 'IFD0:Model': {'unexpected': 'object'}}))
assert candidates(rows({'PDF:Creator': 'Example editor'}))[0]['field'] == 'creation_or_editing_software'
assert candidates(rows({'IFD0:Model': '中文型号'}))[0]['en'] is None
mixed = candidates([{'SourceFile':'/synthetic/a','IFD0:Model':'Camera A'}, {'SourceFile':'/synthetic/b','IFD0:Model':'Camera B'}])
assert len(mixed)==2 and {c['file'] for c in mixed}=={'/synthetic/a','/synthetic/b'}
assert all(c['field'] not in {'purpose','notes'} for c in mixed)
print('PASS: formats, MIME fallback, explicit suggestions, embedded-document exclusion, person/handler rejection, non-scalar rejection, mixed mappings, no fabricated translation')
