# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Evidence-backed form suggestions, separate from the full metadata record."""
DEVICE = {'Make': 'capture_device_make', 'Model': 'capture_device_model',
          'CameraMake': 'capture_device_make', 'CameraModel': 'capture_device_model',
          'CameraModelName': 'capture_device_model', 'CameraModelID': 'capture_device_model'}
# Only known namespaces may describe the outer capture device.
DEVICE_GROUPS = {'IFD0', 'ExifIFD', 'EXIF', 'XMP-tiff', 'XMP-exif',
                 'Keys', 'UserData', 'QuickTime', 'DICOM', 'FLIR', 'DJI',
                 'Canon', 'Nikon', 'Sony', 'FujiFilm', 'Panasonic', 'Olympus',
                 'Pentax', 'Ricoh', 'Samsung', 'Apple', 'GoPro', 'Insta360'}
DEVICE.update(AndroidMake='capture_device_make', AndroidModel='capture_device_model')

def device_field(tag):
    parts = tag.split(':')
    group, name = parts[0], parts[-1]
    if group not in DEVICE_GROUPS:
        return None
    if any(p.startswith('Doc') and p[3:].isdigit() for p in parts[:-1]):
        return None
    if group == 'DICOM':
        return {'Manufacturer': 'capture_device_make',
                'ManufacturerModelName': 'capture_device_model'}.get(name)
    if name in {'AndroidMake', 'AndroidModel'} and group not in {'Keys', 'QuickTime'}:
        return None
    return DEVICE.get(name)

SOFTWARE = {'Software', 'CreatorTool', 'Encoder', 'EncodingSoftware', 'WritingApplication',
            'MuxingApp', 'WritingApp', 'EncodedBy', 'EncodingLibrary', 'CompressorName'}
TYPES = {
    'CSV': ('CSV 数据文件', 'CSV data files'),
    'TSV': ('TSV 数据文件', 'TSV data files'),
    'XLS': ('电子表格', 'Spreadsheets'), 'XLSX': ('电子表格', 'Spreadsheets'),
    'PDF': ('PDF 文档', 'PDF documents'),
    'DOC': ('文字文档', 'Text documents'), 'DOCX': ('文字文档', 'Text documents'),
    'TXT': ('文本文件', 'Text files'), 'JSON': ('JSON 数据文件', 'JSON data files'),
    'XML': ('XML 数据文件', 'XML data files'),
    'ZIP': ('压缩包', 'Compressed archives'), '7Z': ('压缩包', 'Compressed archives'),
}
MIME_TYPES = {'text/csv': TYPES['CSV'], 'text/tab-separated-values': TYPES['TSV'],
              'application/pdf': TYPES['PDF'], 'application/json': TYPES['JSON']}


def classify(value, mime=False):
    key = value.lower() if mime else value.upper()
    if mime:
        if key in MIME_TYPES:
            return MIME_TYPES[key]
        for prefix, names in [('image/', ('图像文件', 'Image files')),
                              ('video/', ('视频文件', 'Video files')),
                              ('audio/', ('音频文件', 'Audio files'))]:
            if key.startswith(prefix):
                return names
        return None
    if key in TYPES:
        return TYPES[key]
    if key in {'JPEG', 'PNG', 'HEIC', 'HEIF', 'TIFF', 'GIF', 'WEBP', 'DNG', 'CR2', 'CR3', 'NEF', 'ARW', 'RAF'}:
        return ('图像文件', 'Image files')
    if key in {'MP4', 'MOV', 'AVI', 'MKV', 'M2TS', 'MTS', 'WEBM'}:
        return ('视频文件', 'Video files')
    if key in {'MP3', 'WAV', 'FLAC', 'AAC', 'M4A', 'OGG'}:
        return ('音频文件', 'Audio files')
    return None


DOCUMENT_TYPES = {'PDF','DOC','DOCX','XLS','XLSX','PPT','PPTX','ZIP','7Z','EPUB','ODT','ODS','ODP'}

def document_context(row):
    return any(k.rsplit(':',1)[-1]=='FileType' and str(v).upper() in DOCUMENT_TYPES
               and not any(p.startswith('Doc') and p[3:].isdigit() for p in k.split(':')[:-1])
               for k,v in row.items())


def candidates(rows, source=None):
    result = []
    seen = set()
    for row in rows:
        filename = source or row.get('SourceFile')
        if not filename:
            continue
        for tag, raw in row.items():
            name = tag.rsplit(':', 1)[-1]
            # Never stringify objects or arrays into fabricated device identities.
            if not isinstance(raw, (str, int, float)) or isinstance(raw, bool):
                continue
            value = str(raw).strip()
            if not value:
                continue
            field = device_field(tag)
            if field and document_context(row):
                field = field.replace("capture_device", "document_device_reference")
            english = value if value.isascii() else None
            kind = 'metadata_value'
            suggested = value
            if (name in SOFTWARE or (name in {'Creator', 'Producer'} and tag.split(':')[0] == 'PDF')) and not any(p.startswith('Doc') and p[3:].isdigit() for p in tag.split(':')[:-1]):
                field = 'creation_or_editing_software'
            if name in {'FileType', 'MIMEType'}:
                # Embedded documents describe their own types, not the outer file.
                if any(part.startswith('Doc') and part[3:].isdigit() for part in tag.split(':')[:-1]):
                    continue
                suggestion = classify(value, mime=name == 'MIMEType')
                if suggestion:
                    field = 'source_type'; suggested, english = suggestion
                    kind = 'file_type_suggestion'
                elif name == 'FileType':
                    field = 'source_type'; suggested = value + ' 格式文件'; english = value + ' format files'
                    kind = 'file_type_suggestion'
            if not field:
                continue
            key = (field, suggested, filename, tag)
            if key in seen:
                continue
            seen.add(key)
            result.append({'field': field, 'value': suggested, 'en': english, 'file': filename,
                           'tag': tag, 'raw_value': value, 'tool': 'exiftool', 'kind': kind,
                           'role': 'capture_device' if field.startswith('capture_device') else ('software' if 'software' in field else 'file_type'),
                           'basis': 'explicit_metadata', 'status': 'unconfirmed_metadata'})
    return result
