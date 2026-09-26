"""Print the release notes for a version from CHANGELOG.md."""

import pathlib
import re
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
    if match is None:
        raise SystemExit(f"No changelog entry for version {version}")
    print(match.group(1).strip())


if __name__ == "__main__":
    main()
