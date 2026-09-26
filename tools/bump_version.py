"""Increment the Debian package and preference bundle versions for a commit."""

import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
VERSION_PATTERN = re.compile(
    r"^Version:\s*(\d+)\.(\d+)\.(\d+)(?:\+(\d+))?\s*$",
    re.MULTILINE,
)


def bump_kind(message):
    subject = message.strip().splitlines()[0].strip().lower() if message.strip() else ""
    if "[build-fix]" in subject or "[no-version]" in subject:
        return "build"
    header = re.match(r"^([a-z]+)(?:\([^)]*\))?(!)?:", subject)
    if (header and header.group(2)) or "breaking change:" in message.lower():
        return "major"

    kind = header.group(1) if header else None
    if kind in {"feat", "feature", "add", "enhance", "remove", "delete"} or any(
        word in subject for word in ("新增", "增强", "添加", "支持", "删除", "移除")
    ):
        return "minor"
    if kind in {"build", "chore", "ci", "doc", "docs", "style", "test"}:
        return "build"
    if kind is None and any(word in subject for word in ("文档", "测试", "构建", "样式")):
        return "build"
    return "patch"


def replace_plist_value(contents, key, value):
    pattern = re.compile(
        r"(<key>" + re.escape(key) + r"</key>\s*<string>)[^<]*(</string>)"
    )
    updated, count = pattern.subn(
        lambda match: match.group(1) + value + match.group(2),
        contents,
        count=1,
    )
    if count != 1:
        raise ValueError(f"Prefs/Resources/Info.plist 缺少 {key}")
    return updated


def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: python3 tools/bump_version.py <commit-message>")

    control_path = ROOT / "control"
    control = control_path.read_text(encoding="utf-8")
    match = VERSION_PATTERN.search(control)
    if match is None:
        raise SystemExit("control 中的 Version 不是 x.y.z[+build] 格式")

    major, minor, patch, build = (int(value or 0) for value in match.groups())
    kind = bump_kind(sys.argv[1])
    if kind == "major":
        major, minor, patch = major + 1, 0, 0
    elif kind == "minor":
        minor, patch = minor + 1, 0
    elif kind == "patch":
        patch += 1
    build += 1

    semantic_version = f"{major}.{minor}.{patch}"
    version = f"{semantic_version}+{build}"
    control_path.write_text(
        control[:match.start()]
        + f"Version: {version}"
        + control[match.end():],
        encoding="utf-8",
    )

    plist_path = ROOT / "Prefs" / "Resources" / "Info.plist"
    plist = plist_path.read_text(encoding="utf-8")
    plist = replace_plist_value(plist, "CFBundleShortVersionString", semantic_version)
    plist = replace_plist_value(plist, "CFBundleVersion", str(build))
    plist_path.write_text(plist, encoding="utf-8")
    print(version)


if __name__ == "__main__":
    main()
