<!-- Copyright (C) 2026 Kevin Zheng; SPDX-License-Identifier: GPL-3.0-only -->
> 桌面版 1.0.1 覆盖说明（2026-10-03 用户明确要求）：下述上游文档的“默认 32 个文件”和“仅设备/软件标签”不再适用于本应用。应用对全部纳入归档的文件请求所有 ExifTool 可读取元数据，保留完整报告与逐文件错误，无抽样上限。归档核心、固定排除规则及五项来源确认仍保留。下方保留原始规范以说明来源。

---
name: sha512-7z-archive
description: >-
  Create Personal Cold Archive Format v1.0 packages for photography, video,
  aerial footage, NAS backups, project files, and other personal digital assets,
  using complete SHA-512, fixed LZMA2 Ultra 7z, recovery extraction, source
  consistency, documentation, statistics, and atomic publication gates. This is
  the sole creation entry point: every new archive request must execute the
  complete workflow. Use for new personal cold archives and for standalone
  inspection, verification, recovery testing, or hash checking of an existing
  archive.
---

# Personal Cold Archive Format

Version:

1.0

Status:

Stable / Frozen

Release Date:

2026-09-24

Maintenance Fix:

2026-10-02 — Added native single-file and explicit multi-file input support, preserving original-source hashing and full recovery verification without source-copy wrappers. Directory input behavior and format version remain unchanged.

2026-10-02 — Localized README Chinese headings and field labels, added the missing Chinese exclusion-rule reference, and validated Chinese and English sections independently. Format version, archive layout, compression, hashing, and recovery workflows remain unchanged. Existing published archives are not rewritten by this maintenance fix.

2026-09-25 — Added explicit `--output-dir` routing without changing the format. When supplied, the existing destination directory is used for space checks, staging, recovery extraction, final publication, and post-publication verification; when omitted, the source parent remains the destination. The fixed cross-platform system-entry exclusions are applied recursively and consistently to source inventory, SHA-512 scanning, 7z input, recovery scanning, and directory comparison; an end-to-end `.DS_Store` regression is mandatory. SMB/NFS compatibility self-tests run only in a verified local temporary directory. PHASE 10 recovery hashing on `smbfs` retries only the exact transient `File changed while hashing:` condition, at most five attempts with one second between attempts; all original SHA-512 and comparison gates remain mandatory. When macOS `renameatx_np(RENAME_EXCL)` explicitly reports unsupported on `smbfs`, publication uses the existing portable `require_absent` plus same-filesystem `os.rename` fallback. Format version and frozen archive rules are unchanged.

This skill is the only entry point for creating long-term cold archive packages for photography, video, aerial footage, NAS backups, project files, and other personal digital assets. Archive creation always executes the complete cold archive workflow. Never present hashing alone, compression alone, archive hashing alone, or folder organization alone as a completed new archive. Never skip recovery verification or live-source verification. Standalone inspection, verification, recovery testing, and hash checking are allowed only as maintenance of an existing archive.

## Required output

Obtain a user-specified human-readable `ArchiveName_RAW` and preserve it exactly. Derive `ArchiveName_DISPLAY` only by replacing every underscore (`_`) in `ArchiveName_RAW` with a hyphen (`-`). Publish inside an explicitly supplied `--output-dir`, or beside the source directory when that option is omitted, using the local creation date and only after every verification passes:

```text
YYYYMMDD_[ArchiveName_DISPLAY]_归档_[Archive SHA512 first 16 hex]/
├── README.md
├── [ArchiveName_RAW].7z
├── [ArchiveName_RAW].7z.sha512.md
└── Documents/
    ├── ARCHIVE_FORMAT.md
    ├── COMPRESSION_INFO.md
    ├── SHA512.md
    ├── archive-info.md
    ├── verification-log.md
    ├── ARCHIVE_CONTENTS.md
    ├── SOURCE_INFO.md
    └── STATISTICS.md
```

The root must contain only the bilingual UTF-8 `README.md`, the 7z archive, its SHA-512 Markdown, and `Documents/`. Put every other technical record in `Documents/`. Do not add unused files or put a format or Skill version in the directory name. Derive the directory suffix only from the first 16 lowercase hexadecimal characters of the final 7z SHA-512 after archive creation, `7z t`, real extraction verification, and final archive hashing have passed. The machine-tracking Archive ID remains `YYYYMMDD_[ArchiveName_RAW]_[digest16]`; keep it separate from the human-facing folder name `YYYYMMDD_[ArchiveName_DISPLAY]_归档_[digest16]`. Use `ArchiveName_RAW` unchanged for the 7z filename, checksum filename, Archive ID, metadata, and logs. Record both `ArchiveName_RAW` and `ArchiveName_DISPLAY` in `README.md`, `Documents/archive-info.md`, and `Documents/verification-log.md`. Do not apply any other normalization, use a random final name, overwrite an existing destination, or publish a partial result.

## 来源信息采集与交互 / Provenance intake

Before starting a new archive, inspect source metadata read-only, then collect five separate explicit answers. Do not silently mark all provenance fields “not provided” or infer capture hardware from the current Mac/NAS. This intake is agent-side: the archive CLI remains noninteractive and receives the resolved values through its existing provenance arguments.

1. Run `python3 -B scripts/inspect_source_metadata.py SOURCE [SOURCE ...]`. It prints JSON to stdout without modifying files. Use existing ExifTool only; never install a metadata tool automatically. It reads only device/software tags, not GPS, serial numbers, people or image contents. A default limit of 32 files bounds work; always disclose partial coverage and inspection errors. Do not describe an uninspected file as having no metadata. Increase `--limit` only when needed for the requested scope. Do not recursively unpack archives to obtain metadata.
2. Automatically record verified facts: original paths, single-file/multiple-file/directory input mode, included file count, size and observed filesystem. Record a supplied SMB URL as storage context; never guess a NAS model or network endpoint from a volume name. Distinguish capture/creation device, creation/editing/encoding software, current storage location, and the machine executing the archive.
3. Present metadata values as candidates, with source filename, original tag, extraction tool and inspection coverage. Metadata can be edited or stale. Preserve conflicting device values and their file mappings; do not choose one device for a mixed collection. Missing metadata means unknown, not proof that there is no device. CSV/TXT often provide no capture-device tags.
4. **Mandatory per-archive field confirmation.** Before each new archive, use `request_user_input_async` with exactly ONE question per call. Ask in the order below, followed by notes. After displaying each question, wait for the actual user reply before displaying the next question:
   - **来源类别 / Source category**
   - **生成此文件的设备品牌及型号 / Device make and model that generated the file**
   - **生成或编辑此文件的软件 / Software that generated or edited the file**
   - **此归档的用途 / Purpose of this archive**
   For each question, use the relevant metadata-supported candidate as the first/default option, display its actual value and evidence (file, tag, tool and coverage), and allow custom text or an explicit “未知／不填写 / Unknown or leave blank” response. A preselected option is NOT confirmation. If metadata provides no defensible value, state “元数据未检测到 / Not detected in metadata”; do not fabricate a default. File category may be a clearly labelled suggestion from detected file type rather than a proven business category. Archive purpose normally cannot be established from file metadata: show a relevant description/purpose tag only as an unconfirmed candidate, never infer future intent from capture hardware, location or file extension. A current user-supplied value takes priority as the displayed candidate; previous answers or batch defaults may prefill candidates but NEVER suppress these five confirmation questions for a new archive. Metadata describes the source, not the archive executor or the current storage hardware.
   Each field is independently accepted, corrected, or explicitly left unknown. If “自定义填写 / Custom” is selected without an actual value, request only that value. Never combine fields into one all-or-nothing acceptance. For multiple inputs with different devices or software, show mixed values with mappings and ask confirmation for the collection; do not choose a single model silently. For a batch of independently created archives, require all five confirmations per archive, even when shared values are prefilled. Do not reconfirm within the same archive attempt once the user has actually answered, unless the selected inputs or candidate values change. Notes is a mandatory separate question with exactly two choices: “无补充” and “自由填写”. The latter requires actual text before proceeding; it is not itself a completed answer.
5. **Wait for an explicit response.** This is required provenance confirmation, not a new authorization to archive. While waiting, only continue independent read-only preparation such as path, environment and disk-space checks. Do not start compression or publication until all five fields have an explicit submitted answer (notes requires “无补充” or actual free text). Elapsed time, silence, a preselected option and prior-task acceptance are not answers. Do not silently proceed with unknown values after a timeout. If the interactive tool is unavailable, ask the same five questions one at a time in conversation and wait after each; explain that a popup cannot be shown with the current tools. Cancellation stops the attempt. Follow a later explicit user override of this confirmation preference if one is given.

   **Asynchronous popup lifecycle — keep the turn active:** `request_user_input_async` returns when the popup is displayed, not when it is answered. While a popup is pending, DO NOT send a final-channel reply, end the turn, or mark the task/goal complete. A final reply is not a waiting mechanism. After independent read-only preparation, use the available interruptible `clock.sleep` tool in intervals of at most 60 seconds to yield execution while keeping this turn active. Each wakeup is only a chance to inspect newly delivered user messages; elapsed time never supplies an answer. If no reply arrived, keep the same popup pending and wait again; do not duplicate it, call the archive helper, or substitute defaults. Brief commentary may report the actual pending question, but never repeat a question already answered. This waiting is solely for the user's current popup response, not filesystem monitoring or archive polling. Respect cancellation or a request to stop waiting immediately.

   **Five-question state machine (mandatory):** Initialize `source_type`, `device`, `source_software`, `purpose`, and `notes` as pending for each new archive attempt. Record which question is currently displayed. Before every wait or progress message, first process any actual user reply already delivered. Transition that exact field to submitted, preserve its answer, then immediately ask the next unanswered question in the SAME active turn. Do not say “waiting for device” after the device reply arrived. Do not reset submitted fields when a new message arrives. Candidate/default values, tool returns, UI closure, skip, timeout and prior archive records are never submissions. Selecting “自由填写” without text keeps notes pending and requires the actual text. Do not display multiple outstanding forms. Once all five actual answers are submitted, invoke the complete archive workflow without an extra “continue” request. Until then, no archive creation or success report is allowed. On cancellation, stop without filling remaining fields.

   **Tool availability fallback:** If an interruptible waiting tool is unavailable, do not pretend an asynchronous popup can remain active after a final reply. Before opening a popup, explain the limitation and use an ordinary single-question conversation handoff instead; resume on the actual next reply. Use a synchronous question tool only when it is available and its tool instructions permit required questions in the current mode. Never use shell sleeps or background monitors as a substitute. This fallback is a waiting handoff, never archive completion.

   **Executable gate and exact answer mapping:** Every agent-initiated new archive MUST use `--require-source-confirmation --source-answers-json PATH`. A checked list of confirmed field names is not sufficient. Preserve actual submitted answers by stable question IDs, never reconstruct them from a prose summary or positional order. The five IDs are `source_type`, `device`, `source_software`, `purpose`, `notes`. The helper derives field values from these answers and checks the rendered Chinese/English fields before and after publication. Unanswered questions, source-path mismatches, incomplete custom values, and conflicting scalar flags block execution before environment checks. Tools cannot prove that an agent transcribed a real response; never fabricate responses to satisfy the gate. Save only actual submitted answers from this attempt.
   Answer JSON schema: `{"schema_version":2,"sources":["/absolute/source/path"],"answers":{"source_type":{"status":"submitted","answer":"CSV 数据文件","en":"CSV data file"},"device":{"status":"submitted","answer":"未知／不填写"},"source_software":{"status":"submitted","answer":"未知／不填写"},"purpose":{"status":"submitted","answer":"测试","en":"Test"},"notes":{"status":"submitted","answer":"无补充"}}}`. Paths must match the exact current resolved inputs. Schema v2 requires `status: "submitted"` on every answer; schema v1 and pending/prefilled/skipped/cancelled records are rejected. Set this status only from an actual user reply, never to satisfy validation. The `answer` is the exact submitted field value (or the actual value explicitly adopted from a displayed metadata candidate); `en` is its English translation for custom/provided answers. Unknown/blank/no-notes states use fixed translations. Never assign the purpose answer to source_type. Optional explicit device `brand` and `model` objects may be supplied only when those components were actually provided; otherwise preserve the whole combined device answer without guessing its split. “未知／不填写” maps to unknown, not missing information. “无补充” produces notes containing only that phrase and its English translation. All creation calls, including direct CLI calls, require --source-answers-json. Omitting --require-source-confirmation never disables the gate. Tests must supply explicit synthetic fixture answers for temporary test inputs.

6. Preserve user answers as distinct field states. “不清楚 / Unknown” is an explicit answer, not “未提供 / Not provided”. “无补充 / No additional notes” is an explicit notes answer, not permission to insert system-generated text. Purpose has its own field. User notes contain ONLY the user's notes; never append metadata inspection details, tool paths, confirmation history, source mappings or summaries of other fields. Store inspection evidence separately under “元数据检测记录 / Metadata inspection record”. Render Chinese values only in the Chinese section, and English values only in the English section.
   Use `--source-answers-json` exclusively for submitted user fields. Optional `--source-details-json` accepts only `storage_source` and `metadata_evidence`, using separate `zh` and `en` strings with state `provided`, or an explicit unknown/missing state. Notes and purpose must never be inserted into metadata evidence. Explicit unknown answers remain unknown; only genuinely absent optional facts are not provided. Original path mappings are generated separately. Legacy scalar user-field flags cannot be combined with the mandatory answer record.


This intake does not modify existing bundles or rerun a cancelled batch. It does not replace source SHA-512, extraction, or final verification. Direct CLI creation also requires the source-bound answer record; interactive forms are provided by the agent, not by a terminal script.

## Complete creation workflow

Run every stage below for every new archive:

1. **Environment check.** Check `7z`, `7zz`, and `7za` in that detection order and report the path and version of every available command. Detection does not choose the executable. Unless the user explicitly specifies an executable, select in the independent priority order `7zz`, `7z`, `7za`. Use the selected executable for creation, property inspection, testing, and extraction. Record the OS, CPU architecture, Python version, source and target filesystem types, selected executable, version, and all detected commands. Never install software without separate authorization.
2. **Path and type check.** Resolve the exact source and final parent. If `--output-dir` is supplied, require it to be an existing non-symbolic-link filesystem directory and use it as the final parent; mounted SMB paths such as `/Volumes/share/folder` are supported, while `smb://` URLs are not filesystem paths and must first be mounted. If the option is omitted, use the source parent exactly as before. Refuse an output directory equal to or below the source because target workspaces would otherwise mutate the live source. For one directory, archive the directory itself so extraction recreates its top-level folder. Also accept a single regular file or multiple explicitly selected regular files without temporary source copies. For file inputs, use their common parent directory as the path base, preserving relative paths (including subdirectories and same-named files in different directories); a single file restores directly at the extraction root. Scan and rehash only selected original files. Reject duplicate inputs, mixed file/directory selections, special files, symlinks, a filesystem-root common base, and explicit files whose relative path matches fixed exclusions. Record every original absolute path and its archive path in SOURCE_INFO.md. Never silently include unselected sibling files. For file mode only, use -spd to disable operand wildcard expansion; fixed compression parameters and exclusion rules remain unchanged. Refuse a filesystem root, an existing destination, symbolic links, devices, sockets, FIFOs, and all other special included entries. Never alter the source.
3. **Apply only the fixed system and temporary-entry exclusions.** Exclude `.DS_Store`, `.AppleDouble`, `._*`, `.Spotlight-V100`, `.Trashes`, `.fseventsd`, `.DocumentRevisions-V100`, `.TemporaryItems`, `Thumbs.db`, `ehthumbs.db`, `Desktop.ini`, `$RECYCLE.BIN`, `System Volume Information`, `.Trash-*`, `.nfs*`, `lost+found`, `.nomedia`, `*.tmp`, `*.temp`, `*.bak`, and `*~`, at any depth. Apply the same exclusion model to source scanning, SHA-512 generation, compression input, and recovery validation. These rules affect archive scanning only: never delete or modify excluded source entries. Record the complete rule set under `## Exclusion Rules` in `Documents/archive-info.md`.
4. **Disk-space check.** Calculate and report included source bytes, compression workspace of at least `source_size × 1.1`, extraction-verification workspace of at least `source_size × 1.1`, an additional safety buffer of at least 1 GiB, target free bytes, and total required bytes. Measure free space on the resolved output directory. Stop before hashing or compression if free space is less than `(source_size × 2.2) + 1 GiB`.
5. **Filename compatibility test and source manifest.** Run all compatibility-test fixtures only in a unique, verified local temporary directory such as `/tmp`; never create them beside the source, on SMB/NFS/NAS storage, or in the output directory. Prove with the selected 7-Zip executable that representative UTF-8, Chinese, Japanese, Korean, emoji, space-containing, special-symbol, and long filenames survive archive creation, testing, full-path extraction, and SHA-512 comparison. Always remove the compatibility-test directory on success or failure and fail if cleanup leaves it behind. Record the local test path, local filesystem type, and the SMB/NFS metadata-synchronization avoidance reason in the generated logs. Before source compression, hash every included regular file and write UTF-8 `Documents/SHA512.md` in staging. Record `Relative Path`, `Size Bytes`, `Modified Time`, and `SHA-512`. Preserve Unicode, Chinese, spaces, and special characters by losslessly encoding Markdown-sensitive and line-break characters so every row remains parseable. Modified time is auxiliary only; the final integrity decision remains based on path, exact byte size, and SHA-512. Parse and verify the written manifest.
6. **Compression.** Create `[ArchiveName_RAW].7z` with all fixed switches: `-t7z -m0=lzma2 -mx=9 -md=64m -mfb=64 -ms=on`, plus only the fixed system-exclusion switches. Use `./SOURCE_NAME` for directory mode and one literal `-i!relative/path` include switch per selected file (no positional file operands, to preserve paths and avoid same-basename collisions), so names beginning with `-` or `@` remain data.
7. **Compression verification.** Prove that the executed command contains every required compression switch and system exclusion. Inspect `7z l -slt` and require `Type = 7z`; require a method containing `LZMA2` when a non-empty stream exists. Require `Solid = +` when at least two non-empty streams exist. With fewer than two non-empty streams, `Solid = -` means no solid grouping can exist; prove the requested solid setting from `-ms=on`. Accept a smaller displayed dictionary such as `LZMA2:12` only when execution proves `-md=64m`; likewise prove Fast Bytes from `-mfb=64`.
8. **Archive test and real recovery.** Require a successful 7-Zip `t` test, then extract with full paths into a new empty temporary directory inside the resolved output directory and therefore on the target filesystem. Reject any excluded entry found in the recovered archive. Rehash every recovered regular file and require a 100% path, size, and SHA-512 match with `Documents/SHA512.md`; also require the complete included directory set, including empty directories, to match. On `smbfs` only, retry this unchanged recovered-file hash scan at most five times with a one-second delay only when the exact transient `File changed while hashing:` condition occurs; never retry or suppress any other failure. A successful `7z t` alone is never sufficient.
9. **Source freeze verification.** Rescan and rehash the live source under the same fixed exclusions. Any added, removed, resized, type-changed, hash-changed, or directory-changed included data invalidates the archive and stops publication.
10. **Format documentation, technical records, source context, and identity.** Write root-level `[ArchiveName_RAW].7z.sha512.md` with the final archive filename, exact byte size, and SHA-512, then parse and verify it. Only now derive the 16-character digest suffix, Archive ID, and final folder name. Write bilingual `Documents/ARCHIVE_FORMAT.md` naming `Personal Cold Archive Format`, version `1.0`, its purpose, use cases, and core standards. Write bilingual `Documents/COMPRESSION_INFO.md` with the actual 7-Zip version and executable, Format `7z`, Method `LZMA2`, Level `Ultra`, Dictionary `64 MiB`, Fast Bytes `64`, Solid `Enabled`, required switches, and complete compression parameters. Write `Documents/ARCHIVE_CONTENTS.md` from the verified recovered archive tree with relative paths, sizes, counts, total size, and case-normalized extension counts; begin it with Chinese and English warnings that it is only an inventory and SHA-512 manifests are required for integrity verification. Write bilingual `Documents/SOURCE_INFO.md` with source type, device, model, software, storage source, original path, creation time, and notes. Require explicit answers or allowed explicit unknown choices before execution; retain exact original paths and creation time. Unanswered required questions block creation. Write bilingual `Documents/STATISTICS.md` with creation time, verified file and directory counts, source and archive bytes, archive-to-source ratio, excluded-entry count, and measured compression duration. Write `Documents/archive-info.md` with `ArchiveName_RAW`, `ArchiveName_DISPLAY`, Archive ID, Archive Folder Name, format and version, creation time, fixed compression settings, statistics, exclusions, Compatibility Test results, and toolchain. Write `Documents/verification-log.md` with both archive-name forms and every acceptance result. Validate every generated document before and after publication.
11. **Human-readable README.** Write UTF-8 `README.md` with a complete Simplified Chinese section first and matching English section second. The Chinese section must use numbered headings `归档标识`, `归档格式`, `压缩信息`, `恢复步骤`, `排除文件`, and `归档规则`; the English section uses `Archive Identity`, `Archive Format`, `Compression Information`, `Recovery Procedure`, `Excluded Files`, and `Archive Policy`. Use Chinese field labels and explanations in the Chinese section, retaining technical identifiers `ArchiveName_RAW` and `ArchiveName_DISPLAY` with Chinese explanations. Preserve format names, paths, algorithm identifiers, numeric parameters, and exclusion patterns exactly. Include the exclusion-rule reference to `Documents/archive-info.md` in both languages. Validate each language section independently so English text cannot satisfy missing Chinese content. Record `ArchiveName_RAW`, `ArchiveName_DISPLAY`, the final folder name, and digest prefix; name `Personal Cold Archive Format` version `1.0`; state 7z, LZMA2, Ultra, 64 MiB dictionary, Fast Bytes 64, and Solid Enabled; give all five recovery steps from archive checksum verification through restored SHA-512 and directory comparison; directly list the exclusion rules. Preserve the immutable archive policy and state that `ARCHIVE_CONTENTS.md` is an inventory, not integrity proof.
12. **Transactional publication.** Create every output in a temporary staging directory inside the resolved output directory. Before and after exclusive atomic publication within that same directory, verify the exact required layout, archive digest, parsed manifests, content-index counts and content, README presence, and recorded output location. Publish only after source hashing, compression, property verification, archive testing, real extraction verification, source freeze verification, archive hashing, and all document generation succeed. On any failure, remove staging and recovery directories, leave no final archive directory, preserve the source, and never overwrite an existing destination.

## Deterministic helper

For every new cold archive, run the complete helper rather than reproducing partial stages:

```sh
python3 scripts/create_archive_bundle.py SOURCE [SOURCE ...] --archive-name ARCHIVE_NAME --source-answers-json ANSWERS.json [--output-dir OUTPUT_DIR]
```

Pass an existing local or mounted-filesystem directory with `--output-dir` to place the completed bundle and all target-filesystem workspaces there. Omit it to preserve the original source-parent behavior. Pass the submitted answers through --source-answers-json; pass only storage context and inspection evidence through --source-details-json. Never omit an explicitly unknown answer or convert it to not provided. Use `--seven-zip PROGRAM` only when the user explicitly selects a 7-Zip executable. The helper has no partial-creation mode. For an existing archive, perform only the requested read-only inspection, verification, recovery test, or hash check unless the user explicitly asks to create a new archive.

For maintenance regression testing of the local compatibility workspace, run the read-only source-context check against both a local directory and an available SMB/NFS source directory:

```sh
python3 scripts/test_compatibility_workspace.py --source-dir SOURCE_DIR
```

Add `--verify-failure-cleanup` when explicitly testing cleanup after a forced compatibility-test failure. The regression helper never writes into `SOURCE_DIR` or its parent.

For the bounded PHASE 10 SMB recovery stability behavior, run:

```sh
python3 scripts/test_smb_recovery_stability.py
```

For explicit-output and default-behavior regression coverage, run:

```sh
python3 scripts/test_output_directory.py
```

For the recursive cross-platform system-entry exclusions, including root-level and nested `.DS_Store`, run the complete archive regression:

```sh
python3 scripts/test_system_exclusions.py
```

### File input examples

```sh
python3 scripts/create_archive_bundle.py /path/Disks.csv --archive-name Disks.csv --source-answers-json ANSWERS.json --output-dir /path/output
python3 scripts/create_archive_bundle.py /path/a.csv /path/sub/b.txt --archive-name SelectedFiles --source-answers-json ANSWERS.json --output-dir /path/output
```

For multiple-file inputs, ask for an archive name if the user has not supplied one. Never select additional files based on inferred relevance. The output parent may be the common source base in file mode because only explicit files are scanned; directory mode retains the existing output-descendant prohibition.

Validate native file input support with `python3 scripts/test_file_inputs.py`; this uses a local temporary workspace and verifies single files, exact multi-file selection, path preservation, unchanged original files, directory compatibility, rejected inputs, and cleanup.

### Bilingual metadata and accurate provenance

All eight non-hash Markdown documents (README and seven Documents files) must contain Simplified Chinese first, then matching English. The two SHA-512 manifests retain their machine-parseable layout. Generate both sections from the same metadata and check them before and after publication. Record actual original paths separately from the common relative-path base; preserve user context and readable path mappings. Use bundle-root-relative references for recovery instructions. Distinguish requested compression settings from actual 7z properties and retain the full executed argument list, including file-selection switches. Directory counts must describe the actual input mode. Record start and completion separately; only record completion after successful final checks, and never invent historical completion timestamps or commands. Script implementation version and archive format version are different identifiers. Explicitly authorized documentation-only corrections may revise metadata without changing archive bytes or hash manifests; preserve an external correction log and mark historical evidence limits.
