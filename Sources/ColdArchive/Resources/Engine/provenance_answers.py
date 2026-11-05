# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Map identified user answers to provenance fields without freeform summarization."""
from pathlib import Path

UNKNOWN = {'未知／不填写', '未知/不填写', '未知', '不清楚', 'Unknown'}
BLANK = {'不填写', '留空', 'Leave blank'}
NONE = {'无补充', 'No additional notes'}
QUESTIONS = {'source_type', 'device', 'source_software', 'purpose', 'notes'}

def fail(message):
    raise SystemExit('SOURCE_CONFIRMATION_PENDING: ' + message)

def value(record, field):
    if not isinstance(record, dict) or not isinstance(record.get('answer'), str) or not record['answer'].strip():
        fail(field + ' has no submitted answer')
    if record.get('status') != 'submitted':
        fail(field + ' is not explicitly submitted')
    answer = record['answer'].strip()
    if field == 'notes' and answer in UNKNOWN | BLANK:
        fail('notes requires No additional notes or actual free text')
    if answer in UNKNOWN:
        return {'state': 'unknown'}
    if answer in BLANK:
        return {'state': 'not_provided'}
    if answer in NONE:
        if field != 'notes':
            fail('No additional notes is valid only for notes')
        return {'state': 'no_additional_notes'}
    if answer in {'自定义填写', '自由填写', 'Custom', '采用检测结果'}:
        fail(field + ' requires the actual chosen/custom value')
    english = record.get('en')
    if not isinstance(english, str) or not english.strip():
        fail(field + ' requires an English translation')
    # Chinese value comes directly from the answer, never a model-produced summary.
    return {'state': 'provided', 'zh': answer, 'en': english}

def compile_answers(document, sources):
    if isinstance(document, dict) and document.get('schema_version') == 3:
        return compile_grouped_answers(document, sources)
    if not isinstance(document, dict) or document.get('schema_version') != 2:
        fail('unsupported answer record schema')
    recorded = document.get('sources')
    if not isinstance(recorded, list) or not all(isinstance(p, str) for p in recorded):
        fail('source binding missing')
    actual = sorted(str(Path(p).expanduser().resolve()) for p in sources)
    if sorted(recorded) != actual:
        fail('answer record belongs to different source inputs')
    answers = document.get('answers')
    if not isinstance(answers, dict) or set(answers) != QUESTIONS:
        fail('all five identified questions must be answered')
    result = {field: value(answers[field], field) for field in QUESTIONS - {'device'}}
    device = value(answers['device'], 'device')
    if device['state'] != 'provided':
        result['device_name'] = dict(device)
        result['device_model'] = dict(device)
    else:
        # Preserve the combined answer; do not guess a brand/model split.
        result['device_name'] = device
        result['device_model'] = {'state':'not_provided'}
        # Optional explicitly submitted separate components must be verbatim fragments.
        for field, key in [('device_name','brand'),('device_model','model')]:
            if key in answers['device']:
                part = value(answers['device'][key], field)
                if part['state']=='provided' and part['zh'] not in device['zh']:
                    fail('device component not present in submitted answer')
                result[field] = part
    return result

def validate_source_answers(text, provenance, render):
    """Compare rendered fields to the original answer-derived values, per language."""
    import re
    parts = text.split('## English', 1)
    if len(parts) != 2:
        raise SystemExit('SOURCE_ANSWER_MISMATCH: missing language section')
    headings = {
        'source_type': ('来源类别','Source category'),
        'device_name': ('生成文件的设备品牌及型号','Generating device brand and model'),
        'device_model': ('单独提供的设备型号','Separately provided device model'),
        'source_software': ('生成或编辑文件的软件','Creation or editing software'),
        'purpose': ('此归档的用途','Purpose of this archive'),
        'notes': ('备注','Notes'),
    }
    for field, labels in headings.items():
        for i, lang in enumerate(('zh','en')):
            match = re.search(r'^### ' + re.escape(labels[i]) + r'\n\n(.*?)(?=\n\n### |\n\n---|\Z)', parts[i], re.S|re.M)
            if not match or match.group(1).strip() != render(provenance[field],lang).strip():
                raise SystemExit('SOURCE_ANSWER_MISMATCH: ' + field + '/' + lang)


def compile_grouped_answers(document, sources):
    """Validate a complete, disjoint file partition for every provenance question."""
    import os
    recorded = document.get('sources')
    actual = sorted(str(Path(p).expanduser().resolve()) for p in sources)
    if not isinstance(recorded, list) or not all(isinstance(p, str) for p in recorded) or sorted(recorded) != actual:
        fail('grouped answers belong to different source inputs')
    expected = set()
    for name in actual:
        source = Path(name)
        if source.is_file():
            expected.add(str(source))
        elif source.is_dir():
            def walk_error(error):
                fail('cannot enumerate grouped source: ' + str(error))
            for directory, dirs, names in os.walk(source, followlinks=False, onerror=walk_error):
                links = [n for n in dirs if (Path(directory) / n).is_symlink()]
                expected.update(str(Path(directory) / n) for n in links + names)
                dirs[:] = [n for n in dirs if n not in links]
        else:
            fail('grouped source is missing or unsupported')
    answers = document.get('grouped_answers')
    if not isinstance(answers, dict) or set(answers) != QUESTIONS:
        fail('all five grouped questions must be answered')
    result = {}
    for field in sorted(QUESTIONS):
        records = answers[field]
        if not isinstance(records, list) or not records:
            fail(field + ' has no confirmed groups')
        seen, ids, groups = set(), set(), []
        for record in records:
            if not isinstance(record, dict):
                fail(field + ' invalid group')
            group_id = record.get('group_id')
            if not isinstance(group_id, str) or not group_id or group_id in ids:
                fail(field + ' duplicate or missing group ID')
            ids.add(group_id)
            files = record.get('files')
            if not isinstance(files, list) or not all(isinstance(p, str) for p in files):
                fail(field + ' invalid file mapping')
            if len(files) != len(set(files)) or seen.intersection(files) or not set(files).issubset(expected):
                fail(field + ' overlapping or foreign file mapping')
            if expected and not files:
                fail(field + ' empty group for nonempty source')
            if not expected and len(records) != 1:
                fail(field + ' empty source requires one confirmation')
            seen.update(files)
            if any(not isinstance(record.get(k), str) or not record[k].strip() for k in ('category', 'category_en')):
                fail(field + ' missing bilingual group category')
            groups.append({'category': record['category'], 'category_en': record['category_en'],
                           'files': files, 'value': value(record.get('response'), field)})
        if seen != expected:
            fail(field + ' missing file confirmations or source inventory changed')
        compiled = {'state': 'grouped', 'groups': groups}
        if field == 'device':
            result['device_name'] = compiled
            result['device_model'] = {'state': 'grouped', 'groups': [
                {**g, 'value': g['value'] if g['value']['state'] != 'provided' else {'state': 'not_provided'}} for g in groups]}
        else:
            result[field] = compiled
    return result
