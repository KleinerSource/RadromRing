"""Print the release notes for a version from CHANGELOG.md."""

import pathlib
import re
import subprocess
import sys


def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: python3 tools/release_notes.py <version>")

    version = sys.argv[1].removeprefix("v")
    changelog = pathlib.Path(__file__).resolve().parents[1] / "CHANGELOG.md"
    text = changelog.read_text(encoding="utf-8")
    match = re.search(
        rf"^## {re.escape(version)}\s*\n(.*?)(?=^## |\Z)",
        text,
        flags=re.MULTILINE | re.DOTALL,
    )
    if match is not None:
        print(match.group(1).strip())
        return

    tag = f"v{version}"
    try:
        previous_tag = subprocess.run(
            ["git", "describe", "--tags", "--abbrev=0", f"{tag}^"],
            check=True,
            capture_output=True,
            text=True,
            encoding="utf-8",
        ).stdout.strip()
        revision = f"{previous_tag}..{tag}"
    except subprocess.CalledProcessError:
        revision = tag

    commits = subprocess.run(
        ["git", "log", "--reverse", "--format=%s", revision],
        check=True,
        capture_output=True,
        text=True,
        encoding="utf-8",
    ).stdout.splitlines()
    commits = [
        subject
        for subject in commits
        if subject.strip()
        and not subject.lower().startswith("chore: bump version to ")
    ]
    if not commits:
        commits = ["本次版本仅更新了构建版本号。"]

    print("本次提交包含以下更新：\n")
    for subject in commits:
        print(f"- {subject}")


if __name__ == "__main__":
    main()
