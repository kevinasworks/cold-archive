# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Real Security.framework upgrade test, isolated synthetic keychain only.

Signs two changed executables with the project identity, never opens login
keychain items. The temporary keychain is removed from the search list directly
on creation, and deleted on completion. No real passwords are read or printed.
"""
import os, subprocess, tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def run(args, **kw):
    result=subprocess.run(args,text=True,capture_output=True,timeout=90,**kw)
    if result.returncode:
        raise RuntimeError(result.stderr + result.stdout)
    return result
with tempfile.TemporaryDirectory(prefix='coldarchive-keychain-upgrade-') as folder:
    base=Path(folder)
    cache=(ROOT/'Sources/ColdArchive/SynologyMonitor.swift').read_text()
    cache=cache[cache.index('final class CredentialSessionCache'):cache.index('struct NASSample:')]
    (base/'support.swift').write_text('''import Foundation
struct NASSecrets:Codable,Equatable {var auth="";var privacy="";var loadingError:String?=nil}
enum AppError:LocalizedError {case message(String);var errorDescription:String? {if case let .message(s)=self{return s};return nil}}
final class DiagnosticLog {
 static let shared=DiagnosticLog()
 func write(_ fields:[String:Any]) { print(String(decoding:try! JSONSerialization.data(withJSONObject:fields,options:.sortedKeys),as:UTF8.self)) }
}
'''+cache)
    (base/'main.swift').write_text('''import Foundation
import Security
let args=CommandLine.arguments
let file=args[1], action=args[2]
var keychain:SecKeychain?
if action=="seed" {
 var before:CFArray?
 precondition(SecKeychainCopySearchList(&before)==errSecSuccess)
 let password="synthetic-fixture-password-3719"
 let status=password.withCString {SecKeychainCreate(file,UInt32(strlen($0)),$0,false,nil,&keychain)}
 precondition(status==errSecSuccess)
 precondition(SecKeychainSetSearchList(before!)==errSecSuccess)
} else {precondition(SecKeychainOpen(file,&keychain)==errSecSuccess)}
guard let keychain else {fatalError("No fixture keychain")}
var interactionBefore:DarwinBoolean=false
precondition(SecKeychainGetUserInteractionAllowed(&interactionBefore)==errSecSuccess)
let backend=SystemNASCredentialBackend(keychain:keychain)
if action=="seed" {
 try backend.write(service:NASCredentialStore.legacyService,secrets:NASSecrets(auth:"synthetic-original"))
} else if action=="denied" {
 let store=NASCredentialStore(backend:backend)
 do {_=try store.load();fatalError("Expected legacy identity mismatch")}
 catch let error as CredentialAccessError {precondition(error.migration);precondition(error.status==errSecInteractionNotAllowed || error.status==errSecAuthFailed)}
} else if action=="save" {
 try NASCredentialStore(backend:backend).save(NASSecrets(auth:"synthetic-new"))
} else if action=="read" {
 let store=NASCredentialStore(backend:backend)
 let value=try store.load()
 precondition(value.auth=="synthetic-new" || value.auth=="synthetic-updated")
 let again=try store.load();precondition(again==value)
 try store.save(value)
 try store.save(NASSecrets(auth:"synthetic-updated"))
} else if action=="legacy" {
 let original=try backend.read(service:NASCredentialStore.legacyService,interaction:false);precondition(original?.auth=="synthetic-original")
} else if action=="delete" {precondition(SecKeychainDelete(keychain)==errSecSuccess)}
var interactionAfter:DarwinBoolean=false
precondition(SecKeychainGetUserInteractionAllowed(&interactionAfter)==errSecSuccess)
precondition(interactionBefore.boolValue==interactionAfter.boolValue)
#if SECOND
print("PASS second-build",action)
#else
print("PASS first-build",action)
#endif
''')
    keychain=base/'synthetic.keychain-db'
    binaries=[]
    for name,flags in [('old',[]),('first',[]),('second',['-D','SECOND'])]:
        binary=base/name
        run(['swiftc',*flags,str(base/'support.swift'),str(ROOT/'Sources/ColdArchive/NASCredentialStore.swift'),str(base/'main.swift'),'-o',str(binary)])
        if name=='old':run(['codesign','--force','--sign','-','--identifier','local.coldarchive.mac',str(binary)])
        else:run(['python3',str(ROOT/'scripts/sign-app.py'),str(binary)])
        binaries.append(binary)
    old,first,second=binaries
    outputs=[]
    try:
        for binary,action in [(old,'seed'),(first,'denied'),(first,'save'),(first,'read'),(second,'read'),(second,'read'),(old,'legacy')]:
            outputs.append(run([str(binary),str(keychain),action]).stdout)
        displays=[run(['codesign','-d','-r-','--verbose=2',str(p)]) for p in [first,second]]
        signatures=[r.stdout+r.stderr for r in displays]
        dr=[s.split('designated =>',1)[1].strip().splitlines()[0] for s in signatures]
        assert dr[0]==dr[1] and 'cdhash' not in dr[0]
        import hashlib
        assert hashlib.sha256(first.read_bytes()).digest()!=hashlib.sha256(second.read_bytes()).digest()
        print('PASS: changed signed builds share stable DR; blocked legacy fails without interaction; new credentials read/update across restart and upgrade; old fixture retained unchanged')
        for out in outputs: print(out,end='')
    finally:
        if keychain.exists():run([str(old),str(keychain),'delete'])
