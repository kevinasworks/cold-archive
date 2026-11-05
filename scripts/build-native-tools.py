# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Build locally pinned offline tools; no package-manager installation."""
import concurrent.futures, os, subprocess
from pathlib import Path
root=Path(__file__).resolve().parents[1]
def build(name,source,steps):
    with (root/'QA/components'/f'{name}-build.log').open('w') as log:
        for args in steps:
            subprocess.run(args,cwd=root/source,env={**os.environ,'MACOSX_DEPLOYMENT_TARGET':'14.0'},stdout=log,stderr=subprocess.STDOUT,check=True)
    print(name+' built',flush=True)
tasks=[('ffmpeg','vendor/src/ffmpeg-7.1.1',[
    ['./configure','--prefix='+str(root/'vendor/runtime/media'),'--cc=clang','--extra-cflags=-mmacosx-version-min=14.0','--extra-ldflags=-mmacosx-version-min=14.0','--disable-autodetect','--disable-network','--disable-doc','--disable-debug','--disable-ffmpeg','--disable-ffplay','--disable-avdevice','--disable-avfilter','--disable-swscale','--disable-swresample','--disable-encoders','--disable-decoders','--disable-muxers','--disable-protocols','--enable-protocol=file,pipe','--enable-static','--disable-shared'],['make','-j6'],['make','install']])]
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    futures=[pool.submit(build,*t) for t in tasks]
    for f in futures:f.result()
subprocess.run([os.sys.executable, str(root/'scripts/build-perl.py')], check=True)
