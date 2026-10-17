#!/usr/bin/env python3
"""Check publishable files without printing potential secrets or personal data.

This checks the current snapshot, not historical commits or remote release assets.
Pass additional private identifiers with --forbid; values never appear in output.
"""
import argparse
import getpass
from pathlib import Path
import re
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--forbid", action="append", default=[])
    parser.add_argument("--app", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    paths = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=root
    ).decode().split("\0")
    files = [root / name for name in paths if name and (root / name).is_file()]
    if args.app:
        if not args.app.is_dir():
            parser.error("App bundle does not exist")
        files.extend(path for path in args.app.rglob("*") if path.is_file())
    identifiers = [str(Path.home()), *args.forbid]
    username = getpass.getuser()
    if len(username) >= 4:
        identifiers.append(username)
    # The current local author's addresses should never leak into a clean snapshot.
    authors = subprocess.check_output(
        ["git", "log", "--all", "--format=%ae%n%ce"], cwd=root
    ).decode().splitlines()
    identifiers.extend(email for email in set(authors) if not email.endswith("@voicescribe.invalid"))
    patterns = {
        "private-key": rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----",
        "github-token": rb"(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})",
        "aws-key": rb"(?:AKIA|ASIA)[A-Z0-9]{16}",
        "provider-token": rb"(?:sk-(?:proj-|ant-api)[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{32,}|hf_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{15,})",
        "credential-url": rb"https?://[^/\s:@]+:[^/\s@]+@",
    }
    findings = []
    for path in sorted(set(files)):
        data = path.read_bytes()
        label = path.relative_to(root) if path.is_relative_to(root) else path.name
        for identifier in identifiers:
            if identifier and identifier.encode().lower() in data.lower():
                findings.append((str(label), "private-identifier"))
                break
        for kind, pattern in patterns.items():
            if re.search(pattern, data):
                findings.append((str(label), kind))
    for path, kind in findings:
        print(f"FAIL: {path}: {kind}")
    if findings:
        return 1
    print(f"PASS: {len(set(files))} publishable files; no checked secrets or local identifiers")
    return 0


if __name__ == "__main__":
    sys.exit(main())
