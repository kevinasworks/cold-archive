# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Supplement ExifTool with ffprobe container/stream metadata, preserving raw tags."""
MEDIA_EXTENSIONS = {'.mp4', '.mov', '.m4v', '.avi', '.mkv', '.webm', '.mts', '.m2ts',
                    '.ts', '.mpg', '.mpeg', '.vob', '.dav', '.264', '.265', '.hevc',
                    '.mp3', '.wav', '.flac', '.aac', '.m4a', '.ogg', '.aiff'}
OPTIONS = ['-v', 'error', '-show_format', '-show_streams', '-show_chapters',
           '-show_programs', '-show_private_data', '-of', 'json']


def needed(path, rows, errors):
    return bool(errors) or path.suffix.lower() in MEDIA_EXTENSIONS or any(
        tag.rsplit(':', 1)[-1] == 'MIMEType' and str(value).startswith(('video/', 'audio/'))
        for row in rows for tag, value in row.items())


def suggestions(data, path):
    result = []
    def add(field, value, tag, raw=None, english=None, kind='metadata_value'):
        result.append(dict(field=field, value=value, en=english, file=str(path), tag=tag,
                           raw_value=raw if raw is not None else value, tool='ffprobe',
                           kind=kind, status='unconfirmed_metadata'))
    streams = data.get('streams', [])
    types = {stream.get('codec_type') for stream in streams}
    if 'video' in types or 'audio' in types:
        video = 'video' in types
        add('source_type', '视频文件' if video else '音频文件', 'streams.codec_type',
            'video' if video else 'audio', 'Video files' if video else 'Audio files', 'file_type_suggestion')
    scopes = [('format', data.get('format', {}))] + [(f'streams[{i}]', s) for i, s in enumerate(streams)]
    device = {'make': 'capture_device_make', 'model': 'capture_device_model',
              'com.apple.quicktime.make': 'capture_device_make',
              'com.apple.quicktime.model': 'capture_device_model',
              'com.android.manufacturer': 'capture_device_make',
              'com.android.model': 'capture_device_model',
              'camera_make': 'capture_device_make', 'camera_model': 'capture_device_model'}
    for scope, obj in scopes:
        for tag, value in obj.get('tags', {}).items():
            if not isinstance(value, str) or not value.strip():
                continue
            field = device.get(tag.lower())
            if tag.lower() in {'encoder', 'software', 'encoding_tool', 'com.apple.quicktime.software'}:
                field = 'creation_or_editing_software'
            if field:
                add(field, value, f'{scope}.tags.{tag}', english=value if value.isascii() else None)
    return result
