# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Independent pools, local-device classification and target contention."""
import os,sys,tempfile,threading,fcntl,time
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'Sources/ColdArchive/Resources/Engine'))
import write_budget
with tempfile.TemporaryDirectory() as directory:
    root=Path(directory);local=root/'temporary';local.mkdir()
    for pool,limit in [(root,1),(local,5)]:
        (pool/'limit').write_text(str(limit))
        for i in range(limit):(pool/str(i)).touch()
    os.environ['COLD_ARCHIVE_WRITE_BUDGET']=str(root)
    os.environ['COLD_ARCHIVE_LOCAL_TEMP_DEVICE']=str(root.stat().st_dev)
    target=os.open(root/'0',os.O_RDWR);fcntl.flock(target,fcntl.LOCK_EX)
    completed=threading.Event();errors=[]
    def temp_writer():
        try:
            with tempfile.TemporaryFile(mode='w+') as stream:write_budget.write(stream,'temporary output')
            completed.set()
        except BaseException as e:errors.append(e)
    thread=threading.Thread(target=temp_writer);thread.start()
    independent=completed.wait(3)
    os.close(target);thread.join(3)
    assert independent and not errors,'target permit blocked local temporary write'
    assert write_budget.pool_root(root/'new.json',True)==str(local)
    os.environ['COLD_ARCHIVE_LOCAL_TEMP_DEVICE']=str(root.stat().st_dev+1)
    assert write_budget.pool_root(root/'new.json',True)==str(root),'nonlocal temporary must use target pool'
    os.environ['COLD_ARCHIVE_LOCAL_TEMP_DEVICE']=str(root.stat().st_dev)
    for temporary,expected in [(False,1),(True,5)]:
        active=peak=0;guard=threading.Lock();errors=[]
        def writer():
            global active,peak
            try:
                with write_budget.writing(root/'spool',temporary=temporary):
                    with guard:active+=1;peak=max(peak,active)
                    time.sleep(.1)
                    with guard:active-=1
            except BaseException as e:errors.append(e)
        jobs=[threading.Thread(target=writer) for _ in range(10)]
        for job in jobs:job.start()
        for job in jobs:job.join(5)
        assert not errors and all(not j.is_alive() for j in jobs) and peak==expected,(errors,peak)
print('PASS: target held while local temporary completes; target peak 1; temporary peak 5; nonlocal temporary uses target pool')
