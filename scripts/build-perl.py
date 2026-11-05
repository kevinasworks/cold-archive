# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
import os, subprocess, tempfile, shutil
from pathlib import Path
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='coldarchive-perl-',dir='/private/tmp') as t:
    work=Path(t); prefix=work/'installed'
    subprocess.run(['tar','-xf',str(root/'vendor/downloads/perl.tar.gz'),'-C',str(work)],check=True)
    with (root/'QA/components/perl-build.log').open('w') as log:
        env={**os.environ,'MACOSX_DEPLOYMENT_TARGET':'14.0','LC_ALL':'C','LANG':'C'}
        for command in [['sh','Configure','-des','-Dprefix='+str(prefix),'-Duserelocatableinc','-Dman1dir=none','-Dman3dir=none','-Dcc=clang'],['make','-j6'],['make','install']]:
            subprocess.run(command,cwd=work/'perl-5.42.0',env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
    shutil.copytree(prefix,root/'vendor/runtime/perl',dirs_exist_ok=True)
print('Relocatable Perl built')
