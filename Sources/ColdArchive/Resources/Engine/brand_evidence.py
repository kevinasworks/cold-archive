# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Derive brand evidence from parsed metadata, never file names or media content."""
import re
from metadata_candidates import device_field, document_context

ALIASES = {'canon':'Canon','canon inc.':'Canon','nikon':'Nikon','nikon corporation':'Nikon',
           'sony':'Sony','sony corporation':'Sony','fujifilm':'Fujifilm','fujifilm corporation':'Fujifilm',
           'apple':'Apple','apple inc.':'Apple','samsung':'Samsung','samsung electronics':'Samsung',
           'dji':'DJI','sz dji technology co., ltd.':'DJI','gopro':'GoPro','insta360':'Insta360',
           'panasonic':'Panasonic','olympus':'Olympus','olympus corporation':'Olympus',
           'ricoh':'Ricoh','pentax':'Pentax','leica':'Leica','flir':'FLIR',
           'huawei':'Huawei','xiaomi':'Xiaomi','oppo':'OPPO','vivo':'vivo','oneplus':'OnePlus',
           'google':'Google','hasselblad':'Hasselblad','axis':'Axis','dahua':'Dahua','hikvision':'Hikvision'}
FAMILIES = {'Canon','Nikon','Sony','FujiFilm','Panasonic','Olympus','Pentax','Ricoh','Leica',
            'Samsung','Apple','DJI','GoPro','Insta360','FLIR','Hasselblad','Reconyx','Kodak'}


def collect(rows, path, media=None, companions=None):
    out=[];seen=set()
    def add(brand,role,basis,tag,raw,tool='exiftool',scope='main',status='file_declared'):
        if not isinstance(raw,(str,int,float)) or isinstance(raw,bool) or not str(raw).strip():return
        brand=ALIASES.get(str(brand).strip().casefold(),str(brand).strip())
        key=(brand,role,tag,scope,tool)
        if key in seen:return
        seen.add(key)
        out.append(dict(brand=brand,role=role,basis=basis,tag=tag,raw_value=str(raw),tool=tool,
                        file=str(path),scope=scope,status=status,rule_version='brand-evidence-1'))
    for row in rows:
        for tag,raw in row.items():
            parts=tag.split(':');group=parts[0];name=parts[-1]
            scope=next((p for p in parts if re.fullmatch(r'Doc\d+',p)), 'main')
            unscoped=':'.join(p for p in parts if not re.fullmatch(r'Doc\d+',p))
            if device_field(unscoped)=='capture_device_make':
                add(raw,'document_device_reference' if document_context(row) else 'capture_device','explicit_manufacturer',tag,raw,scope=('document_or_embedded_reference' if document_context(row) and scope=='main' else scope))
            if group in {'ExifIFD','XMP-exifEX','XMP-aux'} and name=='LensMake':
                add(raw,'lens','explicit_manufacturer',tag,raw,scope=scope)
            # A decoder namespace is only a format-family clue, not an identity.
            if group in FAMILIES and name not in {'Warning','Error'}:
                add(group,'format_family','parser_namespace_not_independent_identity',group,group,
                    scope=scope,status='associated_format')
    for location,obj in [('format',(media or {}).get('format',{}))]+[(f'streams[{i}]',x) for i,x in enumerate((media or {}).get('streams',[]))]:
        for key,raw in obj.get('tags',{}).items():
            if key.lower() in {'make','camera_make','com.apple.quicktime.make','com.android.manufacturer'}:
                add(raw,'capture_device','explicit_manufacturer',location+'.tags.'+key,raw,'ffprobe',location)
    companions=companions or {}
    for i,track in enumerate(companions.get('mediainfo',{}).get('data',{}).get('media',{}).get('track',[])):
        for key,role in [('Encoded_Hardware_CompanyName','encoding_device'),('Encoded_Application_CompanyName','software')]:
            if key in track:add(track[key],role,'explicit_company',f'track[{i}].{key}',track[key],'mediainfo',f'track[{i}]')
    hint=companions.get('private_format')
    if hint:
        add(hint['brand_hint'],'format_family',hint['basis'],'header.signature',hint['signature'],
            'private_signature',status=hint['brand_status'])
    return out
