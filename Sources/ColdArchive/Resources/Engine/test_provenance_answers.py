# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Regression for real field choices, missing answers, and output mismatches."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from provenance_answers import compile_answers, validate_source_answers
from bilingual_documents import provenance_value

def main():
    with tempfile.TemporaryDirectory() as temp:
        root=Path(temp);source=root/'Disks.csv';source.write_text('a,b\n1,2');out=root/'out';out.mkdir()
        doc={'schema_version':2,'sources':[str(source.resolve())],'answers':{
            'source_type':{'answer':'CSV 数据文件','en':'CSV data file'},
            'device':{'answer':'未知／不填写'},'source_software':{'answer':'未知／不填写'},
            'purpose':{'answer':'测试','en':'Test'},'notes':{'answer':'无补充'}}}
        for record in doc['answers'].values():
            record['status']='submitted'
        values=compile_answers(doc,[source]);assert values['source_type']['zh']=='CSV 数据文件';assert values['purpose']['zh']=='测试'
        assert values['device_name']['state']==values['device_model']['state']==values['source_software']['state']=='unknown'
        for question in doc['answers']:
            bad=copy.deepcopy(doc);del bad['answers'][question]
            try:compile_answers(bad,[source])
            except SystemExit:pass
            else:raise AssertionError('Missing answer accepted: '+question)
        bad=copy.deepcopy(doc);bad['sources']=[str(root/'another.csv')]
        try:compile_answers(bad,[source])
        except SystemExit:pass
        else:raise AssertionError('Unrelated source accepted')
        answers=root/'answers.json';answers.write_text(json.dumps(doc,ensure_ascii=False))
        helper=Path(__file__).with_name('create_archive_bundle.py')
        cmd=[sys.executable,'-B',str(helper),str(source),'--archive-name','Disks.csv','--output-dir',str(out),'--require-source-confirmation']
        r=subprocess.run(cmd,capture_output=True,text=True);assert r.returncode and not list(out.iterdir())
        r=subprocess.run(cmd[:-1],capture_output=True,text=True);assert r.returncode and not list(out.iterdir())
        # Exercise the real CLI gate, including a default value with no actual submission.
        for question in doc['answers']:
            for state in [None, 'pending', 'prefilled', 'skipped', 'cancelled']:
                bad=copy.deepcopy(doc)
                if state is None: bad['answers'][question].pop('status')
                else: bad['answers'][question]['status']=state
                answers.write_text(json.dumps(bad,ensure_ascii=False))
                blocked=subprocess.run(cmd+['--source-answers-json',str(answers)],capture_output=True,text=True)
                assert blocked.returncode and 'SOURCE_CONFIRMATION_PENDING' in blocked.stderr
                assert 'PHASE 1' not in blocked.stdout and not list(out.iterdir())
            bad=copy.deepcopy(doc);del bad['answers'][question]
            answers.write_text(json.dumps(bad,ensure_ascii=False))
            blocked=subprocess.run(cmd+['--source-answers-json',str(answers)],capture_output=True,text=True)
            assert blocked.returncode and 'PHASE 1' not in blocked.stdout and not list(out.iterdir())
        bad=copy.deepcopy(doc);bad['schema_version']=1
        try: compile_answers(bad,[source])
        except SystemExit: pass
        else: raise AssertionError('Legacy record accepted')
        answers.write_text(json.dumps(doc,ensure_ascii=False))
        r=subprocess.run(cmd+['--source-answers-json',str(answers)],capture_output=True,text=True)
        assert r.returncode==0,(r.stdout+r.stderr)[-2000:]
        text=next(out.glob('*/Documents/SOURCE_INFO.md')).read_text();validate_source_answers(text,values,provenance_value)
        zh,en=text.split('## English',1)
        assert '### 来源类别\n\nCSV 数据文件' in zh
        assert '### 此归档的用途\n\n测试' in zh
        assert '### 备注\n\n无补充' in zh
        assert '### Notes\n\nNo additional notes' in en
        for old,new in [('CSV 数据文件','测试'),('不清楚','未提供'),('无补充','无补充。ExifTool 检查记录')]:
            corrupted=text.replace(old,new,1)
            try:validate_source_answers(corrupted,values,provenance_value)
            except SystemExit:pass
            else:raise AssertionError('Corruption accepted: '+old)
        for answer in ['自由填写', ' 自由填写 ', '', '未知／不填写', ' 未知／不填写 ']:
            bad=copy.deepcopy(doc);bad['answers']['notes']={'answer':answer,'status':'submitted','en':'Custom'}
            try:compile_answers(bad,[source])
            except SystemExit:pass
            else:raise AssertionError('Incomplete notes accepted')
        print('PASS: exact five choices, missing answers blocked, source binding, full archive workflow, category/purpose swap, unknown loss and note contamination rejected')
if __name__=='__main__':main()
