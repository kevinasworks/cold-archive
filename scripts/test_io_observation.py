# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
import json
from pathlib import Path
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'Sources/ColdArchive/Resources/Engine'))
from io_observation import ReadObservation

now=[0.0]; rows=[]
observation=ReadObservation(rows.append,lambda:now[0])
observation.record(7,.1)
assert not rows
now[0]=1.2
observation.record(13,.2)
observation.record(5,.05)
now[0]=1.5
observation.flush(); observation.flush()
data=[json.loads(line.removeprefix('IO_SAMPLE ')) for line in rows]
assert len(data)==2
assert sum(row['bytes_read'] for row in data)==25
assert sum(row['io_calls'] for row in data)==3
assert data[0]['max_io_seconds']==.2
assert all(row['metric_source']=='logical_bytes' for row in data)
now[0]=2
observation=ReadObservation(rows.append,lambda:now[0])
now[0]=12
observation.exclude_idle(9)
observation.record(3,.1)
assert json.loads(rows[-1].removeprefix('IO_SAMPLE '))['window_seconds']==1
print('PASS: exact logical byte counts, bounded emission, final partial window')
