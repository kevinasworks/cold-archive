# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Exercise installed parsers against upstream samples and metadata/content boundaries."""
import json, os, subprocess, sys, tempfile, zipfile
from pathlib import Path
root=Path(__file__).resolve().parents[1]
engine=root/'Sources/ColdArchive/Resources/Engine'
runtime=Path(os.environ.get('COLDARCHIVE_RUNTIME',root/'vendor/runtime'))
sys.path.insert(0,str(engine))
from metadata_readers import document_metadata
from brand_evidence import collect
from metadata_candidates import candidates
assert not any(x['field'].startswith('capture_device') for x in candidates([{'SourceFile':'test.pdf','File:Main:FileType':'PDF','IFD0:Main:Make':'Canon'}]))
assert collect([{'IFD0:Make':'NIKON CORPORATION'}], 'x')[0]['brand']=='Nikon'
assert not collect([{'QuickTime:MajorBrand':'qt','System:FileName':'Sony.jpg'}],'x')
assert collect([{'File:Main:FileType':'PDF','IFD0:Make':'Canon'}],'x')[0]['role']=='document_device_reference'
with tempfile.TemporaryDirectory() as t:
    work=Path(t)
    doc=work/'document.docx'
    with zipfile.ZipFile(doc,'w') as z:
        z.writestr('_rels/.rels','<Relationships><Relationship Type="urn/test/custom-properties" Target="different/props.xml"/></Relationships>')
        z.writestr('different/props.xml','<properties><custom name="UnknownProperty">METADATA_SENTINEL</custom></properties>')
        z.writestr('word/document.xml','<body>CONTENT_MUST_NOT_BE_READ</body>')
    result=document_metadata(doc)
    text=json.dumps(result)
    assert 'METADATA_SENTINEL' in text and 'CONTENT_MUST_NOT_BE_READ' not in text
    from pypdf import PdfWriter
    pdf=work/'metadata.pdf';writer=PdfWriter();writer.add_blank_page(width=72,height=72);writer.add_metadata({'/Producer':'Fixture software','/UnusualField':'PDF_CUSTOM_SENTINEL'})
    with pdf.open('wb') as f:writer.write(f)
    data=document_metadata(pdf);assert data['info']['/UnusualField']=='PDF_CUSTOM_SENTINEL'
    xml=work/'bad.docx'
    with zipfile.ZipFile(xml,'w') as z:z.writestr('docProps/custom.xml','<!DOCTYPE a [<!ENTITY x SYSTEM "file:///etc/passwd">]><a>&x;</a>')
    assert document_metadata(xml)['errors']
    def extract(sample):
        report=work/(sample.stem+'.json')
        env={**os.environ,'COLDARCHIVE_RUNTIME':str(runtime),'PATH':str(runtime/'bin')+':/usr/bin:/bin:/usr/sbin:/sbin','PYTHONNOUSERSITE':'1','PYTHONDONTWRITEBYTECODE':'1'}
        subprocess.run([str(runtime/'python/bin/python3'),'-B',str(engine/'inspect_source_metadata.py'),str(sample),'--output-json',str(report)],env=env,check=True,stdout=subprocess.DEVNULL)
        return json.loads(report.read_text())
    corpus=root/'vendor/src/exiftool-13.55/t/images'
    for sample,brand in [('Canon.jpg','Canon'),('Nikon.jpg','Nikon'),('Sony.jpg','Sony'),('Apple.jpg','Apple'),('GoPro.jpg','GoPro'),('FLIR.jpg','FLIR Systems AB'),('FujiFilm.jpg','Fujifilm'),('Olympus.jpg','OLYMPUS OPTICAL CO.,LTD')]:
        r=extract(corpus/sample)
        assert r['attempted_file_count']==1
        declared=[x['brand'] for x in r['brand_findings'] if x['role']=='capture_device']
        assert brand in declared,(sample,declared)
        assert r['files'][0]['format_identification']['data']['siegfried']=='1.11.9'
        for b in r['files'][0]['binary_metadata']['data']['fields']:
            if b['status']!='binary_metadata_retained':assert 'data' not in b
    r=extract(corpus/'DICOM.dcm')
    fields=r['files'][0]['binary_metadata']['data']['fields']
    assert any(b['tag']=='PixelData' and b['status']=='content_payload_omitted' and 'data' not in b for b in fields)
    r=extract(corpus/'PDF.pdf')
    assert not any(x['role']=='capture_device' for x in r['brand_findings'])
print('PASS: 8 upstream camera brands, DICOM pixel exclusion, PDF device scope, offline identification, relocated properties, unknown properties, external entity rejection, no document body')
