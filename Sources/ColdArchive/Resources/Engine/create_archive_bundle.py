#!/usr/bin/env python3
# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Create a complete, verified SHA-512 + LZMA2 7z cold archive."""

from __future__ import annotations

import argparse
import ctypes
from dataclasses import dataclass
from datetime import datetime
import errno
import hashlib
import html
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import time


CHUNK_SIZE = 8 * 1024 * 1024
SOURCE_MANIFEST_NAME = "SHA512.md"
ARCHIVE_CONTENTS_NAME = "ARCHIVE_CONTENTS.md"
INFO_NAME = "archive-info.md"
VERIFICATION_LOG_NAME = "verification-log.md"
SOURCE_INFO_NAME = "SOURCE_INFO.md"
STATISTICS_NAME = "STATISTICS.md"
ARCHIVE_FORMAT_NAME = "ARCHIVE_FORMAT.md"
COMPRESSION_INFO_NAME = "COMPRESSION_INFO.md"
README_NAME = "README.md"
INFO_DIRECTORY_NAME = "Documents"
FORMAT_NAME = "Personal Cold Archive Format"
FORMAT_VERSION = "1.0"
SKILL_VERSION = "3.0.0"
SMB_RECOVERY_STABILITY_MAX_ATTEMPTS = 5
SMB_RECOVERY_STABILITY_DELAY_SECONDS = 1.0
REQUIRED_SWITCHES = (
    "-t7z",
    "-m0=lzma2",
    "-mx=9",
    "-md=64m",
    "-mfb=64",
    "-ms=on",
)
SPACE_SAFETY_BYTES = 1024 * 1024 * 1024
SYSTEM_EXCLUDED_NAMES = (
    ".DS_Store",
    ".AppleDouble",
    ".Spotlight-V100",
    ".Trashes",
    ".fseventsd",
    ".DocumentRevisions-V100",
    ".TemporaryItems",
    "Thumbs.db",
    "ehthumbs.db",
    "Desktop.ini",
    "$RECYCLE.BIN",
    "System Volume Information",
    "lost+found",
    ".nomedia",
)
SYSTEM_EXCLUDED_PATTERNS = (
    "._*",
    ".Trash-*",
    ".nfs*",
    "*.tmp",
    "*.temp",
    "*.bak",
    "*~",
)
SYSTEM_EXCLUSION_SWITCHES = tuple(
    f"-xr!{name}" for name in (*SYSTEM_EXCLUDED_NAMES, *SYSTEM_EXCLUDED_PATTERNS)
)


@dataclass(frozen=True)
class FileRecord:
    size: int
    digest: str
    modified_time: str | None = None


@dataclass(frozen=True)
class CompatibilityTestResult:
    location: str
    filesystem: str


@dataclass(frozen=True)
class RecoveryScanResult:
    records: dict[str, FileRecord]
    directories: set[str]
    excluded: dict[str, str]
    attempts: int
    mode: str


def sha512(path: Path) -> str:
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode):
        raise SystemExit(f"Not a regular file while hashing: {path}")
    digest = hashlib.sha512()
    with path.open("rb") as stream:
        while chunk := stream.read(CHUNK_SIZE):
            digest.update(chunk)
    after = path.lstat()
    stable_before = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
    stable_after = (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
    if stable_before != stable_after or not stat.S_ISREG(after.st_mode):
        raise SystemExit(f"File changed while hashing: {path}")
    return digest.hexdigest()


def markdown_name(value: str) -> str:
    return (
        html.escape(value, quote=False)
        .replace("|", "&#124;")
        .replace("\r", "&#13;")
        .replace("\n", "&#10;")
    )


def archive_name_display(archive_name_raw: str) -> str:
    """Derive the human-facing archive name without changing the raw name."""

    return archive_name_raw.replace("_", "-")


def exclusion_rule(name: str) -> str | None:
    if name in SYSTEM_EXCLUDED_NAMES:
        return name
    pattern_checks = (
        (name.startswith("._"), "._*"),
        (name.startswith(".Trash-"), ".Trash-*"),
        (name.startswith(".nfs"), ".nfs*"),
        (name.endswith(".tmp"), "*.tmp"),
        (name.endswith(".temp"), "*.temp"),
        (name.endswith(".bak"), "*.bak"),
        (name.endswith("~"), "*~"),
    )
    for matches, pattern in pattern_checks:
        if matches:
            return pattern
    return None


def source_tree(root: Path) -> tuple[list[Path], set[str], dict[str, str]]:
    """Return included files/directories and excluded OS-generated entries."""

    files: list[Path] = []
    directories: set[str] = set()
    excluded: dict[str, str] = {}

    def visit(directory: Path) -> None:
        try:
            entries = sorted(os.scandir(directory), key=lambda entry: entry.name)
        except OSError as error:
            raise SystemExit(f"Cannot scan source directory {directory}: {error}")
        for entry in entries:
            path = Path(entry.path)
            relative = path.relative_to(root).as_posix()
            if rule := exclusion_rule(entry.name):
                excluded[relative] = rule
                continue
            try:
                mode = entry.stat(follow_symlinks=False).st_mode
            except OSError as error:
                raise SystemExit(f"Cannot inspect source entry {path}: {error}")
            if stat.S_ISLNK(mode):
                raise SystemExit(f"Unsupported source entry (symbolic link): {path}")
            if stat.S_ISDIR(mode):
                directories.add(relative)
                visit(path)
            elif stat.S_ISREG(mode):
                files.append(path)
            else:
                raise SystemExit(f"Unsupported source entry (special file): {path}")

    visit(root)
    return files, directories, excluded


def inventory_size(source: Path) -> tuple[int, int, set[str], dict[str, str]]:
    files, directories, excluded = source_tree(source)
    return len(files), sum(path.lstat().st_size for path in files), directories, excluded


def scan_hashes(root: Path, selected_files: list[Path] | None = None) -> tuple[dict[str, FileRecord], set[str], dict[str, str]]:
    records: dict[str, FileRecord] = {}
    if selected_files is None:
        files, directories, excluded = source_tree(root)
    else:
        files = selected_files
        directories = set()
        excluded = {}
        for path in files:
            if path.is_symlink() or not stat.S_ISREG(path.lstat().st_mode):
                raise SystemExit(f"Selected input is no longer a regular file: {path}")
            relative = path.relative_to(root)
            if path.resolve(strict=True) != path:
                raise SystemExit(f"Selected input path changed through a symbolic link: {path}")
            for part in relative.parts:
                if exclusion_rule(part):
                    raise SystemExit(f"Explicitly selected input matches an exclusion: {path}")
            directories.update(parent.as_posix() for parent in relative.parents if parent != Path('.'))
    for path in files:
        relative = path.relative_to(root).as_posix()
        file_stat = path.lstat()
        modified_time = datetime.fromtimestamp(
            file_stat.st_mtime_ns / 1_000_000_000
        ).astimezone().isoformat(timespec="microseconds")
        records[relative] = FileRecord(
            size=file_stat.st_size,
            digest=sha512(path),
            modified_time=modified_time,
        )
        print(f"HASHED {relative}", flush=True)
    return records, directories, excluded


def scan_recovered_hashes_with_smb_stability(
    root: Path, target_filesystem: str
) -> RecoveryScanResult:
    """Retry only transient smbfs metadata changes around recovered-file hashing."""

    if not target_filesystem.casefold().startswith("smb"):
        records, directories, excluded = scan_hashes(root)
        print(
            "SMB_RECOVERY_STABILITY NOT_REQUIRED "
            f"filesystem={target_filesystem}",
            flush=True,
        )
        return RecoveryScanResult(
            records=records,
            directories=directories,
            excluded=excluded,
            attempts=1,
            mode="not required",
        )

    for attempt in range(1, SMB_RECOVERY_STABILITY_MAX_ATTEMPTS + 1):
        try:
            records, directories, excluded = scan_hashes(root)
        except SystemExit as error:
            transient = str(error).startswith("File changed while hashing:")
            if not transient or attempt == SMB_RECOVERY_STABILITY_MAX_ATTEMPTS:
                raise
            print(
                "SMB_RECOVERY_STABILITY RETRY "
                f"attempt={attempt} max={SMB_RECOVERY_STABILITY_MAX_ATTEMPTS} "
                f"reason={error}",
                flush=True,
            )
            time.sleep(SMB_RECOVERY_STABILITY_DELAY_SECONDS)
            continue
        print(
            "SMB_RECOVERY_STABILITY PASS "
            f"attempts={attempt} max={SMB_RECOVERY_STABILITY_MAX_ATTEMPTS}",
            flush=True,
        )
        return RecoveryScanResult(
            records=records,
            directories=directories,
            excluded=excluded,
            attempts=attempt,
            mode="bounded smbfs retry",
        )

    raise AssertionError("unreachable SMB recovery stability state")


def require_no_excluded_entries(excluded: dict[str, str], label: str) -> None:
    if excluded:
        paths = ", ".join(sorted(excluded))
        raise SystemExit(f"{label} contains excluded entries: {paths}")


def write_manifest(manifest: Path, records: dict[str, FileRecord]) -> None:
    temporary = manifest.with_name(f".{manifest.name}.tmp-{os.getpid()}")
    try:
        with temporary.open("x", encoding="utf-8", newline="\n") as output:
            output.write("# Source SHA-512 Manifest\n\n")
            output.write(f"- File Count: {len(records)}\n")
            output.write("- Hash Algorithm: SHA-512\n\n")
            output.write("| Relative Path | Size Bytes | Modified Time | SHA-512 |\n")
            output.write("|---|---:|---|---|\n")
            for relative, record in records.items():
                if record.modified_time is None:
                    raise SystemExit(f"Missing modified time for source file: {relative}")
                output.write(
                    f"| <code>{markdown_name(relative)}</code> | {record.size} | "
                    f"{record.modified_time} | "
                    f"<code>{record.digest}</code> |\n"
                )
        os.replace(temporary, manifest)
    finally:
        if temporary.exists():
            temporary.unlink()


def read_manifest(manifest: Path) -> dict[str, FileRecord]:
    records: dict[str, FileRecord] = {}
    declared_count: int | None = None
    count_pattern = re.compile(r"^- File Count: ([0-9]+)$")
    row_pattern = re.compile(
        r"^\| <code>(.*?)</code> \| ([0-9]+) \| (.*?) \| "
        r"<code>([0-9a-f]{128})</code> \|$"
    )
    with manifest.open("r", encoding="utf-8", newline="") as stream:
        for raw_line in stream:
            line = raw_line.rstrip("\n")
            if count_match := count_pattern.match(line):
                if declared_count is not None:
                    raise SystemExit(f"Duplicate file count in source manifest: {manifest}")
                declared_count = int(count_match.group(1))
                continue
            if not (match := row_pattern.match(line)):
                continue
            relative = html.unescape(match.group(1))
            if relative in records:
                raise SystemExit(f"Duplicate path in source manifest: {relative}")
            modified_time = match.group(3)
            if not modified_time:
                raise SystemExit(f"Missing modified time in source manifest: {relative}")
            records[relative] = FileRecord(
                size=int(match.group(2)),
                digest=match.group(4),
                modified_time=modified_time,
            )
    if declared_count is None or declared_count != len(records):
        raise SystemExit(
            f"Invalid source manifest file count in {manifest}: "
            f"declared {declared_count!r}, parsed {len(records)}."
        )
    return records


def compare_records(
    expected: dict[str, FileRecord], actual: dict[str, FileRecord], label: str
) -> None:
    expected_names = set(expected)
    actual_names = set(actual)
    added = sorted(actual_names - expected_names)
    removed = sorted(expected_names - actual_names)
    resized = sorted(
        name
        for name in expected_names & actual_names
        if expected[name].size != actual[name].size
    )
    changed = sorted(
        name
        for name in expected_names & actual_names
        if expected[name].digest != actual[name].digest
    )
    if added or removed or resized or changed:
        details = []
        for category, values in (
            ("added", added),
            ("removed", removed),
            ("resized", resized),
            ("hash-changed", changed),
        ):
            if values:
                details.append(f"{category}: " + ", ".join(values))
        raise SystemExit(f"{label} verification failed; " + "; ".join(details))
    print(f"{label} MATCH ({len(expected)} files)", flush=True)


def compare_directories(expected: set[str], actual: set[str], label: str) -> None:
    added = sorted(actual - expected)
    removed = sorted(expected - actual)
    if added or removed:
        details = []
        if added:
            details.append("added: " + ", ".join(added))
        if removed:
            details.append("removed: " + ", ".join(removed))
        raise SystemExit(f"{label} directory verification failed; " + "; ".join(details))
    print(f"{label} DIRECTORIES MATCH ({len(expected)} directories)", flush=True)


def seven_zip_version(command: str) -> str:
    try:
        result = subprocess.run(
            [command, "--help"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
    except OSError as error:
        return f"Unavailable ({error})"
    lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    identified = next((line for line in lines if "7-Zip" in line), None)
    if identified:
        return identified
    if lines:
        return lines[0]
    return f"Unknown (help exit status {result.returncode})"


def detect_7zip() -> list[tuple[str, str, str]]:
    available: list[tuple[str, str, str]] = []
    for candidate in ("7z", "7zz", "7za"):
        if resolved := shutil.which(candidate):
            path = str(Path(resolved).resolve())
            version = seven_zip_version(path)
            available.append((candidate, path, version))
            print(
                f"AVAILABLE {candidate} PATH={path} VERSION={version}",
                flush=True,
            )
        else:
            print(f"NOT_FOUND {candidate}", flush=True)
    if not available:
        print("AVAILABLE none (checked 7z, 7zz, 7za)", flush=True)
    return available


def select_7zip(
    explicit: str | None, available: list[tuple[str, str, str]]
) -> tuple[str, str]:
    if explicit:
        resolved = (
            shutil.which(explicit)
            if os.sep not in explicit
            else str(Path(explicit).expanduser().resolve())
        )
        if not resolved or not Path(resolved).is_file() or not os.access(resolved, os.X_OK):
            raise SystemExit(f"7-Zip executable not found: {explicit}")
        path = str(Path(resolved).resolve())
        return path, seven_zip_version(path)

    available_by_name = {
        command_name: (command_path, version)
        for command_name, command_path, version in available
    }
    for preferred in ("7zz", "7z", "7za"):
        if preferred in available_by_name:
            return available_by_name[preferred]
    raise SystemExit("No 7-Zip CLI found in PATH (checked 7z, 7zz, and 7za).")


def filesystem_type(path: Path) -> str:
    if platform.system() == "Darwin":
        class DarwinStatFs(ctypes.Structure):
            _fields_ = [
                ("f_bsize", ctypes.c_uint32),
                ("f_iosize", ctypes.c_int32),
                ("f_blocks", ctypes.c_uint64),
                ("f_bfree", ctypes.c_uint64),
                ("f_bavail", ctypes.c_uint64),
                ("f_files", ctypes.c_uint64),
                ("f_ffree", ctypes.c_uint64),
                ("f_fsid", ctypes.c_int32 * 2),
                ("f_owner", ctypes.c_uint32),
                ("f_type", ctypes.c_uint32),
                ("f_flags", ctypes.c_uint32),
                ("f_fssubtype", ctypes.c_uint32),
                ("f_fstypename", ctypes.c_char * 16),
                ("f_mntonname", ctypes.c_char * 1024),
                ("f_mntfromname", ctypes.c_char * 1024),
                ("f_reserved", ctypes.c_uint32 * 8),
            ]

        result = DarwinStatFs()
        libc = ctypes.CDLL(None, use_errno=True)
        libc.statfs.argtypes = [ctypes.c_char_p, ctypes.POINTER(DarwinStatFs)]
        libc.statfs.restype = ctypes.c_int
        if libc.statfs(os.fsencode(path), ctypes.byref(result)) != 0:
            error_number = ctypes.get_errno()
            raise SystemExit(
                f"Cannot determine filesystem type for {path}: "
                f"{os.strerror(error_number)}"
            )
        value = bytes(result.f_fstypename).split(b"\0", 1)[0].decode("ascii")
        if not value:
            raise SystemExit(f"Filesystem type is empty for {path}.")
        return value

    command = ["stat", "-f", "-c", "%T", str(path)]
    try:
        result = subprocess.run(
            command,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Cannot determine filesystem type for {path}: {error}")
    value = result.stdout.strip()
    if not value:
        raise SystemExit(f"Filesystem type is empty for {path}.")
    return value


def is_network_filesystem(filesystem: str) -> bool:
    normalized = filesystem.casefold()
    return normalized.startswith(("smb", "nfs", "afp", "cifs", "webdav", "sshfs"))


def local_compatibility_temp_parent() -> tuple[Path, str]:
    """Select a writable local temporary directory for compatibility fixtures."""

    candidates: list[Path] = []
    if platform.system() == "Darwin":
        candidates.append(Path("/tmp"))
    if configured_tmp := os.environ.get("TMPDIR"):
        candidates.append(Path(configured_tmp))
    candidates.append(Path(tempfile.gettempdir()))

    checked: set[Path] = set()
    failures: list[str] = []
    for candidate in candidates:
        try:
            resolved = candidate.expanduser().resolve(strict=True)
        except OSError as error:
            failures.append(f"{candidate}: {error}")
            continue
        if resolved in checked:
            continue
        checked.add(resolved)
        if not resolved.is_dir():
            failures.append(f"{resolved}: not a directory")
            continue
        if not os.access(resolved, os.W_OK | os.X_OK):
            failures.append(f"{resolved}: not writable/searchable")
            continue
        candidate_filesystem = filesystem_type(resolved)
        if is_network_filesystem(candidate_filesystem):
            failures.append(
                f"{resolved}: network filesystem {candidate_filesystem} is not allowed"
            )
            continue
        return resolved, candidate_filesystem

    raise SystemExit(
        "No writable local temporary directory is available for the filename "
        "compatibility test: " + "; ".join(failures)
    )


def publish_directory_exclusive(
    staging: Path, final: Path, *, allow_unsupported_fallback: bool = False
) -> None:
    """Atomically rename staging to final without replacing an existing path."""

    libc = ctypes.CDLL(None, use_errno=True)
    source = os.fsencode(staging)
    destination = os.fsencode(final)
    if platform.system() == "Darwin" and hasattr(libc, "renameatx_np"):
        at_fdcwd = -2
        rename_excl = 0x00000004
        result = libc.renameatx_np(
            at_fdcwd,
            ctypes.c_char_p(source),
            at_fdcwd,
            ctypes.c_char_p(destination),
            rename_excl,
        )
    elif hasattr(libc, "renameat2"):
        at_fdcwd = -100
        rename_noreplace = 1
        result = libc.renameat2(
            at_fdcwd,
            ctypes.c_char_p(source),
            at_fdcwd,
            ctypes.c_char_p(destination),
            rename_noreplace,
        )
    else:
        require_absent(final, "final archive directory")
        os.rename(staging, final)
        return
    if result != 0:
        error_number = ctypes.get_errno()
        if error_number in (errno.EEXIST, errno.ENOTEMPTY):
            raise SystemExit(f"Refusing to overwrite existing final archive directory: {final}")
        unsupported_errors = {errno.ENOTSUP}
        if hasattr(errno, "EOPNOTSUPP"):
            unsupported_errors.add(errno.EOPNOTSUPP)
        if allow_unsupported_fallback and error_number in unsupported_errors:
            require_absent(final, "final archive directory")
            print(
                "ATOMIC_PUBLICATION_FALLBACK smbfs renameatx_np(RENAME_EXCL) "
                "unsupported; verified destination absent before os.rename",
                flush=True,
            )
            os.rename(staging, final)
            return
        raise OSError(error_number, os.strerror(error_number), str(final))


def require_absent(path: Path, label: str) -> None:
    if path.exists() or path.is_symlink():
        raise SystemExit(f"Refusing to overwrite existing {label}: {path}")


def run(command: list[str], cwd: Path) -> subprocess.CompletedProcess[str]:
    print("RUN " + shlex.join(command), flush=True)
    return subprocess.run(command, cwd=cwd, text=True, check=True)


def run_filename_compatibility_test(seven_zip: str) -> CompatibilityTestResult:
    """Prove representative filename round-trips using the selected executable."""

    local_parent, local_filesystem = local_compatibility_temp_parent()
    workspace = Path(
        tempfile.mkdtemp(prefix=".cold-archive-compatibility-", dir=local_parent)
    )
    result = CompatibilityTestResult(
        location=str(workspace),
        filesystem=local_filesystem,
    )
    print("COMPATIBILITY_TEST_LOCATION", flush=True)
    print(f"LOCAL_TEMPORARY_DIRECTORY {workspace}", flush=True)
    print(f"COMPATIBILITY_TEST_FILESYSTEM local ({local_filesystem})", flush=True)
    print(
        "COMPATIBILITY_TEST_REASON Compatibility tests are executed on local "
        "filesystem to avoid SMB/NFS metadata synchronization issues.",
        flush=True,
    )
    try:
        source = workspace / "compatibility-input"
        source.mkdir()
        names = (
            "UTF-8-é.txt",
            "中文.txt",
            "日本語.txt",
            "한국어.txt",
            "emoji-📦.txt",
            "file with spaces.txt",
            "symbols-&_#_[].txt",
            f"long-{'x' * 180}.txt",
        )
        for index, name in enumerate(names):
            (source / name).write_text(f"compatibility-{index}\n", encoding="utf-8")
        expected, expected_directories, expected_excluded = scan_hashes(source)
        if expected_excluded:
            raise SystemExit("Compatibility fixture unexpectedly matched exclusions.")
        archive = workspace / "compatibility.7z"
        run(
            [
                seven_zip,
                "a",
                *REQUIRED_SWITCHES,
                *SYSTEM_EXCLUSION_SWITCHES,
                str(archive),
                f"./{source.name}",
            ],
            workspace,
        )
        run([seven_zip, "t", str(archive)], workspace)
        recovered = workspace / "recovered"
        recovered.mkdir()
        run([seven_zip, "x", str(archive), f"-o{recovered}", "-y"], workspace)
        actual, actual_directories, actual_excluded = scan_hashes(
            recovered / source.name
        )
        require_no_excluded_entries(actual_excluded, "COMPATIBILITY_TEST")
        compare_records(expected, actual, "FILENAME_COMPATIBILITY_SHA512")
        compare_directories(
            expected_directories,
            actual_directories,
            "FILENAME_COMPATIBILITY_STRUCTURE",
        )
        print("FILENAME_COMPATIBILITY PASS", flush=True)
        return result
    finally:
        shutil.rmtree(workspace, ignore_errors=True)
        if workspace.exists() or workspace.is_symlink():
            raise SystemExit(
                f"Compatibility-test cleanup failed; temporary directory remains: {workspace}"
            )
        print("COMPATIBILITY_TEST_CLEANUP PASS", flush=True)


def write_archive_checksum(path: Path, archive_name: str, size: int, digest: str) -> None:
    path.write_text(
        "# Archive SHA-512 Manifest\n\n"
        "| Archive File | Size (bytes) | SHA-512 |\n"
        "|---|---:|---|\n"
        f"| <code>{markdown_name(archive_name)}</code> | {size} | "
        f"<code>{digest}</code> |\n",
        encoding="utf-8",
        newline="\n",
    )


def read_archive_checksum(path: Path, archive_name: str) -> FileRecord:
    row_pattern = re.compile(
        r"^\| <code>(.*?)</code> \| ([0-9]+) \| <code>([0-9a-f]{128})</code> \|$"
    )
    matches = []
    with path.open("r", encoding="utf-8", newline="") as stream:
        for raw_line in stream:
            if match := row_pattern.match(raw_line.rstrip("\n")):
                matches.append(match)
    if len(matches) != 1:
        raise SystemExit(f"Invalid archive checksum Markdown: {path}")
    recorded_name = html.unescape(matches[0].group(1))
    if recorded_name != archive_name:
        raise SystemExit(
            f"Archive checksum records {recorded_name!r}, expected {archive_name!r}."
        )
    return FileRecord(size=int(matches[0].group(2)), digest=matches[0].group(3))


def archive_contents_markdown(
    archive_name: str,
    created: str,
    source_name: str,
    records: dict[str, FileRecord],
    directories: set[str],
) -> str:
    extension_counts: dict[str, int] = {}
    for relative in records:
        suffix = Path(relative).suffix
        label = suffix[1:].upper() if suffix else "[NO EXTENSION]"
        extension_counts[label] = extension_counts.get(label, 0) + 1
    extension_lines = "\n".join(
        f"- {markdown_name(extension)}: {count} files"
        for extension, count in sorted(extension_counts.items())
    ) or "- None: 0 files"
    rows = [f"| Directory | <code>{markdown_name(source_name)}</code> | — |"] if source_name else []
    for relative in sorted(directories):
        archive_path = f"{source_name}/{relative}" if source_name else relative
        rows.append(f"| Directory | <code>{markdown_name(archive_path)}</code> | — |")
    for relative, record in sorted(records.items()):
        archive_path = f"{source_name}/{relative}" if source_name else relative
        rows.append(
            f"| File | <code>{markdown_name(archive_path)}</code> | {record.size} |"
        )
    return (
        "# Archive Contents\n\n"
        "> **注意：** 此文件仅用于展示归档内容列表，不能作为完整性验证依据。"
        "完整性验证必须使用 SHA-512 清单。\n\n"
        "> **WARNING:** This file is only an inventory of archive contents. It must "
        "not be used for integrity verification. Integrity verification must use "
        "SHA-512 manifests.\n\n"
        f"- Archive: <code>{markdown_name(archive_name)}</code>\n"
        f"- Created: {created}\n"
        f"- File Count: {len(records)}\n"
        f"- Directory Count (including the top-level directory): {len(directories) + bool(source_name)}\n"
        f"- Total File Size: {sum(record.size for record in records.values())} bytes\n\n"
        "## File Type Statistics\n\n"
        f"{extension_lines}\n\n"
        "This index was generated from the files and directories recovered from the "
        "completed archive and verified against the frozen source manifest. It is a "
        "content index, not integrity proof.\n\n"
        "| Type | Relative Path in Archive | Size (bytes) |\n"
        "|---|---|---:|\n"
        + ("\n".join(rows) + "\n" if rows else "")
    )


def write_archive_contents(
    path: Path,
    archive_name: str,
    created: str,
    source_name: str,
    records: dict[str, FileRecord],
    directories: set[str],
) -> str:
    content = archive_contents_markdown(
        archive_name, created, source_name, records, directories
    )
    path.write_text(content, encoding="utf-8", newline="\n")
    if path.read_text(encoding="utf-8") != content:
        raise SystemExit(f"Archive contents verification failed after writing: {path}")
    return content


def archive_format_markdown() -> str:
    return f"""# Archive Format

## 中文

归档格式：

{FORMAT_NAME}

版本：

{FORMAT_VERSION}

用途：

个人数字资产长期冷备保存。

适用：

- 视频素材
- 图片素材
- 航拍素材
- 项目文件
- NAS备份
- 个人资料

核心标准：

- 7z
- LZMA2
- SHA-512
- 解压恢复验证
- 源数据一致性验证

---

## English

Archive Format:

{FORMAT_NAME}

Version:

{FORMAT_VERSION}

Purpose:

Long-term cold storage format for personal digital assets.

Core Standards:

- 7z
- LZMA2
- SHA-512
- Extraction verification
- Source integrity verification
"""


def write_archive_format(path: Path) -> str:
    content = archive_format_markdown()
    path.write_text(content, encoding="utf-8", newline="\n")
    if path.read_text(encoding="utf-8") != content:
        raise SystemExit(f"Archive format verification failed after writing: {path}")
    return content


def compression_info_markdown(
    *, selected_seven_zip_path: str, seven_zip_version: str
) -> str:
    required_lines = "\n".join(REQUIRED_SWITCHES[1:])
    full_parameters = " ".join((*REQUIRED_SWITCHES, *SYSTEM_EXCLUSION_SWITCHES))
    executable = markdown_name(selected_seven_zip_path)
    version = markdown_name(seven_zip_version)
    return f"""# Compression Information

## 中文

7-Zip 版本：

{version}

实际执行程序：

<code>{executable}</code>

Format:

7z

Method:

LZMA2

Level:

Ultra

Dictionary:

64 MiB

Fast Bytes:

64

Solid:

Enabled

Command:

```text
{required_lines}
```

完整命令参数：

<code>{markdown_name(full_parameters)}</code>

---

## English

7-Zip Version:

{version}

Executable:

<code>{executable}</code>

Format:

7z

Method:

LZMA2

Level:

Ultra

Dictionary:

64 MiB

Fast Bytes:

64

Solid:

Enabled

Command:

```text
{required_lines}
```

Complete Parameters:

<code>{markdown_name(full_parameters)}</code>
"""


def write_compression_info(
    path: Path, *, selected_seven_zip_path: str, seven_zip_version: str
) -> str:
    content = compression_info_markdown(
        selected_seven_zip_path=selected_seven_zip_path,
        seven_zip_version=seven_zip_version,
    )
    path.write_text(content, encoding="utf-8", newline="\n")
    if path.read_text(encoding="utf-8") != content:
        raise SystemExit(f"Compression information verification failed: {path}")
    return content


def statistics_markdown(
    *,
    created: str,
    file_count: int,
    directory_count: int,
    source_size: int,
    archive_size: int,
    excluded_count: int,
    compression_seconds: float,
) -> str:
    if source_size:
        ratio = f"{archive_size / source_size * 100:.2f}%"
    else:
        ratio = "N/A"
    return f"""# Archive Statistics

## 中文

- 创建时间：{created}
- 文件数量：{file_count}
- 目录数量（不含顶层目录）：{directory_count}
- 原始大小：{source_size} bytes
- 归档大小：{archive_size} bytes
- 压缩比例（归档大小 / 原始大小）：{ratio}
- 排除文件数量：{excluded_count}
- 压缩耗时：{compression_seconds:.6f} seconds

以上数值来自已验证的归档事务。文件完整性仍必须使用 SHA-512 清单验证。

---

## English

- Creation Time: {created}
- Source File Count: {file_count}
- Source Directory Count (excluding the top-level directory): {directory_count}
- Source Data Size: {source_size} bytes
- Archive Size: {archive_size} bytes
- Archive-to-Source Ratio: {ratio}
- Excluded Entry Count: {excluded_count}
- Compression Duration: {compression_seconds:.6f} seconds

These values describe the verified archive transaction. File integrity must still be checked with the SHA-512 manifests.
"""


def write_statistics(
    path: Path,
    *,
    created: str,
    file_count: int,
    directory_count: int,
    source_size: int,
    archive_size: int,
    excluded_count: int,
    compression_seconds: float,
) -> str:
    content = statistics_markdown(
        created=created,
        file_count=file_count,
        directory_count=directory_count,
        source_size=source_size,
        archive_size=archive_size,
        excluded_count=excluded_count,
        compression_seconds=compression_seconds,
    )
    path.write_text(content, encoding="utf-8", newline="\n")
    if path.read_text(encoding="utf-8") != content:
        raise SystemExit(f"Statistics verification failed after writing: {path}")
    return content


def read_archive_contents_counts(path: Path) -> tuple[int, int]:
    file_count: int | None = None
    directory_count: int | None = None
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("- File Count: "):
            file_count = int(line.removeprefix("- File Count: "))
        elif line.startswith("- Directory Count: "):
            directory_count = int(line.removeprefix("- Directory Count: "))
        elif line.startswith("- Directory Count (including the top-level directory): "):
            directory_count = int(
                line.removeprefix(
                    "- Directory Count (including the top-level directory): "
                )
            )
    if file_count is None or directory_count is None:
        raise SystemExit(f"Invalid archive contents document: {path}")
    return file_count, directory_count


def write_readme(
    path: Path,
    *,
    archive_name_raw: str,
    archive_name_display: str,
    archive_filename: str,
    archive_checksum_filename: str,
    source_name: str,
    archive_folder_name: str,
    archive_digest_prefix: str,
) -> None:
    raw_name = markdown_name(archive_name_raw)
    display_name = markdown_name(archive_name_display)
    archive = markdown_name(archive_filename)
    archive_checksum = markdown_name(archive_checksum_filename)
    source = markdown_name(source_name)
    folder = markdown_name(archive_folder_name)
    prefix = markdown_name(archive_digest_prefix)
    content = f"""# Personal Cold Archive README

# 中文

## 1. 归档标识

归档文件夹：

<code>{folder}</code>

归档 SHA-512 前缀：

<code>{prefix}</code>

原始归档名称（ArchiveName_RAW）： <code>{raw_name}</code>

显示归档名称（ArchiveName_DISPLAY）： <code>{display_name}</code>

主要归档文件：<code>{archive}</code>

源路径：<code>{source}</code>

## 2. 归档格式

{FORMAT_NAME}

版本：

{FORMAT_VERSION}

详细标准见 <code>{INFO_DIRECTORY_NAME}/{ARCHIVE_FORMAT_NAME}</code>。

## 3. 压缩信息

- 格式：7z
- 压缩算法：LZMA2
- 压缩级别：极限（Ultra）
- 字典大小：64 MiB
- 快速字节数（Fast Bytes）：64
- 固实压缩：启用

详细参数见 <code>{INFO_DIRECTORY_NAME}/{COMPRESSION_INFO_NAME}</code>。

## 4. 恢复步骤

1. 使用 <code>{archive_checksum}</code> 验证 <code>{archive}</code> 的大小和 SHA-512。
2. 对 <code>{archive}</code> 执行 7-Zip <code>t</code> 完整性测试。
3. 使用 7-Zip <code>x</code> 完整路径模式解压到新的空目录。
4. 重新计算全部恢复文件的 SHA-512。
5. 将恢复文件的路径、大小和 SHA-512 与 <code>{INFO_DIRECTORY_NAME}/{SOURCE_MANIFEST_NAME}</code> 逐项比较，并确认目录结构一致。

## 5. 排除文件

以下条目不会进入归档：

macOS:

- <code>.DS_Store</code>
- <code>.AppleDouble</code>
- <code>._*</code>
- <code>.Spotlight-V100</code>
- <code>.Trashes</code>
- <code>.fseventsd</code>
- <code>.DocumentRevisions-V100</code>
- <code>.TemporaryItems</code>

Windows:

- <code>Thumbs.db</code>
- <code>ehthumbs.db</code>
- <code>Desktop.ini</code>
- <code>$RECYCLE.BIN</code>
- <code>System Volume Information</code>

Linux / Android:

- <code>.Trash-*</code>
- <code>.nfs*</code>
- <code>lost+found</code>
- <code>.nomedia</code>

临时文件：

- <code>*.tmp</code>
- <code>*.temp</code>
- <code>*.bak</code>
- <code>*~</code>

完整排除规则也记录于 <code>{INFO_DIRECTORY_NAME}/{INFO_NAME}</code>。

## 6. 归档规则

本归档按照长期冷备流程创建并视为不可修改对象。任何修改必须创建新归档，禁止覆盖已有冷备归档。<code>{INFO_DIRECTORY_NAME}/{ARCHIVE_CONTENTS_NAME}</code> 仅用于浏览，不是完整性证明。

---

# English

## 1. Archive Identity

Archive Folder:

<code>{folder}</code>

Archive SHA512 Prefix:

<code>{prefix}</code>

ArchiveName_RAW: <code>{raw_name}</code>

ArchiveName_DISPLAY: <code>{display_name}</code>

Primary Archive File: <code>{archive}</code>

Source Path(s): <code>{source}</code>

## 2. Archive Format

{FORMAT_NAME}

Version:

{FORMAT_VERSION}

See <code>{INFO_DIRECTORY_NAME}/{ARCHIVE_FORMAT_NAME}</code> for the complete standard.

## 3. Compression Information

- Format: 7z
- Method: LZMA2
- Level: Ultra
- Dictionary: 64 MiB
- Fast Bytes: 64
- Solid: Enabled

See <code>{INFO_DIRECTORY_NAME}/{COMPRESSION_INFO_NAME}</code> for complete parameters.

## 4. Recovery Procedure

1. Verify the size and SHA-512 of <code>{archive}</code> against <code>{archive_checksum}</code>.
2. Run the 7-Zip <code>t</code> integrity test on <code>{archive}</code>.
3. Extract with full paths using 7-Zip <code>x</code> into a new empty directory.
4. Recompute SHA-512 for every restored file.
5. Compare every restored path, size, and SHA-512 with <code>{INFO_DIRECTORY_NAME}/{SOURCE_MANIFEST_NAME}</code>, and require the directory structure to match.

## 5. Excluded Files

The following entries do not enter the archive:

macOS:

- <code>.DS_Store</code>
- <code>.AppleDouble</code>
- <code>._*</code>
- <code>.Spotlight-V100</code>
- <code>.Trashes</code>
- <code>.fseventsd</code>
- <code>.DocumentRevisions-V100</code>
- <code>.TemporaryItems</code>

Windows:

- <code>Thumbs.db</code>
- <code>ehthumbs.db</code>
- <code>Desktop.ini</code>
- <code>$RECYCLE.BIN</code>
- <code>System Volume Information</code>

Linux / Android:

- <code>.Trash-*</code>
- <code>.nfs*</code>
- <code>lost+found</code>
- <code>.nomedia</code>

Temporary:

- <code>*.tmp</code>
- <code>*.temp</code>
- <code>*.bak</code>
- <code>*~</code>

The complete rule set is also recorded in <code>{INFO_DIRECTORY_NAME}/{INFO_NAME}</code>.

## 6. Archive Policy

This archive was created using a long-term cold archive workflow and must be treated as immutable. Any modification requires a new archive. Existing cold archives must never be overwritten. <code>{INFO_DIRECTORY_NAME}/{ARCHIVE_CONTENTS_NAME}</code> is only an inventory, not integrity proof.
"""
    path.write_text(content, encoding="utf-8", newline="\n")
    if path.read_text(encoding="utf-8") != content:
        raise SystemExit(f"README verification failed after writing: {path}")


def validate_readme(
    path: Path,
    *,
    archive_name_raw: str,
    archive_name_display: str,
    archive_folder_name: str,
    archive_digest_prefix: str,
) -> None:
    content = path.read_text(encoding="utf-8")
    chinese = content.find("# 中文")
    english = content.find("# English")
    required = (
        "# Personal Cold Archive README",
        "## 1. Archive Identity",
        "Archive Folder:",
        "Archive SHA512 Prefix:",
        f"ArchiveName_RAW: <code>{markdown_name(archive_name_raw)}</code>",
        f"ArchiveName_DISPLAY: <code>{markdown_name(archive_name_display)}</code>",
        f"<code>{markdown_name(archive_folder_name)}</code>",
        f"<code>{markdown_name(archive_digest_prefix)}</code>",
        "## 2. Archive Format",
        FORMAT_NAME,
        f"Version:\n\n{FORMAT_VERSION}",
        "## 3. Compression Information",
        "- Format: 7z",
        "- Method: LZMA2",
        "- Level: Ultra",
        "- Dictionary: 64 MiB",
        "- Fast Bytes: 64",
        "- Solid: Enabled",
        "## 4. Recovery Procedure",
        f"{INFO_DIRECTORY_NAME}/{SOURCE_MANIFEST_NAME}",
        "## 5. Excluded Files",
        "<code>.DS_Store</code>",
        "<code>*.tmp</code>",
        "## 6. Archive Policy",
        "Existing cold archives must never be overwritten.",
        f"{INFO_DIRECTORY_NAME}/{ARCHIVE_FORMAT_NAME}",
        f"{INFO_DIRECTORY_NAME}/{COMPRESSION_INFO_NAME}",
    )
    # Check each language independently; English must not mask missing Chinese text.
    zh = content[chinese:english] if 0 <= chinese < english else ""
    en = content[english:] if english >= 0 else ""
    translations = {'## 1. Archive Identity': '## 1. 归档标识', 'Archive Folder:': '归档文件夹：', 'Archive SHA512 Prefix:': '归档 SHA-512 前缀：', 'ArchiveName_RAW:': '原始归档名称（ArchiveName_RAW）：', 'ArchiveName_DISPLAY:': '显示归档名称（ArchiveName_DISPLAY）：', '## 2. Archive Format': '## 2. 归档格式', 'Version:': '版本：', '## 3. Compression Information': '## 3. 压缩信息', '- Format: 7z': '- 格式：7z', '- Method: LZMA2': '- 压缩算法：LZMA2', '- Level: Ultra': '- 压缩级别：极限（Ultra）', '- Dictionary: 64 MiB': '- 字典大小：64 MiB', '- Fast Bytes: 64': '- 快速字节数（Fast Bytes）：64', '- Solid: Enabled': '- 固实压缩：启用', '## 4. Recovery Procedure': '## 4. 恢复步骤', '## 5. Excluded Files': '## 5. 排除文件', 'Temporary:': '临时文件：', '## 6. Archive Policy': '## 6. 归档规则'}
    english_required = required[1:] + (
        f"The complete rule set is also recorded in <code>{INFO_DIRECTORY_NAME}/{INFO_NAME}</code>.",
    )
    chinese_required = []
    for fragment in required[1:]:
        if fragment == "Existing cold archives must never be overwritten.":
            fragment = "任何修改必须创建新归档，禁止覆盖已有冷备归档。"
        else:
            for old, new in translations.items():
                fragment = fragment.replace(old, new)
        chinese_required.append(fragment)
    chinese_required.extend((
        "临时文件：",
        f"完整排除规则也记录于 <code>{INFO_DIRECTORY_NAME}/{INFO_NAME}</code>。",
        "完整性测试。", "完整路径模式解压到新的空目录。",
        "重新计算全部恢复文件的 SHA-512。", "逐项比较，并确认目录结构一致。",
        "仅用于浏览，不是完整性证明。",
    ))
    missing = ["English: " + item for item in english_required if item not in en]
    missing += ["中文: " + item for item in chinese_required if item not in zh]
    if required[0] not in content:
        missing.append(required[0])
    if chinese < 0 or english < 0 or chinese >= english or missing:
        raise SystemExit(
            f"Bilingual README verification failed for {path}; missing: {missing!r}."
        )


def validate_archive_info(
    path: Path,
    *,
    archive_name_raw: str,
    archive_name_display: str,
    compatibility_test_location: str,
    compatibility_test_filesystem: str,
    recovery_stability_attempts: int,
    recovery_stability_mode: str,
    archive_id: str,
    archive_folder_name: str,
    output_directory: Path,
    output_directory_mode: str,
) -> None:
    content = path.read_text(encoding="utf-8")
    required = (
        "## Compression",
        "Format:\n7z",
        "Method:\nLZMA2",
        "Level:\nUltra",
        "Dictionary:\n64 MiB",
        "Fast Bytes:\n64",
        "Solid:\nEnabled",
        "## Exclusion Rules",
        "<code>.DS_Store</code>",
        "<code>.AppleDouble</code>",
        "<code>._*</code>",
        "<code>System Volume Information</code>",
        "<code>.Trash-*</code>",
        "<code>.nfs*</code>",
        "<code>lost+found</code>",
        "<code>.nomedia</code>",
        "<code>*.tmp</code>",
        "## Toolchain",
        "Hash Tool:\nPython hashlib.sha512",
        "Archive Script:\ncreate_archive_bundle.py",
        f"Skill Version:\n{SKILL_VERSION}",
        f"Archive Format:\n{FORMAT_NAME}",
        f"Format Version:\n{FORMAT_VERSION}",
        "## Compatibility Test",
        "Compatibility Test Location:",
        f"<code>{markdown_name(compatibility_test_location)}</code>",
        f"Filesystem:\n\nlocal ({markdown_name(compatibility_test_filesystem)})",
        "Compatibility tests are executed on local filesystem to avoid SMB/NFS metadata synchronization issues.",
        "## SMB Recovery Stability",
        f"Mode: {markdown_name(recovery_stability_mode)}",
        f"Hash Scan Attempts: {recovery_stability_attempts}",
        "Result: PASS",
        "Filename Compatibility:\n\nPASS:",
        "Extraction Test:\n\nPASS",
        "SHA512 Verification:\n\nPASS",
        "Archive ID:",
        "Archive Folder Name:",
        f"ArchiveName_RAW: {markdown_name(archive_name_raw)}",
        f"ArchiveName_DISPLAY: {markdown_name(archive_name_display)}",
        f"Archive ID: {markdown_name(archive_id)}",
        f"Archive Folder Name: {markdown_name(archive_folder_name)}",
        f"Output Directory: {output_directory}",
        f"Output Directory Mode: {output_directory_mode}",
        "Source SHA512: PASS",
        "Archive Test: PASS",
        "Extraction Verification: PASS",
        "Source Data Verification: PASS",
        "Archive SHA512: PASS",
    )
    missing = [fragment for fragment in required if fragment not in content]
    if missing:
        raise SystemExit(
            f"Archive information verification failed for {path}; missing: {missing!r}."
        )


def write_archive_info(
    path: Path,
    *,
    created: str,
    operating_system: str,
    cpu_architecture: str,
    python_version: str,
    source_filesystem: str,
    target_filesystem: str,
    detected_seven_zip: list[tuple[str, str, str]],
    selected_seven_zip_path: str,
    seven_zip_version: str,
    source: Path,
    file_count: int,
    source_size: int,
    excluded_count: int,
    archive_filename: str,
    archive_name_raw: str,
    archive_name_display: str,
    compatibility_test_location: str,
    compatibility_test_filesystem: str,
    recovery_stability_attempts: int,
    recovery_stability_mode: str,
    archive_size: int,
    archive_id: str,
    archive_folder_name: str,
    output_directory: Path,
    output_directory_mode: str,
) -> None:
    display_archive_filename = markdown_name(archive_filename)
    display_source_name = markdown_name(source.name)
    detected_lines = (
        "\n".join(
            f"- {markdown_name(command_name)}: "
            f"<code>{markdown_name(command_path)}</code> — "
            f"{markdown_name(command_version)}"
            for command_name, command_path, command_version in detected_seven_zip
        )
        or "- None"
    )
    content = f"""# Archive Information

## Archive Identity

Archive Name: {display_archive_filename}
ArchiveName_RAW: {markdown_name(archive_name_raw)}
ArchiveName_DISPLAY: {markdown_name(archive_name_display)}
Archive ID: {markdown_name(archive_id)}
Archive Folder Name: {markdown_name(archive_folder_name)}
Created: {created}
CPU Architecture: {cpu_architecture}
Source Filesystem: {source_filesystem}
Target Filesystem: {target_filesystem}
Output Directory: {output_directory}
Output Directory Mode: {output_directory_mode}

Detected 7-Zip Commands (detection order):

{detected_lines}

## Toolchain

Operating System:
{operating_system}

Python Version:
{python_version}

7-Zip Version:
{seven_zip_version}

7-Zip Executable:
<code>{markdown_name(selected_seven_zip_path)}</code>

Hash Tool:
Python hashlib.sha512

Archive Script:
create_archive_bundle.py

Skill Version:
{SKILL_VERSION}

## Archive Standard

Archive Format:
{FORMAT_NAME}

Format Version:
{FORMAT_VERSION}

Purpose:
Long-term cold storage archive

## Purpose

Long-term cold storage archive

## Archive Status

Status: Immutable Cold Archive

Warning:

Do not modify files inside this directory.

Any modification invalidates verification records.

## Source

Source Path: {source}
File Count: {file_count}
Total Size: {source_size} bytes

## Archive

Archive Size: {archive_size} bytes

## Compression

Compression:

Format:
7z

Method:
LZMA2

Level:
Ultra

Dictionary:
64 MiB

Fast Bytes:
64

Solid:
Enabled

Command Parameters:
<code>{" ".join(REQUIRED_SWITCHES)}</code>

## Exclusion Rules

Only the following automatically generated operating-system entries were excluded. No broader patterns were used.

macOS:

- <code>.DS_Store</code>
- <code>.AppleDouble</code>
- <code>._*</code>
- <code>.Spotlight-V100</code>
- <code>.Trashes</code>
- <code>.fseventsd</code>
- <code>.DocumentRevisions-V100</code>
- <code>.TemporaryItems</code>

Windows:

- <code>Thumbs.db</code>
- <code>ehthumbs.db</code>
- <code>Desktop.ini</code>
- <code>$RECYCLE.BIN</code>
- <code>System Volume Information</code>

Linux:

- <code>.Trash-*</code>
- <code>.nfs*</code>
- <code>lost+found</code>

Android:

- <code>.nomedia</code>

General temporary files:

- <code>*.tmp</code>
- <code>*.temp</code>
- <code>*.bak</code>
- <code>*~</code>

Excluded Source Entries: {excluded_count}

These rules affect archive scanning only. No source file or directory is deleted or modified.

## Compatibility Test

Compatibility Test Location:

Local Temporary Directory:

<code>{markdown_name(compatibility_test_location)}</code>

Filesystem:

local ({markdown_name(compatibility_test_filesystem)})

Compatibility tests are executed on local filesystem to avoid SMB/NFS metadata synchronization issues.

Filename Compatibility:

PASS:

- UTF-8 filenames
- Chinese characters
- Japanese characters
- Korean characters
- Emoji
- Spaces
- Special symbols
- Long filenames

Extraction Test:

PASS

SHA512 Verification:

PASS

## SMB Recovery Stability

Mode: {markdown_name(recovery_stability_mode)}

Hash Scan Attempts: {recovery_stability_attempts}

Result: PASS

## Verification

Source SHA512: PASS
Archive Test: PASS
Extraction Verification: PASS
Source Data Verification: PASS
Archive SHA512: PASS
Archive Contents: PASS
Final Bundle Structure: PASS

## Notes

Already compressed media may have limited size reduction.

## Recovery

1. Independently compute the SHA-512 digest of <code>../{display_archive_filename}</code> and require an exact match with <code>../{display_archive_filename}.sha512.md</code>.
2. Run the selected 7-Zip executable in test mode (`t`) against <code>{display_archive_filename}</code> and require success.
3. Extract with full paths (`x`) into a new empty recovery directory. Require every recovered path to match Documents/ARCHIVE_CONTENTS.md and verify file hashes against Documents/SHA512.md.
4. Recompute the byte size and SHA-512 digest of every restored regular file and require a complete match with <code>{SOURCE_MANIFEST_NAME}</code>.
5. Treat <code>{ARCHIVE_CONTENTS_NAME}</code> only as a content index, not as integrity proof.
"""
    path.write_text(content, encoding="utf-8", newline="\n")


def write_verification_log(
    path: Path,
    *,
    created: str,
    archive_name_raw: str,
    archive_name_display: str,
    compatibility_test_location: str,
    compatibility_test_filesystem: str,
    recovery_stability_attempts: int,
    recovery_stability_mode: str,
    archive_filename: str,
    archive_digest: str,
    output_directory: Path,
    output_directory_mode: str,
) -> str:
    content = f"""# Verification Log

- Completed: {created}
- ArchiveName_RAW: <code>{markdown_name(archive_name_raw)}</code>
- ArchiveName_DISPLAY: <code>{markdown_name(archive_name_display)}</code>
- Output Directory: <code>{markdown_name(str(output_directory))}</code>
- Output Directory Mode: {markdown_name(output_directory_mode)}
- Compatibility Test Location: <code>{markdown_name(compatibility_test_location)}</code>
- Compatibility Test Filesystem: local ({markdown_name(compatibility_test_filesystem)})
- Compatibility Test Reason: Compatibility tests are executed on local filesystem to avoid SMB/NFS metadata synchronization issues.
- SMB Recovery Stability Mode: {markdown_name(recovery_stability_mode)}
- SMB Recovery Hash Scan Attempts: {recovery_stability_attempts}
- SMB Recovery Stability: PASS
- Archive: <code>{markdown_name(archive_filename)}</code>
- Archive SHA-512: <code>{archive_digest}</code>

## Results

- Source SHA512: PASS
- Archive SHA512: PASS
- 7z Test: PASS
- Compression Parameters: PASS
- Extraction Verification: PASS
- Restored SHA512 Comparison: PASS
- Directory Structure Comparison: PASS
- Source SHA-512 manifest generation and parse verification: PASS
- 7z format and LZMA2 property inspection: PASS
- 7-Zip integrity test: PASS
- Full-path extraction test: PASS
- Restored path, size, directory, and SHA-512 comparison: PASS
- Live-source freeze verification: PASS
- Final archive SHA-512 verification: PASS
- Filename compatibility: PASS
- Source information document generation: PASS
- Statistics document generation: PASS
- Final bundle structure verification: PASS
"""
    path.write_text(content, encoding="utf-8", newline="\n")
    if path.read_text(encoding="utf-8") != content:
        raise SystemExit(f"Verification log failed after writing: {path}")
    return content


def validate_bundle_structure(
    directory: Path, archive_name: str, archive_checksum_name: str
) -> None:
    expected = {
        README_NAME,
        archive_name,
        archive_checksum_name,
        INFO_DIRECTORY_NAME,
    }
    entries = list(directory.iterdir())
    actual = {entry.name for entry in entries}
    root_type_errors = sorted(
        entry.name
        for entry in entries
        if (
            entry.name == INFO_DIRECTORY_NAME
            and (not entry.is_dir() or entry.is_symlink())
        )
        or (
            entry.name != INFO_DIRECTORY_NAME
            and (not entry.is_file() or entry.is_symlink())
        )
    )
    if actual != expected or root_type_errors:
        raise SystemExit(
            "Bundle root structure verification failed; expected README, archive, "
            "archive checksum, and Documents only; "
            f"found {sorted(actual)!r}; type errors: {root_type_errors!r}."
        )
    info_directory = directory / INFO_DIRECTORY_NAME
    expected_info = {
        INFO_NAME,
        ARCHIVE_CONTENTS_NAME,
        SOURCE_MANIFEST_NAME,
        VERIFICATION_LOG_NAME,
        SOURCE_INFO_NAME,
        STATISTICS_NAME,
        ARCHIVE_FORMAT_NAME,
        COMPRESSION_INFO_NAME,
    }
    info_entries = list(info_directory.iterdir())
    actual_info = {entry.name for entry in info_entries}
    info_type_errors = sorted(
        entry.name for entry in info_entries if not entry.is_file() or entry.is_symlink()
    )
    if actual_info != expected_info or info_type_errors:
        raise SystemExit(
            "Documents structure verification failed; expected eight regular files "
            f"{sorted(expected_info)!r}, found {sorted(actual_info)!r}; "
            f"type errors: {info_type_errors!r}."
        )


def main() -> int:
    import sys
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from bilingual_documents import update_documents, validate_documents, record_completion
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_dir", type=Path, nargs="+", help="One directory, one file, or multiple explicitly selected files")
    parser.add_argument(
        "--archive-name",
        required=True,
        help="Human-readable archive base name used for the .7z file and final directory",
    )
    parser.add_argument("--seven-zip", help="7-Zip executable name or path")
    parser.add_argument(
        "--output-dir",
        type=Path,
        help=(
            "Existing directory that receives the final archive bundle and all "
            "target-filesystem workspaces; defaults to the source parent"
        ),
    )
    parser.add_argument("--source-type", help="Source category or project context")
    parser.add_argument("--device-name", help="Source device name")
    parser.add_argument("--device-model", help="Source device model")
    parser.add_argument("--source-software", help="Source capture or project software")
    parser.add_argument("--storage-source", help="Original storage medium or system")
    parser.add_argument("--source-notes", help="Optional source context notes")
    parser.add_argument("--source-purpose", help="User-stated purpose, separate from notes")
    parser.add_argument("--source-details-json", type=Path, help="Structured bilingual provenance states and metadata evidence")
    parser.add_argument("--require-source-confirmation", action="store_true", help="Compatibility flag: confirmation is always required, even without this flag")
    parser.add_argument("--source-answers-json", type=Path, help="Source-bound raw answers keyed by stable question IDs")
    args = parser.parse_args()

    provenance = {"source_type": args.source_type, "device_name": args.device_name,
                  "device_model": args.device_model, "source_software": args.source_software,
                  "storage_source": args.storage_source, "purpose": args.source_purpose,
                  "notes": args.source_notes}
    if args.source_details_json:
        import json
        details = json.loads(args.source_details_json.read_text(encoding="utf-8"))
        if not isinstance(details, dict) or set(details) - (set(provenance) | {"metadata_evidence"}):
            raise SystemExit("Invalid source-details JSON fields")
        provenance.update(details)
    if not args.source_answers_json:
        raise SystemExit("SOURCE_CONFIRMATION_PENDING: --source-answers-json is required for every archive")
    if args.source_answers_json:
        import json
        from provenance_answers import compile_answers
        if any(value is not None for value in (args.source_type, args.device_name, args.device_model, args.source_software, args.source_purpose, args.source_notes)):
            raise SystemExit("Conflicting provenance flags: use answer record only for user-confirmed fields")
        if args.source_details_json and set(details) - {"storage_source", "metadata_evidence"}:
            raise SystemExit("Source details cannot override submitted user answers")
        provenance.update(compile_answers(json.loads(args.source_answers_json.read_text(encoding="utf-8")), args.source_dir))

    from bilingual_documents import provenance_value
    for value in provenance.values():
        for language in ("zh", "en"):
            provenance_value(value, language)

    print("PHASE 1 ENVIRONMENT CHECK", flush=True)
    available_7zip = detect_7zip()
    seven_zip, version = select_7zip(args.seven_zip, available_7zip)
    operating_system = platform.platform()
    cpu_architecture = platform.machine()
    python_version = platform.python_version()
    print(f"USING {version} ({seven_zip})", flush=True)
    print(f"OPERATING_SYSTEM {operating_system}", flush=True)
    print(f"CPU_ARCHITECTURE {cpu_architecture}", flush=True)
    print(f"PYTHON_VERSION {python_version}", flush=True)

    print("PHASE 2 PATH CONFIRMATION", flush=True)
    inputs = [path.expanduser() for path in args.source_dir]
    for path in inputs:
        if path.is_symlink():
            raise SystemExit(f"Source must not be a symbolic link: {path}")
    inputs = [path.resolve(strict=True) for path in inputs]
    if len(set(inputs)) != len(inputs):
        raise SystemExit("Duplicate input paths are not allowed.")
    selected_files = None
    if len(inputs) == 1 and inputs[0].is_dir():
        source = inputs[0]
        if source == Path(source.anchor):
            raise SystemExit("Refusing to archive a filesystem root.")
    else:
        if not all(stat.S_ISREG(path.lstat().st_mode) for path in inputs):
            raise SystemExit("Multiple inputs must all be regular files; directory/file mixtures are not supported.")
        selected_files = inputs
        source = Path(os.path.commonpath([str(path.parent) for path in inputs]))
        # For explicit files the common root is only a relative-path base.
        # scan_hashes and 7z receive the exact selection; never recurse over it.
        for path in inputs:
            if any(exclusion_rule(part) for part in path.relative_to(source).parts):
                raise SystemExit(f"Explicitly selected file matches a fixed exclusion: {path}")
        mapping = "\n".join(f"{path} -> {path.relative_to(source).as_posix()}" for path in inputs)
        # Original path mappings are rendered separately, never appended to user notes.
    def scan_source():
        return scan_hashes(source, selected_files)
    content_root = source.name if selected_files is None else ""
    archive_name_raw = args.archive_name
    if Path(archive_name_raw).name != archive_name_raw or archive_name_raw in ("", ".", ".."):
        raise SystemExit("Archive name must be one non-empty filename component.")
    if "\n" in archive_name_raw or "\r" in archive_name_raw:
        raise SystemExit("Archive name must not contain a line break.")
    archive_name_display_value = archive_name_display(archive_name_raw)

    source_parent = source.parent if selected_files is None else source
    if args.output_dir is None:
        output_parent = source_parent
        output_directory_mode = "default source parent"
    else:
        output_input = args.output_dir.expanduser()
        if output_input.is_symlink():
            raise SystemExit(
                f"Output directory must not be a symbolic link: {output_input}"
            )
        output_parent = output_input.resolve()
        if not output_parent.is_dir():
            raise SystemExit(f"Output directory not found: {output_parent}")
        output_directory_mode = "explicit --output-dir"
    if selected_files is None and (output_parent == source or source in output_parent.parents):
        raise SystemExit(
            "Output directory must not be the source directory or one of its "
            "descendants."
        )
    source_filesystem = filesystem_type(source)
    target_filesystem = filesystem_type(output_parent)
    created_at = datetime.now().astimezone()
    archive_filename = f"{archive_name_raw}.7z"
    archive_checksum_filename = f"{archive_filename}.sha512.md"
    print(f"SOURCE_PATH {source}", flush=True)
    print(f"OUTPUT_DIRECTORY {output_parent}", flush=True)
    print(f"OUTPUT_DIRECTORY_MODE {output_directory_mode}", flush=True)
    print("FINAL_DIRECTORY pending verified archive SHA-512", flush=True)
    print(f"SOURCE_FILESYSTEM {source_filesystem}", flush=True)
    print(f"TARGET_FILESYSTEM {target_filesystem}", flush=True)

    print("PHASE 3 FILE TYPE CHECK", flush=True)
    (
        inventory_count,
        inventory_bytes,
        inventory_directories,
        inventory_excluded,
    ) = inventory_size(source) if selected_files is None else (
        len(selected_files), sum(path.stat().st_size for path in selected_files),
        {parent.as_posix() for path in selected_files for parent in path.relative_to(source).parents if parent != Path('.')}, {},
    )
    print("SOURCE_FILE_TYPES SUPPORTED", flush=True)
    print(f"SYSTEM_ENTRIES_EXCLUDED {len(inventory_excluded)}", flush=True)

    print("PHASE 4 DISK SPACE CHECK", flush=True)
    free_bytes = shutil.disk_usage(output_parent).free
    archive_workspace_bytes = (inventory_bytes * 11 + 9) // 10
    extraction_workspace_bytes = (inventory_bytes * 11 + 9) // 10
    required_bytes = (
        archive_workspace_bytes + extraction_workspace_bytes + SPACE_SAFETY_BYTES
    )
    print(f"SOURCE_DATA_BYTES {inventory_bytes}")
    print(f"ARCHIVE_WORKSPACE_BYTES {archive_workspace_bytes}")
    print(f"EXTRACTION_WORKSPACE_BYTES {extraction_workspace_bytes}")
    print(f"SAFETY_BUFFER_BYTES {SPACE_SAFETY_BYTES}")
    print(f"TARGET_FREE_BYTES {free_bytes}")
    print(f"REQUIRED_WORK_BYTES {required_bytes}")
    if free_bytes < required_bytes:
        raise SystemExit(
            "Insufficient target-disk space for temporary archive creation and full "
            f"extraction verification: need {required_bytes} bytes, have {free_bytes}."
        )

    print("PHASE 5 FILENAME COMPATIBILITY TEST", flush=True)
    compatibility_test_result = run_filename_compatibility_test(seven_zip)

    staging = Path(
        tempfile.mkdtemp(prefix=".cold-archive-staging-", dir=output_parent)
    )
    extraction: Path | None = None
    bundle: Path | None = None
    published = False
    complete = False
    try:
        info_directory = staging / INFO_DIRECTORY_NAME
        info_directory.mkdir()

        print(f"PHASE 6 GENERATE {SOURCE_MANIFEST_NAME}", flush=True)
        initial_records, initial_directories, initial_excluded = scan_source()
        if len(initial_records) != inventory_count:
            raise SystemExit("Source file count changed between space check and hashing.")
        if sum(record.size for record in initial_records.values()) != inventory_bytes:
            raise SystemExit("Source size changed between space check and hashing.")
        compare_directories(
            inventory_directories, initial_directories, "SOURCE_INVENTORY"
        )
        if initial_excluded != inventory_excluded:
            raise SystemExit("Excluded operating-system entries changed during source scan.")
        staged_manifest = info_directory / SOURCE_MANIFEST_NAME
        write_manifest(staged_manifest, initial_records)
        manifest_records = read_manifest(staged_manifest)
        compare_records(initial_records, manifest_records, "SOURCE_MANIFEST_WRITE")

        print("PHASE 7 CREATE 7Z", flush=True)
        staged_archive = staging / archive_filename
        source_operands = [f"./{source.name}"] if selected_files is None else ["-i!" + path.relative_to(source).as_posix() for path in selected_files]
        create_command = [
            seven_zip,
            "a",
            *REQUIRED_SWITCHES,
            *SYSTEM_EXCLUSION_SWITCHES,
            str(staged_archive),
            *(["-spd"] if selected_files is not None else []),
            *source_operands,
        ]
        missing_switches = [switch for switch in REQUIRED_SWITCHES if switch not in create_command]
        if missing_switches:
            raise SystemExit(
                "Archive creation command is missing required switches: "
                + ", ".join(missing_switches)
            )
        print("COMMAND_SWITCHES VERIFIED " + " ".join(REQUIRED_SWITCHES), flush=True)
        compression_started = time.monotonic()
        run(create_command, source_parent)
        compression_seconds = time.monotonic() - compression_started
        print(f"COMPRESSION_SECONDS {compression_seconds:.6f}", flush=True)

        print("PHASE 8 VERIFY COMPRESSION", flush=True)
        technical_listing = subprocess.run(
            [seven_zip, "l", "-slt", str(staged_archive)],
            cwd=source_parent,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=True,
        ).stdout
        missing_properties = []
        if "Type = 7z" not in technical_listing:
            missing_properties.append("Type = 7z")
        nonempty_file_count = sum(record.size > 0 for record in manifest_records.values())
        method_is_lzma2 = bool(
            re.search(r"^Method = .*LZMA2", technical_listing, re.MULTILINE)
        )
        if nonempty_file_count > 0 and not method_is_lzma2:
            missing_properties.append("Method contains LZMA2")
        solid_is_enabled = "Solid = +" in technical_listing
        if nonempty_file_count >= 2 and not solid_is_enabled:
            missing_properties.append("Solid = +")
        if missing_properties:
            raise SystemExit(
                "Archive property verification failed; missing: "
                + ", ".join(missing_properties)
            )
        method_evidence = "LZMA2" if method_is_lzma2 else "no data stream"
        solid_evidence = "+" if solid_is_enabled else "not applicable (<2 data streams)"
        print(
            "ARCHIVE_PROPERTIES VERIFIED "
            f"Type=7z Method={method_evidence} Solid={solid_evidence}; "
            "requested switches -m0=lzma2 and -ms=on executed",
            flush=True,
        )
        print(
            "ARCHIVE_EXCLUSION_SWITCHES VERIFIED "
            + " ".join(SYSTEM_EXCLUSION_SWITCHES),
            flush=True,
        )

        print("PHASE 9 ARCHIVE TEST", flush=True)
        run([seven_zip, "t", str(staged_archive)], source_parent)
        print("ARCHIVE_TEST PASS", flush=True)

        print("PHASE 10 REAL RECOVERY VERIFICATION", flush=True)
        extraction = Path(
            tempfile.mkdtemp(prefix=".cold-archive-recovery-", dir=output_parent)
        )
        run(
            [seven_zip, "x", str(staged_archive), f"-o{extraction}", "-y"],
            source_parent,
        )
        top_level = sorted(path.name for path in extraction.iterdir())
        if selected_files is None and top_level != [source.name]:
            raise SystemExit(
                "Extraction structure verification failed; expected only top-level "
                f"{source.name!r}, found {top_level!r}."
            )
        recovery_scan_result = scan_recovered_hashes_with_smb_stability(
            extraction / source.name if selected_files is None else extraction,
            target_filesystem,
        )
        restored_records = recovery_scan_result.records
        restored_directories = recovery_scan_result.directories
        restored_excluded = recovery_scan_result.excluded
        require_no_excluded_entries(restored_excluded, "RECOVERED_ARCHIVE")
        compare_records(manifest_records, restored_records, "EXTRACTION_SHA512")
        compare_directories(
            initial_directories, restored_directories, "EXTRACTION_STRUCTURE"
        )

        print("PHASE 11 SOURCE DATA VERIFICATION", flush=True)
        post_archive_records, post_archive_directories, post_archive_excluded = scan_source()
        compare_records(manifest_records, post_archive_records, "SOURCE_SHA512")
        compare_directories(
            initial_directories, post_archive_directories, "SOURCE_STRUCTURE"
        )
        print(
            f"SOURCE_SYSTEM_ENTRIES_EXCLUDED {len(post_archive_excluded)}",
            flush=True,
        )

        print(f"PHASE 12 GENERATE {archive_checksum_filename}", flush=True)
        archive_size = staged_archive.stat().st_size
        archive_digest = sha512(staged_archive)
        staged_checksum = staging / archive_checksum_filename
        write_archive_checksum(staged_checksum, archive_filename, archive_size, archive_digest)
        recorded_archive = read_archive_checksum(staged_checksum, archive_filename)
        if recorded_archive != FileRecord(size=archive_size, digest=archive_digest):
            raise SystemExit("Archive SHA-512 record verification failed.")
        digest_prefix = archive_digest[:16]
        archive_id = f"{created_at:%Y%m%d}_{archive_name_raw}_{digest_prefix}"
        bundle_name = (
            f"{created_at:%Y%m%d}_{archive_name_display_value}_归档_{digest_prefix}"
        )
        bundle = output_parent / bundle_name
        require_absent(bundle, "final archive directory")
        print(f"ARCHIVE_ID {archive_id}", flush=True)
        print(f"FINAL_DIRECTORY {bundle}", flush=True)

        print(f"PHASE 13 GENERATE {ARCHIVE_CONTENTS_NAME}", flush=True)
        created = created_at.isoformat(timespec="seconds")
        expected_archive_contents = write_archive_contents(
            info_directory / ARCHIVE_CONTENTS_NAME,
            archive_filename,
            created_at.strftime("%Y-%m-%d %H:%M:%S"),
            content_root,
            restored_records,
            restored_directories,
        )
        if read_archive_contents_counts(info_directory / ARCHIVE_CONTENTS_NAME) != (
            len(manifest_records),
            len(initial_directories) + bool(content_root),
        ):
            raise SystemExit("Archive contents count verification failed.")

        print(f"PHASE 14 GENERATE {INFO_NAME}", flush=True)
        write_archive_info(
            info_directory / INFO_NAME,
            created=created,
            operating_system=operating_system,
            cpu_architecture=cpu_architecture,
            python_version=python_version,
            source_filesystem=source_filesystem,
            target_filesystem=target_filesystem,
            detected_seven_zip=available_7zip,
            selected_seven_zip_path=seven_zip,
            seven_zip_version=version,
            source=source,
            file_count=len(manifest_records),
            source_size=sum(record.size for record in manifest_records.values()),
            excluded_count=len(initial_excluded),
            archive_filename=archive_filename,
            archive_name_raw=archive_name_raw,
            archive_name_display=archive_name_display_value,
            compatibility_test_location=compatibility_test_result.location,
            compatibility_test_filesystem=compatibility_test_result.filesystem,
            recovery_stability_attempts=recovery_scan_result.attempts,
            recovery_stability_mode=recovery_scan_result.mode,
            archive_size=archive_size,
            archive_id=archive_id,
            archive_folder_name=bundle_name,
            output_directory=output_parent,
            output_directory_mode=output_directory_mode,
        )
        expected_verification_log = write_verification_log(
            info_directory / VERIFICATION_LOG_NAME,
            created=created,
            archive_name_raw=archive_name_raw,
            archive_name_display=archive_name_display_value,
            compatibility_test_location=compatibility_test_result.location,
            compatibility_test_filesystem=compatibility_test_result.filesystem,
            recovery_stability_attempts=recovery_scan_result.attempts,
            recovery_stability_mode=recovery_scan_result.mode,
            archive_filename=archive_filename,
            archive_digest=archive_digest,
            output_directory=output_parent,
            output_directory_mode=output_directory_mode,
        )
        expected_archive_format = write_archive_format(
            info_directory / ARCHIVE_FORMAT_NAME
        )
        expected_compression_info = write_compression_info(
            info_directory / COMPRESSION_INFO_NAME,
            selected_seven_zip_path=seven_zip,
            seven_zip_version=version,
        )
        expected_statistics = write_statistics(
            info_directory / STATISTICS_NAME,
            created=created,
            file_count=len(manifest_records),
            directory_count=len(initial_directories),
            source_size=sum(record.size for record in manifest_records.values()),
            archive_size=archive_size,
            excluded_count=len(initial_excluded),
            compression_seconds=compression_seconds,
        )
        write_readme(
            staging / README_NAME,
            archive_name_raw=archive_name_raw,
            archive_name_display=archive_name_display_value,
            archive_filename=archive_filename,
            archive_checksum_filename=archive_checksum_filename,
            source_name=source.name if selected_files is None else " / ".join(str(path) for path in selected_files),
            archive_folder_name=bundle_name,
            archive_digest_prefix=digest_prefix,
        )

        expected_documents = update_documents(
            staging, originals=inputs, base=source if selected_files is not None else source.parent,
            archive=archive_filename, command=create_command, listing=technical_listing, provenance=provenance, created=created,
        )
        if args.source_answers_json:
            from provenance_answers import validate_source_answers
            validate_source_answers(expected_documents["Documents/" + SOURCE_INFO_NAME], provenance, provenance_value)
        expected_archive_contents = expected_documents["Documents/" + ARCHIVE_CONTENTS_NAME]
        expected_source_info = expected_documents["Documents/" + SOURCE_INFO_NAME]
        expected_statistics = expected_documents["Documents/" + STATISTICS_NAME]
        expected_archive_format = expected_documents["Documents/" + ARCHIVE_FORMAT_NAME]
        expected_compression_info = expected_documents["Documents/" + COMPRESSION_INFO_NAME]
        expected_verification_log = expected_documents["Documents/" + VERIFICATION_LOG_NAME]

        print("PHASE 15 FINAL CHECK AND PUBLISH", flush=True)
        validate_bundle_structure(
            staging, archive_filename, archive_checksum_filename
        )
        validate_readme(
            staging / README_NAME,
            archive_name_raw=archive_name_raw,
            archive_name_display=archive_name_display_value,
            archive_folder_name=bundle_name,
            archive_digest_prefix=digest_prefix,
        )
        validate_archive_info(
            info_directory / INFO_NAME,
            archive_name_raw=archive_name_raw,
            archive_name_display=archive_name_display_value,
            compatibility_test_location=compatibility_test_result.location,
            compatibility_test_filesystem=compatibility_test_result.filesystem,
            recovery_stability_attempts=recovery_scan_result.attempts,
            recovery_stability_mode=recovery_scan_result.mode,
            archive_id=archive_id,
            archive_folder_name=bundle_name,
            output_directory=output_parent,
            output_directory_mode=output_directory_mode,
        )
        if sha512(staged_archive) != recorded_archive.digest:
            raise SystemExit("Archive SHA-512 mismatch immediately before publication.")
        if (info_directory / ARCHIVE_CONTENTS_NAME).read_text(
            encoding="utf-8"
        ) != expected_archive_contents:
            raise SystemExit("Archive contents changed before publication.")
        if (info_directory / SOURCE_INFO_NAME).read_text(
            encoding="utf-8"
        ) != expected_source_info:
            raise SystemExit("Source information changed before publication.")
        if (info_directory / STATISTICS_NAME).read_text(
            encoding="utf-8"
        ) != expected_statistics:
            raise SystemExit("Statistics changed before publication.")
        if (info_directory / ARCHIVE_FORMAT_NAME).read_text(
            encoding="utf-8"
        ) != expected_archive_format:
            raise SystemExit("Archive format document changed before publication.")
        if (info_directory / COMPRESSION_INFO_NAME).read_text(
            encoding="utf-8"
        ) != expected_compression_info:
            raise SystemExit("Compression information changed before publication.")
        if (info_directory / VERIFICATION_LOG_NAME).read_text(
            encoding="utf-8"
        ) != expected_verification_log:
            raise SystemExit("Verification log changed before publication.")
        compare_records(manifest_records, read_manifest(staged_manifest), "SOURCE_MANIFEST_FINAL")

        publish_directory_exclusive(
            staging,
            bundle,
            allow_unsupported_fallback=target_filesystem.casefold().startswith("smb"),
        )
        published = True

        final_archive = bundle / archive_filename
        validate_bundle_structure(bundle, archive_filename, archive_checksum_filename)
        final_info = bundle / INFO_DIRECTORY_NAME
        validate_readme(
            bundle / README_NAME,
            archive_name_raw=archive_name_raw,
            archive_name_display=archive_name_display_value,
            archive_folder_name=bundle_name,
            archive_digest_prefix=digest_prefix,
        )
        validate_archive_info(
            final_info / INFO_NAME,
            archive_name_raw=archive_name_raw,
            archive_name_display=archive_name_display_value,
            compatibility_test_location=compatibility_test_result.location,
            compatibility_test_filesystem=compatibility_test_result.filesystem,
            recovery_stability_attempts=recovery_scan_result.attempts,
            recovery_stability_mode=recovery_scan_result.mode,
            archive_id=archive_id,
            archive_folder_name=bundle_name,
            output_directory=output_parent,
            output_directory_mode=output_directory_mode,
        )
        final_record = read_archive_checksum(
            bundle / archive_checksum_filename, archive_filename
        )
        if final_record.size != final_archive.stat().st_size:
            raise SystemExit(
                f"Final archive size differs from {archive_checksum_filename}."
            )
        if sha512(final_archive) != final_record.digest:
            raise SystemExit("Final archive SHA-512 mismatch after publication.")
        if (final_info / ARCHIVE_CONTENTS_NAME).read_text(
            encoding="utf-8"
        ) != expected_archive_contents:
            raise SystemExit("Final archive contents differ after publication.")
        if (final_info / SOURCE_INFO_NAME).read_text(
            encoding="utf-8"
        ) != expected_source_info:
            raise SystemExit("Final source information differs after publication.")
        if (final_info / STATISTICS_NAME).read_text(
            encoding="utf-8"
        ) != expected_statistics:
            raise SystemExit("Final statistics differ after publication.")
        if (final_info / ARCHIVE_FORMAT_NAME).read_text(
            encoding="utf-8"
        ) != expected_archive_format:
            raise SystemExit("Final archive format document differs after publication.")
        if (final_info / COMPRESSION_INFO_NAME).read_text(
            encoding="utf-8"
        ) != expected_compression_info:
            raise SystemExit(
                "Final compression information differs after publication."
            )
        if (final_info / VERIFICATION_LOG_NAME).read_text(
            encoding="utf-8"
        ) != expected_verification_log:
            raise SystemExit("Final verification log differs after publication.")
        if read_archive_contents_counts(final_info / ARCHIVE_CONTENTS_NAME) != (
            len(manifest_records),
            len(initial_directories) + bool(content_root),
        ):
            raise SystemExit("Final archive contents count verification failed.")
        compare_records(
            manifest_records,
            read_manifest(final_info / SOURCE_MANIFEST_NAME),
            "FINAL_SOURCE_MANIFEST",
        )
        if validate_documents(bundle) != expected_documents:
            raise SystemExit("Bilingual documentation changed during publication")
        if args.source_answers_json:
            validate_source_answers((final_info / SOURCE_INFO_NAME).read_text(), provenance, provenance_value)
        record_completion(bundle)
        complete = True

        print(f"SOURCE_FILES {len(manifest_records)}")
        print(f"SOURCE_BYTES {sum(record.size for record in manifest_records.values())}")
        print(f"ARCHIVE_BYTES {archive_size}")
        print(f"BUNDLE {bundle}")
        print("ARCHIVE_TEST PASS")
        print("EXTRACTION_VERIFICATION PASS")
        print("SOURCE_DATA_VERIFICATION PASS")
        print("ARCHIVE_SHA512 PASS")
        print("ARCHIVE_CONTENTS_VERIFICATION PASS")
        print("SOURCE_INFO_VERIFICATION PASS")
        print("STATISTICS_VERIFICATION PASS")
        print("ARCHIVE_FORMAT_VERIFICATION PASS")
        print("COMPRESSION_INFO_VERIFICATION PASS")
        print("VERIFICATION_LOG_VERIFICATION PASS")
        print("FINAL_BUNDLE_STRUCTURE PASS")
        return 0
    finally:
        if extraction is not None and extraction.exists():
            shutil.rmtree(extraction)
        if not complete:
            if published and bundle is not None and bundle.exists() and not staging.exists():
                bundle.replace(staging)
            if staging.exists():
                shutil.rmtree(staging)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as error:
        print(f"Command failed with exit status {error.returncode}", file=sys.stderr)
        raise SystemExit(error.returncode)
