# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Group mapping integrity and a real archive using explicitly confirmed fixtures."""
import copy, json, os, subprocess, sys, tempfile
from pathlib import Path
ENGINE = Path(os.environ.get('COLDARCHIVE_TEST_ENGINE', str(Path(__file__).resolve().parents[1] / 'Sources/ColdArchive/Resources/Engine')))
sys.path.insert(0, str(ENGINE))
from provenance_answers import compile_answers
from bilingual_documents import provenance_value
with tempfile.TemporaryDirectory(prefix='coldarchive-grouped-') as tmp:
    root=Path(tmp).resolve(); source=root/'sources'; source.mkdir(); output=root/'output'; output.mkdir()
    files=[]
    for name in ['A1.txt','A2.txt','B1.txt']:
        path=source/name;path.write_text('Fixture only\n');files.append(str(path))
    def group(identifier,paths,answer,en=None):
        return {'group_id':identifier,'category':'测试文件','category_en':'Test files','files':paths,
                'response':{'status':'submitted','answer':answer, 'en':en}}
    fields=['source_type','device','source_software','purpose','notes']
    doc={'schema_version':3,'sources':[str(source)],'grouped_answers':{
        field:[group('a',files[:2], '无补充' if field=='notes' else '未知'),
               group('b',files[2:], '无补充' if field=='notes' else '不填写')] for field in fields}}
    doc['grouped_answers']['device'][0]['response']={'status':'submitted','answer':'设备 A','en':'Device A'}
    compiled=compile_answers(doc,[source])
    assert compiled['device_name']['groups'][0]['files']==files[:2]
    assert compiled['device_name']['groups'][1]['value']=={'state':'not_provided'}
    assert 'Device A' in provenance_value(compiled['device_name'],'en')
    assert '设备 A' not in provenance_value(compiled['device_name'],'en')
    for mutation in ['missing','overlap','foreign','unconfirmed','missing_question']:
        bad=copy.deepcopy(doc)
        if mutation=='missing':bad['grouped_answers']['device'][0]['files'].pop()
        if mutation=='overlap':bad['grouped_answers']['device'][1]['files'].append(files[0])
        if mutation=='foreign':bad['grouped_answers']['device'][1]['files']=['/tmp/unrelated']
        if mutation=='unconfirmed':bad['grouped_answers']['device'][1]['response']['status']='draft'
        if mutation=='missing_question':del bad['grouped_answers']['notes']
        try:compile_answers(bad,[source])
        except SystemExit:pass
        else:raise AssertionError(mutation+' accepted')
    answers=root/'answers.json';answers.write_text(json.dumps(doc,ensure_ascii=False))
    command=[sys.executable,'-B',str(ENGINE/'desktop_bridge.py'),str(source),'--archive-name','GroupedFixture','--output-dir',str(output),'--require-source-confirmation','--source-answers-json',str(answers)]
    result=subprocess.run(command,capture_output=True,text=True,timeout=120)
    assert result.returncode==0,result.stdout[-4000:]+result.stderr
    info=next(output.glob('*/Documents/SOURCE_INFO.md')).read_text()
    assert all(path in info for path in files)
    assert '设备 A' in info and 'Device A' in info and 'Not provided' in info
    assert 'EXTRACTION_SHA512 MATCH' in result.stdout and 'FINAL_BUNDLE_STRUCTURE PASS' in result.stdout
    print('PASS: per-group states, full mapping, missing/overlap/foreign/unconfirmed rejection, bilingual documents and complete archive recovery')
