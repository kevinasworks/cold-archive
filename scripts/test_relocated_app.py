# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Exercise copied production engine with no user-installed runtime or network."""
import json, os, shutil, subprocess, tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='coldarchive-relocation-') as tmp:
    base=Path(tmp); app=base/'换台 Mac 离线 验证'/'冷归档.app'
    shutil.copytree(Path(os.environ.get('COLD_ARCHIVE_TEST_APP', ROOT/'dist/冷归档 2.0.13.app')),app,symlinks=True)
    resources=app/'Contents/Resources'; runtime=resources/'Runtime'; engine=resources/'Engine'
    home=base/'empty-home'; home.mkdir()
    env={'HOME':str(home),'PATH':str(runtime/'bin')+':/usr/bin:/bin:/usr/sbin:/sbin','TMPDIR':str(base),'COLDARCHIVE_RUNTIME':str(runtime),'PYTHONDONTWRITEBYTECODE':'1','PYTHONNOUSERSITE':'1','LANG':'en_US.UTF-8'}
    budget=base/'write-budget'; budget.mkdir()
    for i in range(64): (budget/str(i)).touch(mode=0o600)
    (budget/"limit").write_text("1")
    read_budget=budget/'reading'; read_budget.mkdir()
    for i in range(64): (read_budget/str(i)).touch(mode=0o600)
    (read_budget/'limit').write_text('1')
    temp_budget=budget/'temporary'; temp_budget.mkdir()
    for i in range(5): (temp_budget/str(i)).touch()
    (temp_budget/'limit').write_text('5')
    env['COLD_ARCHIVE_LOCAL_TEMP_DEVICE']=str(base.stat().st_dev)
    env['COLD_ARCHIVE_WRITE_BUDGET']=str(budget)
    prefix=['/usr/bin/sandbox-exec','-p','(version 1)(allow default)(deny network*)',str(runtime/'python/bin/python3'),'-B']
    def run(args):
        r=subprocess.run(prefix+args,env=env,text=True,capture_output=True,timeout=180)
        assert r.returncode==0,r.stdout[-4000:]+r.stderr[-4000:]
        return r.stdout
    source=base/'输入 文件'; source.mkdir()
    fixtures=ROOT/'vendor/src/exiftool-13.55/t/images'
    for name in ['Canon.jpg','Nikon.jpg','Sony.jpg','PDF.pdf']:
        shutil.copy2(fixtures/name,source/name)
    report=base/'report.json'
    run([str(engine/'inspect_source_metadata.py'),str(source),'--output-json',str(report)])
    data=json.loads(report.read_text()); assert len(data['files'])==4 and not data['errors']
    output=base/'归档 输出'; output.mkdir()
    code='''import sys\nfrom pathlib import Path\nsys.path[:0]=[sys.argv[1],sys.argv[4]]\nfrom test_answer_fixture import fixture_args\nimport subprocess\nr=subprocess.run([sys.executable,"-B",sys.argv[1]+"/desktop_bridge.py",sys.argv[2],"--archive-name","离线验证","--output-dir",sys.argv[3],"--require-source-confirmation",*fixture_args([Path(sys.argv[2])])])\nraise SystemExit(r.returncode)'''
    result=run(['-c',code,str(engine),str(source),str(output),str(ROOT/'Sources/ColdArchive/Resources/Engine')])
    assert '"completed"' in result,result[-2000:]
    print(result)
    print('PASS: copied app, Chinese/space path, empty HOME, no Homebrew PATH, network denied, 4-file metadata, complete archive and real recovery')
