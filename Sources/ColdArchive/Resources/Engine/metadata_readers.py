# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Offline, metadata-only companion readers. Never open referenced external resources."""
import base64
import datetime
import ctypes
import errno
import sys
import hashlib
import os
from pathlib import Path
import plistlib
import posixpath
import shutil
import zipfile


def runtime_root():
    value = os.environ.get('COLDARCHIVE_RUNTIME')
    return Path(value) if value else None


def executable(name):
    root = runtime_root()
    if root:
        path = root / 'bin' / name
        return str(path) if path.is_file() and os.access(path, os.X_OK) else None
    return shutil.which(name)


def json_value(value):
    if isinstance(value, bytes):
        return {'encoding': 'base64', 'bytes': len(value), 'data': base64.b64encode(value).decode('ascii')}
    if isinstance(value, (datetime.datetime, datetime.date)):
        return {'type': type(value).__name__, 'value': value.isoformat()}
    if isinstance(value, dict):
        return {str(k): json_value(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [json_value(v) for v in value]
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    return str(value)


def attributes(path):
    if sys.platform != 'darwin':
        return [(n, os.getxattr(path,n,follow_symlinks=False)) for n in os.listxattr(path,follow_symlinks=False)]
    libc=ctypes.CDLL('/usr/lib/libSystem.B.dylib',use_errno=True)
    libc.listxattr.argtypes=[ctypes.c_char_p,ctypes.c_void_p,ctypes.c_size_t,ctypes.c_int]
    libc.listxattr.restype=ctypes.c_ssize_t
    libc.getxattr.argtypes=[ctypes.c_char_p,ctypes.c_char_p,ctypes.c_void_p,ctypes.c_size_t,ctypes.c_uint32,ctypes.c_int]
    libc.getxattr.restype=ctypes.c_ssize_t
    rawpath=os.fsencode(path)
    def read(call):
        while True:
            length=call(None,0)
            if length<0:raise OSError(ctypes.get_errno(),os.strerror(ctypes.get_errno()))
            buf=ctypes.create_string_buffer(length)
            got=call(buf,length)
            if got<0:
                if ctypes.get_errno()==errno.ERANGE:continue
                raise OSError(ctypes.get_errno(),os.strerror(ctypes.get_errno()))
            return buf.raw[:got]
    names=read(lambda b,n:libc.listxattr(rawpath,b,n,1)).split(b'\0')
    return [(os.fsdecode(name),read(lambda b,n:libc.getxattr(rawpath,name,b,n,0,1))) for name in names if name]


def filesystem_metadata(path):
    s = path.stat()
    data = {key: getattr(s, key) for key in ('st_mode','st_uid','st_gid','st_size','st_mtime_ns','st_ctime_ns','st_atime_ns','st_ino','st_dev','st_nlink')}
    for key in ('st_birthtime', 'st_flags'):
        if hasattr(s, key): data[key] = getattr(s, key)
    data['extended_attributes'] = []
    errors = []
    try:
        for name, raw in attributes(path):
            try:
                item = {'name': name, 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}
                # Resource forks and unknown attributes can contain file content.
                if name in {'com.apple.FinderInfo', 'com.apple.quarantine'}:
                    item['value'] = json_value(raw)
                elif name in {'com.apple.metadata:kMDItemWhereFroms','com.apple.metadata:_kMDItemUserTags'}:
                    item['value'] = json_value(plistlib.loads(raw))
                else:
                    item['status'] = 'opaque_attribute_not_interpreted'
                data['extended_attributes'].append(item)
            except (OSError, ValueError, plistlib.InvalidFileException) as e:
                errors.append(f'{name}: {e}')
    except OSError as e:
        errors.append(str(e))
    if sys.platform == 'darwin':
        # ACL_TYPE_EXTENDED from macOS sys/acl.h; this is the client-visible ACL.
        libc = ctypes.CDLL(None, use_errno=True)
        libc.acl_get_file.argtypes = [ctypes.c_char_p, ctypes.c_int]
        libc.acl_get_file.restype = ctypes.c_void_p
        libc.acl_to_text.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ssize_t)]
        libc.acl_to_text.restype = ctypes.c_void_p
        libc.acl_free.argtypes = [ctypes.c_void_p]
        acl = libc.acl_get_file(os.fsencode(path), 0x00000100)
        if acl:
            try:
                length = ctypes.c_ssize_t()
                text = libc.acl_to_text(acl, ctypes.byref(length))
                if text:
                    try: data['acl'] = {'scope':'macOS_client_visible', 'text':ctypes.string_at(text,length.value).decode('utf-8',errors='replace')}
                    finally: libc.acl_free(text)
                else: errors.append('ACL text unavailable: errno '+str(ctypes.get_errno()))
            finally: libc.acl_free(acl)
        else:
            number = ctypes.get_errno()
            if number == errno.ENOENT: data['acl'] = {'scope':'macOS_client_visible','status':'no_extended_acl'}
            else: errors.append('ACL unavailable: errno '+str(number))
    return data, errors


def xml_record(raw):
    from defusedxml import ElementTree as ET
    root = ET.fromstring(raw)
    def node(e):
        return {'name': e.tag, 'attributes': e.attrib, 'text': e.text,
                'tail': e.tail, 'children': [node(x) for x in e]}
    return {'raw': json_value(raw), 'tree': node(root)}


def document_metadata(path):
    """Return an explicit scoped reader result, never document text or pixel data."""
    with path.open('rb') as f: head = f.read(16)
    if head.startswith(b'PK') and zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as z:
            inventory = [{'name': i.filename, 'bytes': i.file_size, 'compressed_bytes': i.compress_size,
                          'compression': i.compress_type, 'flags': i.flag_bits, 'crc32': i.CRC,
                          'modified': list(i.date_time), 'extra': json_value(i.extra),
                          'comment': json_value(i.comment)} for i in z.infolist()]
            names = set(z.namelist())
            selected = {'docProps/core.xml','docProps/app.xml','docProps/custom.xml','meta.xml'} & names
            # Follow only package-level property relationships, never external links.
            if '_rels/.rels' in names:
                from defusedxml import ElementTree as ET
                for rel in ET.fromstring(z.read('_rels/.rels')):
                    if rel.get('TargetMode') == 'External': continue
                    if rel.get('Type','').rsplit('/',1)[-1] in {'metadata/core-properties','core-properties','extended-properties','custom-properties'}:
                        target = posixpath.normpath(rel.get('Target','').lstrip('/'))
                        if not target.startswith('../') and target in names: selected.add(target)
            if 'META-INF/container.xml' in names:
                from defusedxml import ElementTree as ET
                for e in ET.fromstring(z.read('META-INF/container.xml')).iter():
                    target = e.get('full-path')
                    if target in names: selected.add(target)
            records, errors = [], []
            for info in z.infolist():
                if info.filename not in selected: continue
                try:
                    records.append({'path': info.filename, 'header_offset': info.header_offset,
                                    **xml_record(z.read(info))})
                except Exception as e: errors.append(f'{info.filename}: {type(e).__name__}: {e}')
            return {'reader': 'zipfile+defusedxml', 'scope': 'container_directory_and_document_properties',
                    'members': inventory, 'comment': json_value(z.comment), 'properties': records,
                    'errors': errors}
    if head.startswith(b'\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1'):
        import olefile
        with olefile.OleFileIO(path, write_mode=False) as ole:
            props=[]
            for entry in ole.listdir():
                if entry[-1] in {'\x05SummaryInformation','\x05DocumentSummaryInformation'}:
                    values=ole.getproperties(entry)
                    # PIDSI_THUMBNAIL is actual preview data, not metadata.
                    if entry[-1]=='\x05SummaryInformation' and 17 in values:
                        v=values[17]; values[17]={'status':'thumbnail_payload_omitted','bytes':len(v) if isinstance(v,bytes) else None}
                    props.append({'path':entry,'properties':json_value(values)})
                    if entry[-1]=='\x05DocumentSummaryInformation':
                        props.append({'path':entry,'custom_properties':json_value(ole.get_userdefined_properties(entry))})
            return {'reader':'olefile','scope':'property_streams_only','properties':props,
                    'directory':ole.listdir(),'errors':[str(e) for e in ole.parsing_issues]}
    if head.startswith(b'%PDF-'):
        from pypdf import PdfReader
        from pypdf.generic import IndirectObject, StreamObject
        reader=PdfReader(path, strict=False)
        if reader.is_encrypted and not reader.decrypt(''):
            return {'reader':'pypdf','status':'encrypted','scope':'Info_and_catalog_XMP','errors':['Password required']}
        # Do not traverse page contents, fonts, attachments or annotation bodies.
        def safe(v, seen=None):
            seen=set() if seen is None else seen
            if isinstance(v,IndirectObject):
                key=(v.idnum,v.generation)
                if key in seen:return {'reference':list(key),'status':'cycle'}
                seen=seen|{key};return safe(v.get_object(),seen)
            if isinstance(v,StreamObject):return {'status':'non_metadata_stream_not_read'}
            if isinstance(v,dict):return {str(k):safe(x,seen) for k,x in v.items()}
            if isinstance(v,list):return [safe(x,seen) for x in v]
            return json_value(v)
        result={'reader':'pypdf','scope':'Info_and_catalog_XMP','info':safe(reader.trailer.get('/Info',{})), 'errors':[]}
        metadata=reader.trailer['/Root'].get('/Metadata')
        if metadata: result['xmp']=xml_record(metadata.get_object().get_data())
        return result
    return None


def private_structure(path):
    with path.open('rb') as f: header=f.read(32)
    if header.startswith(b'IMKH'):
        return {'family':'IMKH CCTV / MPEG-PS','signature':'494d4b48','offset':0,
                'status':'signature_recognized_structure_not_fully_decoded',
                'brand_hint':'Hikvision','brand_status':'associated_format_unverified_device',
                'role':'format_family','basis':'IMKH signature; not a device identity',
                'reference':'FFmpeg/libavformat/mpeg.c:mpegps_read_header'}
    if header.startswith(b'DAHUA') or (len(header)>=24 and header.startswith(b'DHAV') and header[4] in (0xf0,0xf1,0xfc,0xfd)):
        return {'family':'Dahua DHAV','signature':header[:5].hex(),'offset':0,
                'status':'signature_recognized_structure_not_fully_decoded',
                'brand_hint':'Dahua','brand_status':'associated_format_not_device',
                'role':'format_family','basis':'DAHUA or DHAV + recognized record type',
                'reference':'FFmpeg/libavformat/dhav.c:dhav_probe'}
    return None
