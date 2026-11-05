# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Sign with a pinned Apple identity; never silently fall back to ad-hoc."""
import json, os, re, subprocess, sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
policy_path=Path(os.environ.get('COLD_ARCHIVE_SIGNING_POLICY', str(ROOT/'scripts/signing-policy.json')))
if not policy_path.is_file():
    raise SystemExit('Signing requires a private local policy. Set COLD_ARCHIVE_SIGNING_POLICY; see scripts/signing-policy.example.json.')
policy=json.loads(policy_path.read_text())
app=Path(sys.argv[1])
identity=os.environ.get('COLD_ARCHIVE_SIGN_IDENTITY',policy['identity_sha1'])
assert re.fullmatch(r'[A-Fa-f0-9]{40}',identity),'Specify a certificate SHA-1 fingerprint'
identities=subprocess.check_output(['security','find-identity','-v','-p','codesigning'],text=True)
if identity.upper() not in identities.upper():
    raise SystemExit('Pinned signing identity unavailable; build stopped. No ad-hoc fallback.')
team=policy['team_id']; bundle=policy['bundle_id']
assert re.fullmatch(r'[A-Z0-9]{10}',team)
assert re.fullmatch(r'[A-Za-z0-9.-]+',bundle)
# Stable across binaries/certificate renewal, restricted to this app + Apple team.
requirement=f'identifier "{bundle}" and anchor apple generic and certificate leaf[subject.OU] = "{team}" and (certificate 1[field.1.2.840.113635.100.6.2.1] exists or certificate 1[field.1.2.840.113635.100.6.2.6] exists)'
subprocess.run(['codesign','--force','--sign',identity,'--identifier',bundle,'--requirements','=designated => '+requirement,str(app)],check=True)
subprocess.run(['codesign','--verify','--deep','--strict','--test-requirement','='+requirement,str(app)],check=True)
display=subprocess.run(['codesign','-d','-r-','--verbose=2',str(app)],capture_output=True,text=True,check=True)
info=display.stdout+display.stderr
assert f'TeamIdentifier={team}' in info
assert 'Signature=adhoc' not in info
assert 'designated =>' in info and 'cdhash H' not in info.split('designated =>')[-1]
print('PASS: pinned Apple-team signature and stable app-specific designated requirement')
