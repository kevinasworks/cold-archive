# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Stage corresponding sources and refuse release builds with unresolved materials."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / "vendor"
POLICY = VENDOR / "compliance/release-materials.json"


def check_file(relative, expected, errors, *, root=VENDOR):
    path = root / relative
    if not path.is_file() or not path.stat().st_size:
        errors.append(f"缺少材料 {relative}")
        return None
    if expected:
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        if digest.hexdigest() != expected:
            errors.append(f"SHA-256 不匹配 {relative}")
            return None
    return path


def check_data_directories(policy, root, errors):
    for relative, expected in policy.get("data_directories", {}).items():
        directory = root / relative
        if not directory.is_dir():
            errors.append(f"缺少数据目录 {relative}")
            continue
        digest = hashlib.sha256()
        for path in sorted(directory.iterdir()):
            if not path.is_file() or path.is_symlink():
                errors.append(f"数据目录含非普通文件 {relative}/{path.name}")
                continue
            digest.update(path.name.encode("utf-8") + b"\0")
            digest.update(hashlib.sha256(path.read_bytes()).digest())
        if digest.hexdigest() != expected:
            errors.append(f"数据目录 SHA-256 不匹配 {relative}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("release", "local"), default="release")
    output = parser.add_mutually_exclusive_group()
    output.add_argument("--resources", type=Path)
    output.add_argument("--verify-resources", type=Path)
    args = parser.parse_args()
    policy = json.loads(POLICY.read_text())
    notices = ROOT / "THIRD_PARTY_NOTICES.md"
    if not notices.is_file() or not notices.stat().st_size:
        parser.exit(1, "缺少 THIRD_PARTY_NOTICES.md\n")
    if args.verify_resources:
        root = args.verify_resources
        errors = list(policy["pending"]) if args.mode == "release" else []
        if args.mode == "release" and (root / "LOCAL_VALIDATION_ONLY.txt").exists():
            errors.append("本地验证包不能通过正式发行校验（LOCAL_VALIDATION_ONLY.txt）")
        check_data_directories(policy, root / "Runtime", errors)
        manifest = root / "Runtime/component-manifest.json"
        if not manifest.is_file():
            parser.exit(1, "缺少包内 Runtime/component-manifest.json\n")
        signed_hashes = json.loads(manifest.read_text())["binaries"]
        for document in (notices, ROOT / "LICENSE", ROOT / "OPEN_SOURCE.md"):
            check_file(document.name, hashlib.sha256(document.read_bytes()).hexdigest(), errors, root=root)
        for path, expected in policy["inputs"].items():
            runtime_path = Path(path).relative_to("runtime")
            # The runtime packager records new hashes after signing Mach-O files.
            expected = signed_hashes.get(runtime_path.as_posix(), expected)
            check_file(Path("Runtime") / runtime_path, expected, errors, root=root)
        for path, expected in policy["licenses"].items():
            relative = Path("Runtime") / Path(path).relative_to("runtime")
            check_file(relative, expected, errors, root=root)
        for component, files in policy["sources"].items():
            for path, expected in files.items():
                relative = Path("CorrespondingSource") / component / Path(path).name
                check_file(relative, expected, errors, root=root)
        if errors:
            parser.exit(1, "包内第三方材料校验失败：\n" + "\n".join(errors) + "\n")
        if args.mode == "release":
            subprocess.run([sys.executable, '-B', str(ROOT/'scripts/public-source.py'), '--verify-output', str(root/'CorrespondingSource/ColdArchive')], check=True)
        print(f"PASS ({args.mode}): packaged runtime inputs, notices, licenses and corresponding sources")
        return
    errors = list(policy["pending"])
    # The source tree uses "runtime"; the app bundle uses "Runtime".
    check_data_directories(policy, VENDOR / "runtime", errors)
    for path, expected in (policy["inputs"] | policy["licenses"]).items():
        check_file(path, expected, errors)
    materials = {}
    for component, files in policy["sources"].items():
        materials[component] = [
            path for relative, expected in files.items()
            if (path := check_file(relative, expected, errors)) is not None
        ]
    if errors:
        message = "\n".join(f"  - {error}" for error in errors)
        if args.mode == "release":
            parser.exit(1, f"第三方发行材料不完整：\n{message}\n")
        print(f"本地验证构建，禁止作为正式发行包使用：\n{message}")
    if args.resources:
        for document in (notices, ROOT / "LICENSE", ROOT / "OPEN_SOURCE.md"):
            shutil.copy2(document, args.resources)
        if args.mode == "local":
            (args.resources / "LOCAL_VALIDATION_ONLY.txt").write_text(
                "Local validation build. Not for distribution.\n"
                + "\n".join(errors) + "\n",
                encoding="utf-8",
            )
        for component, paths in materials.items():
            destination = args.resources / "CorrespondingSource" / component
            destination.mkdir(parents=True, exist_ok=True)
            for path in paths:
                shutil.copy2(path, destination / path.name)
        if args.mode == "release":
            with tempfile.TemporaryDirectory(prefix='cold-project-source-') as directory:
                exported = Path(directory) / 'source'
                subprocess.run([sys.executable, '-B', str(ROOT/'scripts/public-source.py'), '--output', str(exported)], check=True)
                shutil.copytree(exported, args.resources/'CorrespondingSource/ColdArchive')


if __name__ == "__main__":
    main()
