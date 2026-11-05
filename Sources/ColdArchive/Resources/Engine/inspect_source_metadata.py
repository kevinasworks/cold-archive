# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Read every included file's available metadata; no sample or tag allowlist.

The full report uses a separate file in desktop mode, never the bounded log pipe.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import contextlib
import threading
import time

import write_budget
import metadata_readers
import brand_evidence

from metadata_candidates import candidates
import media_metadata

EXTRACTION_OPTIONS = ['-j', '-G1:3:4', '-a', '-u', '-U', '-ee3', '-api', 'RequestAll=3',
                      '-api', 'LargeFileSupport=1', '-struct']
active_child = None
cancelled = False


def cancel(signum, frame):
    global cancelled
    cancelled = True
    if active_child is not None and active_child.poll() is None:
        os.killpg(active_child.pid, signal.SIGTERM)
        try:
            active_child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(active_child.pid, signal.SIGKILL)
            active_child.wait()


def checkpoint():
    if cancelled:
        raise SystemExit(130)


def inspect_file(tool, path):
    global active_child
    checkpoint()
    before = path.stat()
    rows, diagnostics, code = run_json([tool, '-config', str(Path(__file__).with_name('exiftool_metadata_only.config')), *EXTRACTION_OPTIONS, str(path)])
    after = path.stat()
    identity = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns)
    if identity(before) != identity(after):
        raise ValueError('File changed during metadata inspection')
    if not isinstance(rows, list) or not all(isinstance(row, dict) for row in rows):
        raise ValueError('Invalid ExifTool JSON report')
    errors = [str(value) for row in rows for tag, value in row.items() if tag.rsplit(':', 1)[-1] == 'Error']
    warnings = [str(value) for row in rows for tag, value in row.items() if tag.rsplit(':', 1)[-1] == 'Warning']
    if code and not errors:
        errors.append(diagnostics.strip() or f'ExifTool exit {code}')
    return rows, errors, warnings, diagnostics


def run_json(command, text_output=False):
    global active_child
    checkpoint()
    with tempfile.TemporaryFile(mode='w+b') as output, tempfile.TemporaryFile(mode='w+b') as diagnostic:
        # Pipe readers hold a write slot only while flushing a bounded chunk;
        # waiting for a metadata tool never occupies a write slot.
        child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL, start_new_session=True)
        active_child = child
        failures = []
        def drain(pipe, destination):
            try:
                while True:
                    chunk = pipe.read(65536)
                    if not chunk: break
                    write_budget.write(destination, chunk)
            except BaseException as error:
                failures.append(error)
                if child.poll() is None: child.kill()
            finally:
                pipe.close()
        drains = [threading.Thread(target=drain, args=pair) for pair in ((child.stdout, output), (child.stderr, diagnostic))]
        for thread in drains: thread.start()
        try:
            if cancelled: child.terminate()
            child.wait()
        finally:
            if child.poll() is None: child.kill(); child.wait()
            for thread in drains: thread.join()
            active_child = None
        checkpoint()
        if failures: raise failures[0]
        output.seek(0); diagnostic.seek(0)
        return (output.read().decode('utf-8', errors='replace') if text_output else json.load(output)), diagnostic.read().decode('utf-8', errors='replace'), child.returncode


def inspect_media(tool, path):
    return run_json([tool, *media_metadata.OPTIONS, str(path)])


def component_inventory():
    root = metadata_readers.runtime_root()
    if root and (root/'component-manifest.json').exists():
        return json.loads((root/'component-manifest.json').read_text())
    return {'mode':'development_host_tools','paths':{n:metadata_readers.executable(n) for n in ('exiftool','ffprobe','mediainfo','sf')}}


def companion_readers(path, include_media=True):
    extra, warnings = {}, []
    # Directory/header listing only: no archive member extraction or recursion.
    archive_tool = metadata_readers.executable('7zz')
    with path.open('rb') as probe:
        signature = probe.read(8)
    if archive_tool and (signature.startswith(b'7z\xbc\xaf\x27\x1c') or signature.startswith(b'Rar!\x1a\x07') or path.suffix.lower() in {'.tar','.tgz','.tbz2','.txz'}):
        try:
            listing, diagnostics, code = run_json([archive_tool, 'l', '-slt', '-sccUTF-8', '-bd', str(path)], text_output=True)
            extra['archive_directory'] = {'reader':'7zz','scope':'directory_and_headers_only','listing':listing,'diagnostics':diagnostics,'exit_code':code}
            if code: warnings.append('Archive directory: '+(diagnostics or f'exit {code}'))
        except (ValueError,OSError) as error:
            extra['archive_directory']={'status':'failed','error':str(error)}
            warnings.append('Archive directory: '+str(error))
    root = metadata_readers.runtime_root()
    commands = []
    sf = metadata_readers.executable('sf')
    if sf:
        command = [sf, '-json']
        if root: command += ['-home', str(root/'siegfried/data/siegfried')]
        commands.append(('format_identification', command+[str(path)]))
    else: warnings.append('Siegfried unavailable; format identification not performed')
    media = metadata_readers.executable('mediainfo')
    if media and include_media:
        commands.append(('mediainfo', [media, '--Output=JSON','--Full','--ParseSpeed=1','--Internet=0','--File_TestContinuousFileNames=0',str(path)]))
    elif include_media: warnings.append('MediaInfo unavailable; complementary media metadata not performed')
    perl = metadata_readers.executable('perl')
    if root and perl:
        commands.append(('binary_metadata', [perl, '-I'+str(root/'exiftool'), str(Path(__file__).with_name('binary_metadata.pl')), str(path)]))
    else: warnings.append('Bundled binary metadata reader unavailable')
    for key, command in commands:
        try:
            data, diagnostics, code = run_json(command)
            extra[key] = {'data':data,'exit_code':code,'diagnostics':diagnostics}
            if code or diagnostics.strip(): warnings.append(key+': '+(diagnostics or f'exit {code}'))
            if key=='binary_metadata':
                for field in data.get('fields',[]):
                    if field.get('status')=='unclassified_binary':
                        warnings.append('Unclassified binary field: '+field['tag'])
        except (ValueError,OSError) as e:
            extra[key]={'status':'failed','error':str(e)}; warnings.append(key+': '+str(e))
    try:
        doc = metadata_readers.document_metadata(path)
        if doc:
            extra['document_metadata']=doc
            warnings.extend('Document properties: '+str(e) for e in doc.get('errors',[]))
    except Exception as e:
        extra['document_metadata']={'status':'failed','error':str(e)}
        warnings.append('Document properties: '+str(e))
    hint = metadata_readers.private_structure(path)
    if hint:
        extra['private_format']=hint
        warnings.append('Private format recognized; unknown proprietary fields may remain')
    extra['parse_coverage']={'file_processed':True,'all_proprietary_fields_decoded':False,
                             'content_analysis':False,'packet_or_frame_decode':False if root else 'host_build_not_verified'}
    return extra, warnings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('sources', nargs='*', type=Path)
    parser.add_argument('--manifest', type=Path)
    parser.add_argument('--enumerate-only', action='store_true')
    parser.add_argument('--merge-directory', type=Path)
    parser.add_argument('--worker-file', type=Path)
    parser.add_argument('--output-json', type=Path, help='New report file outside the sources; stdout is progress only')
    parser.add_argument('--summary-json', type=Path, help='Compact UI summary; full evidence stays in output-json')
    args = parser.parse_args()
    if not args.sources and not args.worker_file and not args.manifest:
        parser.error("At least one source is required")
    if args.summary_json and not args.output_json:
        parser.error('--summary-json requires --output-json')
    tool = metadata_readers.executable('exiftool')
    media_tool = metadata_readers.executable('ffprobe')
    if not tool:
        parser.error('ExifTool unavailable: full metadata inspection requires ExifTool. No files were inspected.')
    helper = Path(__file__).with_name('create_archive_bundle.py')
    spec = importlib.util.spec_from_file_location('archive_metadata_helper', helper)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    paths = []
    inputs = []
    if args.worker_file:
        args.sources = []
        paths = [args.worker_file]
        inputs = [{"path": str(args.worker_file), "type": "file"}]
    for path in args.sources:
        checkpoint()
        path = path.expanduser()
        if path.is_symlink():
            parser.error(f'Symbolic-link source is not supported: {path}')
        path = path.resolve(strict=True)
        if path.is_dir():
            files = []
            def traversal_error(error):
                raise error
            for directory, dirs, names in os.walk(path, followlinks=False, onerror=traversal_error):
                checkpoint()
                links = [Path(directory) / n for n in dirs if (Path(directory) / n).is_symlink()]
                files.extend(links)
                dirs[:] = [n for n in dirs if not (Path(directory) / n).is_symlink()]
                files.extend(Path(directory) / n for n in names)
            excluded = []
            inputs.append({'path': str(path), 'type': 'directory', 'included_files': len(files), 'excluded_entries': len(excluded)})
            paths.extend(files)
        elif path.is_file():
            inputs.append({'path': str(path), 'type': 'file'})
            paths.append(path)
        else:
            parser.error(f'Unsupported source type: {path}')
    paths = sorted(set(paths), key=str)
    if args.manifest and not args.enumerate_only:
        manifest = json.loads(args.manifest.read_text())
        inputs = manifest['inputs']
        paths = [Path(p) for p in manifest['file_paths']]
    if args.enumerate_only:
        if not args.manifest: parser.error('--manifest required')
        with write_budget.writing(args.manifest, temporary=True), args.manifest.open('x') as stream:
            json.dump({'inputs':inputs, 'file_paths':[str(p) for p in paths], 'file_sizes':{str(p):p.lstat().st_size for p in paths}}, stream)
        return
    if args.output_json:
        output = args.output_json.resolve()
        for item in inputs:
            source = Path(item['path'])
            if output == source or (item['type'] == 'directory' and source in output.parents):
                parser.error('Metadata report must be outside every source')
    report = {'inputs': inputs, 'total_included_files': len(paths), 'inspected_file_count': 0,
              'attempted_file_count': 0, 'selected_file_count': len(paths), 'coverage': 'all_files',
              'extraction_options': EXTRACTION_OPTIONS, 'tool': tool,
              'media_tool': media_tool, 'media_extraction_options': media_metadata.OPTIONS,
              'files': [], 'candidates': [], 'errors': [], 'warnings': [],
              'note': 'All included files are attempted with all ExifTool-readable metadata requested. Media files and ExifTool failures also use FFprobe when available. FFprobe reports recognized container, stream, program and chapter metadata; this is not a full packet/frame or proprietary-format decode. Unsupported, encrypted or damaged metadata may remain unreadable. Metadata enumeration does not apply archive exclusions. Symbolic links and special files are reported without following them. Binary payloads are described rather than exported. No source data is modified.'}
    report['file_paths'] = [str(path) for path in paths]
    report['brand_findings'] = []
    report['schema_version'] = 2
    report['binary_policy'] = 'Typed binary metadata retained; content and unclassified payloads explicitly described'
    report['components'] = component_inventory()
    spool = tempfile.TemporaryFile(mode='w+', encoding='utf-8')
    for index, path in enumerate(paths):
        checkpoint()
        if args.output_json:
            print('METADATA_PROGRESS ' + json.dumps({'current': index, 'total': len(paths), 'file': str(path)}, ensure_ascii=False), flush=True)
        if args.merge_directory:
            worker = json.loads((args.merge_directory / f'{index}.json').read_text())
            if worker['file_paths'] != [str(path)] or worker['attempted_file_count'] != 1 or len(worker['files']) != 1:
                raise ValueError('Worker report identity mismatch')
            for key in ['candidates', 'errors', 'warnings', 'brand_findings']:
                report[key].extend(worker[key])
            report['inspected_file_count'] += worker['inspected_file_count']
            report['attempted_file_count'] += 1
            write_budget.write(spool, json.dumps(worker['files'][0], ensure_ascii=True) + '\n')
            continue
        entry = {'path': str(path), 'metadata': []}
        pending_candidates = []
        try:
            if path.is_symlink() or not path.is_file():
                raise ValueError('Symbolic link or special file: target not followed')
            before = path.stat()
            entry.update(bytes=before.st_size, filesystem=mod.filesystem_type(path))
            fs, fs_errors = metadata_readers.filesystem_metadata(path)
            entry['filesystem_metadata'] = fs
            report['warnings'].extend({'file':str(path),'warning': 'Filesystem: '+e} for e in fs_errors)
            try:
                rows, errors, warnings, diagnostics = inspect_file(tool, path)
            except (ValueError, OSError) as error:
                rows, errors, warnings, diagnostics = [], [str(error)], [], ''
            entry.update(metadata=rows, diagnostics=diagnostics, status='failed' if errors else 'read')
            report['errors'].extend({'file': str(path), 'error': error} for error in errors)
            report['warnings'].extend({'file': str(path), 'warning': warning} for warning in warnings)
            pending_candidates.extend(candidates(rows, source=str(path)))
            media_read = False
            if media_metadata.needed(path, rows, errors):
                if media_tool:
                    try:
                        data, media_diagnostics, code = inspect_media(media_tool, path)
                        entry['media_metadata'] = data
                        entry['media_diagnostics'] = media_diagnostics
                        media_read = code == 0 and bool(data.get('streams'))
                        entry['media_status'] = 'read' if media_read else 'failed'
                        if media_read:
                            pending_candidates.extend(media_metadata.suggestions(data, path))
                        if not media_read or media_diagnostics.strip():
                            report['warnings'].append({'file': str(path), 'warning': 'FFprobe: ' + (media_diagnostics.strip() or 'No readable media streams')})
                    except (ValueError, OSError) as error:
                        entry['media_status'] = 'failed'
                        report['warnings'].append({'file': str(path), 'warning': 'FFprobe: ' + str(error)})
                else:
                    entry['media_status'] = 'unavailable'
                    report['warnings'].append({'file': str(path), 'warning': 'FFprobe unavailable; supplementary media inspection was not performed'})
            extras, extra_warnings = companion_readers(path, include_media=media_metadata.needed(path, rows, errors))
            entry.update(extras)
            report['warnings'].extend({'file':str(path),'warning': w} for w in extra_warnings)
            after = path.stat()
            if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
                raise ValueError('File changed during metadata inspection')
            findings = brand_evidence.collect(rows, path, entry.get('media_metadata'), extras)
            entry['brand_findings'] = findings
            report['brand_findings'].extend(findings)
            report['candidates'].extend(pending_candidates)
            if errors and media_read:
                entry['status'] = 'partial'
            if not errors or media_read:
                report['inspected_file_count'] += 1
        except (ValueError, OSError) as error:
            entry.update(status='failed', error=str(error))
            report['errors'].append({'file': str(path), 'error': str(error)})
        write_budget.write(spool, json.dumps(entry, ensure_ascii=True) + '\n')
        report['attempted_file_count'] += 1
    checkpoint()
    if report['errors']:
        report['coverage'] = 'all_files_attempted_with_errors'
    elif report['warnings']:
        report['coverage'] = 'all_files_read_with_warnings'
    # Full evidence is streamed one file at a time; no all-files JSON aggregation.
    report.pop('files', None)
    if args.summary_json:
        for source in inputs:
            base = Path(source['path'])
            target = args.summary_json.resolve()
            if target == base or (source['type']=='directory' and base in target.parents):
                parser.error('Summary must be outside source')
    def write_full(stream):
        prefix = json.dumps(report, ensure_ascii=True)
        stream.write(prefix[:-1] + ', "files": [\n')
        spool.seek(0)
        first = True
        for line in spool:
            checkpoint()
            if not first: stream.write(',\n')
            stream.write(line.rstrip('\n')); first = False
        stream.write('\n]}\n')
    if args.output_json:
        fd = os.open(args.output_json, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            with write_budget.writing(fd, temporary=True), os.fdopen(fd, 'w', encoding='utf-8') as stream: write_full(stream)
            checkpoint()
            if args.summary_json:
                with write_budget.writing(args.summary_json, temporary=True), args.summary_json.open('x', encoding='utf-8') as stream:
                    json.dump(report, stream, ensure_ascii=True)
        except BaseException:
            args.output_json.unlink(missing_ok=True)
            raise
        print('METADATA_COMPLETE ' + json.dumps({'current': len(paths), 'total': len(paths)}), flush=True)
    else:
        write_full(sys.stdout)
    spool.close()


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, cancel)
    signal.signal(signal.SIGINT, cancel)
    parent = os.getppid()
    def watch_parent():
        while os.getppid() == parent:
            time.sleep(1)
        os.kill(os.getpid(), signal.SIGTERM)
        time.sleep(8)
        child = active_child
        if child is not None and child.poll() is None:
            with contextlib.suppress(ProcessLookupError): os.killpg(child.pid, signal.SIGKILL)
        os._exit(130)
    threading.Thread(target=watch_parent, daemon=True).start()
    main()
