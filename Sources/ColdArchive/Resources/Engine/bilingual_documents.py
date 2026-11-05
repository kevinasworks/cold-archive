# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Bilingual presentation of verified archive metadata; never changes hash manifests."""
import html
import re
import shlex
from datetime import datetime
from pathlib import Path

def code(value):
    return '<code>' + html.escape(str(value)).replace('|','&#124;').replace('\n','&#10;').replace('\r','&#13;') + '</code>'

def pair(title, zh, en):
    return f'# {title}\n\n## 中文\n\n{zh.strip()}\n\n---\n\n## English\n\n{en.strip()}\n'

# Translate fixed technical labels, not user paths, values or shell commands.
LABELS = {
'Archive Information':'归档信息','Archive Identity':'归档标识','Archive Name':'归档文件名','ArchiveName_RAW':'原始归档名称（ArchiveName_RAW）','ArchiveName_DISPLAY':'显示归档名称（ArchiveName_DISPLAY）','Archive ID':'归档标识符','Archive Folder Name':'归档文件夹名称','Created':'创建时间','Started':'开始时间','Completion Time':'完成时间','Verification Record Generated':'验证记录生成时间','CPU Architecture':'CPU 架构','Source Filesystem':'源文件系统','Target Filesystem':'目标文件系统','Output Directory':'输出目录','Output Directory Mode':'输出目录选择方式','Detected 7-Zip Commands (detection order)':'检测到的 7-Zip 程序（检测顺序）','Toolchain':'工具链','Operating System':'操作系统','Python Version':'Python 版本','7-Zip Version':'7-Zip 版本','7-Zip Executable':'7-Zip 执行程序','Hash Tool':'哈希工具','Archive Script':'归档脚本','Skill Version':'脚本实现版本（区别于归档格式版本）','Archive Standard':'归档标准','Archive Format':'归档格式','Format Version':'格式版本','Purpose':'用途','Archive Status':'归档状态','Status':'状态','Warning':'提示','Source':'来源','Source Path':'路径基准目录','File Count':'文件数量','Total Size':'总大小','Archive':'归档','Archive Size':'归档大小','Compression':'压缩设置','Format':'格式','Method':'算法','Level':'压缩级别','Dictionary':'字典大小','Fast Bytes':'快速字节数','Solid':'固实压缩','Command Parameters':'压缩配置参数','Exclusion Rules':'排除规则','macOS':'macOS','Windows':'Windows','Linux':'Linux','Android':'Android','General temporary files':'通用临时文件','Excluded Source Entries':'实际排除条目数量','Compatibility Test':'兼容性测试','Compatibility Test Location':'兼容性测试位置','Local Temporary Directory':'本地临时目录','Filesystem':'文件系统','Filename Compatibility':'文件名兼容性','Extraction Test':'解压测试','SHA512 Verification':'SHA-512 验证','SMB Recovery Stability':'SMB 恢复稳定性','Mode':'模式','Hash Scan Attempts':'哈希扫描次数','Result':'结果','Verification':'验证','Source SHA512':'源文件 SHA-512','Archive Test':'归档测试','Extraction Verification':'解压恢复验证','Source Data Verification':'源数据一致性验证','Archive SHA512':'归档 SHA-512','Archive Contents':'归档内容索引','Final Bundle Structure':'最终归档结构','Notes':'备注','Recovery':'恢复步骤','Results':'验证结果','Compatibility Test Filesystem':'兼容性测试文件系统','Compatibility Test Reason':'兼容性测试原因','SMB Recovery Stability Mode':'SMB 恢复稳定性模式','SMB Recovery Hash Scan Attempts':'SMB 恢复哈希扫描次数','Archive SHA-512':'归档 SHA-512','7z Test':'7z 完整性测试','Compression Parameters':'压缩参数','Restored SHA512 Comparison':'恢复文件 SHA-512 比较','Directory Structure Comparison':'目录结构比较','Source SHA-512 manifest generation and parse verification':'源 SHA-512 清单生成与解析验证','7z format and LZMA2 property inspection':'7z 格式和 LZMA2 属性检查','7-Zip integrity test':'7-Zip 完整性测试','Full-path extraction test':'完整路径解压测试','Restored path, size, directory, and SHA-512 comparison':'恢复路径、大小、目录及 SHA-512 比较','Live-source freeze verification':'实时源数据一致性验证','Final archive SHA-512 verification':'最终归档 SHA-512 验证','Filename compatibility':'文件名兼容性','Source information document generation':'来源信息文档生成','Statistics document generation':'统计文档生成','Final bundle structure verification':'最终归档结构验证',
}
SENTENCES = {
'Long-term cold storage archive':'长期冷备归档',
'Data changes require complete reverification; authorized documentation corrections must be recorded separately.':'数据变化必须重新执行完整验证；经授权的文档修订必须单独记录。',
'Immutable Cold Archive':'不可变冷备归档',
'Do not modify files inside this directory.':'不要修改此目录中的文件。',
'Any modification invalidates verification records.':'文档修订需另行记录；数据变化必须重新执行完整验证。',
'Only the following automatically generated operating-system entries were excluded. No broader patterns were used.':'以下为固定排除规则；实际排除数量见下文，不表示每个规则都匹配了源文件。',
'These rules affect archive scanning only. No source file or directory is deleted or modified.':'这些规则仅影响归档扫描，不删除或修改任何源文件或目录。',
'Compatibility tests are executed on local filesystem to avoid SMB/NFS metadata synchronization issues.':'兼容性测试在本地文件系统执行，以避免 SMB/NFS 元数据同步问题。',
'Already compressed media may have limited size reduction.':'已压缩的数据可能无法显著缩小；小文件可能因归档格式开销而变大。',
'UTF-8 filenames':'UTF-8 文件名','Chinese characters':'中文字符','Japanese characters':'日文字符','Korean characters':'韩文字符','Emoji':'表情符号','Spaces':'空格','Special symbols':'特殊符号','Long filenames':'长文件名',
'default source parent':'默认源父目录','explicit --output-dir':'显式指定 --output-dir','bounded smbfs retry':'有上限的 SMB 重试','not required':'无需重试','not recorded':'未记录','Enabled':'启用','Ultra':'极限（Ultra）','PASS':'通过（PASS）',
}

def translate(text):
    out=[]
    for line in text.splitlines():
        # Markdown headings and label/value lines only; never replace inside code values.
        m=re.match(r'^(#{1,6} |\- )?(.*)$',line)
        prefix=m.group(1) or '';body=m.group(2)
        if body in LABELS: body=LABELS[body]
        elif ': ' in body:
            label,value=body.split(': ',1)
            body=(LABELS[label]+'：'+SENTENCES.get(value,value)) if label in LABELS else body
        elif body.endswith(':') and body[:-1] in LABELS: body=LABELS[body[:-1]]+'：'
        else: body=SENTENCES.get(body,body)
        if body.startswith('local ('):body='本地（'+body[7:-1]+'）'
        if body=='PASS:':body='通过（PASS）：'
        if '：local (' in body:body=body.replace('：local (','：本地（').removesuffix(')')+'）'
        out.append(prefix+body)
    return '\n'.join(out)

def recovery(archive, files, directory):
    z='以下路径均以归档包根目录为基准；恢复文件的相对路径以新的解压目录为基准。\n\n'
    e='All document and archive paths below are relative to the bundle root; restored paths are relative to the new extraction directory.\n\n'
    if files:
        z+='解压后直接按内容索引中的相对路径恢复所选文件，不添加包装目录。\n\n'
        e+='Selected files restore at the relative paths in the content index, without a wrapper directory.\n\n'
    else:
        z+='解压后恢复顶层目录 '+code(directory)+'。\n\n'
        e+='Extraction recreates the top-level directory '+code(directory)+'.\n\n'
    z+=f'1. 将 {code(archive)} 的大小及 SHA-512 与 {code(archive+".sha512.md")} 比较。\n2. 使用 7-Zip `t` 测试 {code(archive)}。\n3. 使用 7-Zip `x` 解压到新的空目录。\n4. 计算全部恢复文件的大小及 SHA-512，与 {code("Documents/SHA512.md")} 逐项比较。\n5. 对照 {code("Documents/ARCHIVE_CONTENTS.md")} 检查目录结构；内容索引不是完整性证明。'
    e+=f'1. Compare the size and SHA-512 of {code(archive)} with {code(archive+".sha512.md")}.\n2. Run 7-Zip `t` on {code(archive)}.\n3. Extract using 7-Zip `x` into a new empty directory.\n4. Compare every restored file size and SHA-512 with {code("Documents/SHA512.md")}.\n5. Check directory structure against {code("Documents/ARCHIVE_CONTENTS.md")}; this inventory is not integrity proof.'
    return z,e

def provenance_value(item, language):
    """Keep explicit user states distinct from absent information."""
    defaults = {"unknown": ("不清楚", "Unknown"), "not_provided": ("未提供", "Not provided"),
                "no_additional_notes": ("无补充", "No additional notes")}
    if item is None or item == "":
        item = {"state": "not_provided"}
    if isinstance(item, str):
        aliases = {"未知／不填写": "unknown", "未知/不填写": "unknown", "未知": "unknown", "不清楚": "unknown", "Unknown": "unknown", "未提供": "not_provided",
                   "Not provided": "not_provided", "无补充": "no_additional_notes", "No additional notes": "no_additional_notes"}
        item = {"state": aliases[item]} if item in aliases else {"state": "provided", "zh": item, "en": item}
    state = item.get("state", "provided")
    if state == "grouped":
        groups = item.get("groups")
        if not isinstance(groups, list) or not groups:
            raise SystemExit("Grouped provenance requires confirmed file groups")
        sections = []
        for index, group in enumerate(groups, 1):
            label = html.escape(group["category" if language == "zh" else "category_en"])
            files = group["files"]
            heading = (f"组 {index}：{label}（{len(files)} 个文件）" if language == "zh"
                       else f"Group {index}: {label} ({len(files)} files)")
            paths = "<br>\n".join(html.escape(path).replace("|", "&#124;") for path in files)
            mapping = ("适用文件：" if language == "zh" else "Applicable files: ") + paths
            sections.append(heading + "<br>\n" + mapping + "<br>\n" + provenance_value(group["value"], language))
        return "\n\n".join(sections)
    if state in defaults:
        return defaults[state][0 if language == "zh" else 1]
    if state != "provided" or not isinstance(item.get(language), str) or not item[language].strip():
        raise SystemExit("Provided provenance values require separate nonempty zh/en text")
    return html.escape(item[language]).replace("|", "&#124;").replace("\n", "<br>\n")

def update_documents(bundle, *, originals, base, archive, command, listing, legacy=False, provenance=None, created=None):
    """Called before publication; returns expected bytes for all non-hash documents."""
    docs=bundle/'Documents';now=datetime.now().astimezone().isoformat(timespec='seconds')
    is_files=all(Path(p).is_file() for p in originals)
    rz,recovery_en=recovery(archive,is_files,Path(originals[0]).name)
    properties={}
    for line in listing.splitlines():
        if ' = ' in line:
            key,value=line.split(' = ',1);properties.setdefault(key,value)
    actual_method=properties.get('Method','not recorded');actual_solid=properties.get('Solid','not recorded')
    p=docs/'COMPRESSION_INFO.md';old=p.read_text();version=re.search(r'7-Zip \(z\).*',old).group(0);exe=html.unescape(re.search(r'<code>(.*?)</code>',old).group(1))
    command_text=shlex.join(command) if command is not None else None
    cmdz=code(command_text) if command_text else '原始完整命令未保存，不能从现有记录精确还原。'
    cmde=code(command_text) if command_text else 'The original full command was not retained and cannot be reconstructed exactly from existing records.'
    z=f'### 执行程序\n\n{code(exe)}\n\n{version}\n\n### 请求的压缩配置\n\n- 格式：7z\n- 算法：LZMA2\n- 压缩级别：极限（Ultra）\n- 字典大小上限：64 MiB\n- 快速字节数：64\n- 固实压缩选项：启用（`-ms=on`）\n\n### 实际归档属性\n\n- 算法及字典标识：{code(actual_method)}\n- 固实分组：{code(actual_solid)}\n\n小数据可使用更小的字典；不足两个非空数据流时，不形成多文件固实分组。实际属性与请求参数应分别理解。\n\n### 完整执行命令\n\n{cmdz}'
    e=f'### Executable\n\n{code(exe)}\n\n{version}\n\n### Requested compression settings\n\n- Format: 7z\n- Method: LZMA2\n- Level: Ultra\n- Dictionary limit: 64 MiB\n- Fast Bytes: 64\n- Solid option: enabled (`-ms=on`)\n\n### Observed archive properties\n\n- Method and dictionary identifier: {code(actual_method)}\n- Solid grouping: {code(actual_solid)}\n\nSmall inputs may use a smaller dictionary; fewer than two nonempty streams do not form a multi-file solid group. Requested settings and observed properties are distinct.\n\n### Full executed command\n\n{cmde}'
    p.write_text(pair('压缩信息 / Compression Information',z,e))
    p=docs/'SOURCE_INFO.md'
    if provenance is None or created is None:
        raise SystemExit('Source document requires structured provenance and creation time')
    mappingz='| 原始路径 | 归档内路径 |\n|---|---|\n';mappinge='| Original path | Path in archive |\n|---|---|\n'
    for path in originals:
        rel=Path(path).relative_to(base).as_posix() if is_files else Path(path).name+'/'
        row=f'| {code(path)} | {code(rel)} |\n';mappingz+=row;mappinge+=row
    if provenance is not None:
        def source_section(lang):
            fields = [("source_type", "来源类别", "Source category"),
                      ("device_name", "生成文件的设备品牌及型号", "Generating device brand and model"),
                      ("device_model", "单独提供的设备型号", "Separately provided device model"),
                      ("source_software", "生成或编辑文件的软件", "Creation or editing software"),
                      ("storage_source", "存储来源", "Storage location"),
                      ("purpose", "此归档的用途", "Purpose of this archive")]
            parts = ["### " + (zh if lang == "zh" else en) + "\n\n" + provenance_value(provenance.get(key), lang)
                     for key, zh, en in fields]
            parts += [("### 原始来源与归档路径\n\n" + mappingz if lang == "zh" else "### Original sources and archive paths\n\n" + mappinge),
                      ("### 相对路径基准目录" if lang == "zh" else "### Relative-path base directory") + "\n\n" + code(base),
                      ("### 创建时间" if lang == "zh" else "### Creation time") + "\n\n" + created,
                      ("### 备注" if lang == "zh" else "### Notes") + "\n\n" + provenance_value(provenance.get("notes"), lang)]
            evidence = provenance.get("metadata_evidence")
            if evidence is not None:
                parts.append(("### 元数据检测记录" if lang == "zh" else "### Metadata inspection record") + "\n\n" + provenance_value(evidence, lang))
            return "\n\n".join(parts)
        z, e = source_section("zh"), source_section("en")
    p.write_text(pair('来源信息 / Source Information',z,e))
    p=docs/'ARCHIVE_FORMAT.md';s=p.read_text();s=s.replace('# Archive Format','# 归档格式 / Archive Format',1);s=s.replace('Core Standards:', 'Use cases:\n\n- Video assets\n- Images\n- Aerial footage\n- Project files\n- NAS backups\n- Personal records\n\nCore Standards:');p.write_text(s)
    p=docs/'ARCHIVE_CONTENTS.md';s=p.read_text();s=s.replace('Directory Count (including the top-level directory)','Directory Count');s=re.sub(r'(: 1) files',r'\1 file',s)
    english='\n'.join(line for line in s.splitlines()[1:] if not line.startswith('> **注意'))
    zlines=[]
    for line in english.splitlines():
        if line.startswith('> **WARNING:'):
            line='> **注意：** 此文件仅是内容索引，不是完整性证明；完整性验证必须使用 SHA-512 清单。'
        elif line.startswith('This index was generated'):
            line='此索引根据实际恢复并与源清单核对过的文件和目录生成，仅用于浏览，不是完整性证明。'
        elif line == '| Type | Relative Path in Archive | Size (bytes) |':
            line='| 类型 | 归档内相对路径 | 大小（字节） |'
        elif line.startswith('| Directory |'):
            line=line.replace('| Directory |','| 目录 |',1)
        elif line.startswith('| File |'):
            line=line.replace('| File |','| 文件 |',1)
        elif line == '## File Type Statistics':
            line='## 文件类型统计'
        else:
            for old,new in [('Archive','归档'),('Created','创建时间'),('File Count','文件数量'),('Directory Count','目录数量'),('Total File Size','文件总大小')]:
                if line.startswith('- '+old+': '):
                    line='- '+new+'：'+line[len(old)+4:]
                    if old=='Total File Size':line=line.removesuffix(' bytes')+' 字节'
                    break
            else:
                line=re.sub(r'(: \d+) files?$',r'\1 个文件',line)
        zlines.append(line)
    z='\n'.join(zlines)
    p.write_text(pair('归档内容 / Archive Contents',z,english))
    p=docs/'STATISTICS.md';s=p.read_text().replace('# Archive Statistics','# 归档统计 / Archive Statistics',1).replace('目录数量（不含顶层目录）','清单内目录数量').replace('Source Directory Count (excluding the top-level directory)','Manifest Directory Count');a,b=s.split('## English',1);a=a.replace(' bytes',' 字节').replace(' seconds',' 秒');p.write_text(a+'## English'+b)
    p=docs/'archive-info.md';s=p.read_text().split('\n',1)[1];s=s.replace('Source Path:', 'Source Path:')
    s=s.replace('Any modification invalidates verification records.', 'Data changes require complete reverification; authorized documentation corrections must be recorded separately.')
    s=s.split('## Recovery',1)[0]+'## Recovery\n\n'+recovery_en+'\n'
    z=translate(s.split('## Recovery',1)[0])+'## 恢复步骤\n\n'+rz
    z+='\n\n压缩章节记录请求配置；实际属性与完整命令见 COMPRESSION_INFO.md。版本字段中的脚本实现版本不等于归档格式版本。具体原始路径见 SOURCE_INFO.md。'
    s+='\n\nThe Compression section records requested settings; see COMPRESSION_INFO.md for observed properties and the full command. The implementation version is distinct from the format version. See SOURCE_INFO.md for exact original paths.'
    # Label the common base accurately, retaining the English technical token for compatibility.
    s=s.replace('Source Path:', 'Source Path (relative-path base):')
    p.write_text(pair('归档信息 / Archive Information',z,s))
    p=docs/'verification-log.md';s=p.read_text().split('\n',1)[1].replace('- Completed:', '- Started:')
    s+='\n- Verification Record Generated: '+now+'\n- Completion Time: not recorded\n'
    if legacy:
        s+='\nThis is a documentation correction, not a rerun of the historical verification stages. The original completion time was not recorded accurately.\n'
    z=translate(s).replace('This is a documentation correction, not a rerun of the historical verification stages. The original completion time was not recorded accurately.','本次仅修订文档，未重新执行历史验证各阶段。原始完成时间没有被准确记录。')
    p.write_text(pair('验证记录 / Verification Log',z,s))
    p=bundle/'README.md';s=p.read_text();s=s.replace('- 字典大小：64 MiB','- 字典大小：64 MiB（请求配置上限）').replace('- 固实压缩：启用','- 固实压缩：启用（请求选项）').replace('- Dictionary: 64 MiB','- Dictionary: 64 MiB (requested limit)').replace('- Solid: Enabled','- Solid: Enabled (requested option)')
    s=s.replace('## 4. 恢复步骤','实际算法及字典标识：'+code(actual_method)+'；实际固实分组：'+code(actual_solid)+'。单个非空文件不形成多文件固实分组；小数据可使用较小字典。\n\n## 4. 恢复步骤')
    s=s.replace('## 4. Recovery Procedure','Observed method/dictionary: '+code(actual_method)+'; observed solid grouping: '+code(actual_solid)+'. A single nonempty file does not form a multi-file solid group; small inputs may use smaller dictionaries.\n\n## 4. Recovery Procedure')
    s=s.replace('## 4. 恢复步骤\n','## 4. 恢复步骤\n\n'+rz.split('1. ',1)[0]).replace('## 4. Recovery Procedure\n','## 4. Recovery Procedure\n\n'+recovery_en.split('1. ',1)[0]);p.write_text(s)
    return validate_documents(bundle)

def validate_documents(bundle):
    paths=[bundle/'README.md']+[p for p in (bundle/'Documents').glob('*.md') if p.name!='SHA512.md']
    assert len(paths)==8
    expected={}
    for p in paths:
        s=p.read_text();zh=re.search(r'^#{1,2} 中文$',s,re.M);en=re.search(r'^#{1,2} English$',s,re.M)
        if not zh or not en or zh.start()>=en.start():raise SystemExit(f'Bilingual document order invalid: {p}')
        if not re.search('[\u4e00-\u9fff]',s[zh.end():en.start()]):raise SystemExit(f'Missing Chinese content: {p}')
        zh_codes = re.findall(r'<code>(.*?)</code>', s[zh.end():en.start()], re.S)
        en_codes = re.findall(r'<code>(.*?)</code>', s[en.end():], re.S)
        if sorted(zh_codes) != sorted(en_codes):
            raise SystemExit(f'Bilingual paths or technical values differ: {p}')
        expected[p.relative_to(bundle).as_posix()]=s
    return expected

def record_completion(bundle):
    p=bundle/'Documents/verification-log.md';s=p.read_text();now=datetime.now().astimezone().isoformat(timespec='seconds')
    s=s.replace('完成时间：未记录','完成时间：'+now).replace('Completion Time: not recorded','Completion Time: '+now)
    p.write_text(s)
    if p.read_text()!=s:raise SystemExit('Completion record write verification failed')
    validate_documents(bundle)
