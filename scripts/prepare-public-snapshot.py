#!/usr/bin/env python3
"""Create a local, history-free publication candidate; never push or add a remote."""
import argparse
import os
import plistlib
from pathlib import Path
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    version = plistlib.loads((root / "Info.plist").read_bytes())["CFBundleShortVersionString"]
    destination = args.destination.resolve()
    if destination.exists():
        parser.error("Destination already exists; choose a new directory")
    # Only ignored work directories inside the repo may hold a local snapshot.
    if destination.is_relative_to(root) and not destination.is_relative_to(root / "work"):
        parser.error("An in-repository snapshot must be inside work/")
    subprocess.run(["python3", str(root / "scripts/check-public-files.py")], cwd=root, check=True)
    paths = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=root
    ).decode().split("\0")
    destination.mkdir(parents=True)
    for name in paths:
        if not name:
            continue
        source = root / name
        if not source.is_file():
            continue
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        target.chmod(source.stat().st_mode & 0o777)
    environment = os.environ.copy()
    environment.update({"GIT_AUTHOR_NAME": "VoiceScribe Contributors",
                        "GIT_AUTHOR_EMAIL": "contributors@voicescribe.invalid",
                        "GIT_COMMITTER_NAME": "VoiceScribe Contributors",
                        "GIT_COMMITTER_EMAIL": "contributors@voicescribe.invalid", "TZ": "UTC"})
    def git(*arguments):
        subprocess.run(["git", *arguments], cwd=destination, env=environment, check=True)
    git("init", "-b", "master")
    git("config", "user.name", "VoiceScribe Contributors")
    git("config", "user.email", "contributors@voicescribe.invalid")
    git("config", "commit.gpgsign", "false")
    git("config", "core.hooksPath", "/dev/null")
    git("add", "--all")
    git("-c", "user.name=VoiceScribe Contributors", "-c", "user.email=contributors@voicescribe.invalid",
        "commit", "--no-gpg-sign", "-m", f"Prepare v{version} publication snapshot")
    print("Prepared a local snapshot with a neutral author, one commit and no remote.")
    print("Manual validation and release approval are still required.")


if __name__ == "__main__":
    main()
