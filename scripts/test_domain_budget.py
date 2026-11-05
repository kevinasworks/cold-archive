# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Real Python per-device admission, alias, drain and failure cleanup tests."""
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time

ENGINE = Path(__file__).resolve().parents[1] / 'Sources/ColdArchive/Resources/Engine'


def line(process, expected):
    assert select.select([process.stdout], [], [], 5)[0], 'Child did not reach requested state'
    assert process.stdout.readline().strip() == expected


with tempfile.TemporaryDirectory() as folder:
    root = Path(folder)
    for i in range(64): (root / str(i)).touch(mode=0o600)
    (root / 'limit').write_text('64')
    policy = {'limit':64, 'default_limit':1, 'domain_limits':{'A':1,'B':2}, 'aliases':{'alias-A':'A'}}
    def save():
        temporary = root / 'next-policy'
        temporary.write_text(json.dumps(policy))
        temporary.replace(root / 'policy.json')
    save()
    env = dict(os.environ, PYTHONPATH=str(ENGINE))
    code = """import pathlib,sys,time,write_budget
with write_budget.permit(sys.argv[1],sys.argv[2],'fixture'):
    print('ACQUIRED',flush=True)
    while not pathlib.Path(sys.argv[3]).exists(): time.sleep(.01)
"""
    children = []
    def start(domain):
        release = root / f'release-{len(children)}'
        process = subprocess.Popen([sys.executable,'-B','-c',code,str(root),domain,str(release)],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        children.append((process,release))
        return process,release
    def finish(item):
        process,release = item
        release.touch()
        out,err=process.communicate(timeout=5)
        assert process.returncode==0,(out,err)
    try:
        a=start('A');b=start('B');b2=start('B')
        for process,_ in [a,b,b2]: line(process,'ACQUIRED')
        alias=start('alias-A');b3=start('B')
        assert not select.select([alias[0].stdout,b3[0].stdout],[],[],.15)[0]
        policy['limit']=0;save()
        finish(a);finish(b2)
        assert not select.select([alias[0].stdout,b3[0].stdout],[],[],.15)[0]
        policy['limit']=64;policy['domain_limits']={'A':1,'B':1};save()
        line(alias[0],'ACQUIRED')
        assert not select.select([b3[0].stdout],[],[],.1)[0]
        finish(b)
        line(b3[0],'ACQUIRED')
        finish(alias);finish(b3)
        # Malformed policy fails closed and releases its waiter/gate.
        (root/'policy.json').write_text('{broken')
        failed=subprocess.run([sys.executable,'-B','-c',"import sys,write_budget\nwith write_budget.permit(sys.argv[1],'A'): pass",str(root)],env=env,capture_output=True,text=True,timeout=5)
        assert failed.returncode!=0
        save()
        recovered=start('A');line(recovered[0],'ACQUIRED');finish(recovered)
        assert not list((root/'waiters').iterdir())
    finally:
        for process,_ in children:
            if process.poll() is None: process.kill();process.wait()
print('PASS: independent device quotas, confirmed alias quota, zero admission, in-flight drain, malformed policy cleanup and recovery')
