"""Build a flat APT repository (Sileo/Zebra compatible) from .deb packages.

Usage: python3 tools/build_repo.py <deb-dir> <output-dir>

The runner has no dpkg tooling, so control metadata is read directly from the
ar archive with the standard library.
"""

import bz2
import gzip
import hashlib
import io
import lzma
import pathlib
import shutil
import sys
import tarfile

REPO_FIELDS = {
    "Origin": "RandomRing",
    "Label": "RandomRing",
    "Suite": "stable",
    "Version": "1.0",
    "Codename": "stable",
    "Architectures": "iphoneos-arm64e",
    "Components": "main",
    "Description": "RandomRing random incoming-call ringtones for RootHide iOS 17.0",
}

CONTROL_FIELD_ORDER = (
    "Package", "Name", "Version", "Architecture", "Description", "Maintainer",
    "Author", "Section", "Depends", "Conflicts", "Replaces", "Installed-Size",
)


def ar_members(data):
    if not data.startswith(b"!<arch>\n"):
        raise ValueError("not an ar archive")
    offset = 8
    while offset + 60 <= len(data):
        header = data[offset:offset + 60]
        name = header[:16].decode("ascii").strip().rstrip("/")
        size = int(header[48:58].decode("ascii").strip())
        offset += 60
        yield name, data[offset:offset + size]
        offset += size + (size % 2)


def decompress(name, payload):
    if name.endswith(".gz"):
        return gzip.decompress(payload)
    if name.endswith(".xz") or name.endswith(".lzma"):
        return lzma.decompress(payload)
    if name.endswith(".bz2"):
        return bz2.decompress(payload)
    if name.endswith(".tar"):
        return payload
    raise ValueError(f"unsupported compression: {name}")


def read_control(deb_bytes):
    for name, payload in ar_members(deb_bytes):
        if not name.startswith("control.tar"):
            continue
        with tarfile.open(fileobj=io.BytesIO(decompress(name, payload)), mode="r:") as archive:
            for member in archive.getmembers():
                if member.name.lstrip("./") == "control":
                    return archive.extractfile(member).read().decode("utf-8")
    raise ValueError("control file not found")


def parse_control(text):
    fields = {}
    key = None
    for line in text.splitlines():
        if not line.strip():
            continue
        if line[0] in " \t" and key is not None:
            fields[key] += "\n" + line
            continue
        key, _, value = line.partition(":")
        key = key.strip()
        fields[key] = value.strip()
    return fields


def format_stanza(fields):
    ordered = [key for key in CONTROL_FIELD_ORDER if key in fields]
    ordered += [key for key in fields if key not in ordered]
    return "".join(f"{key}: {fields[key]}\n" for key in ordered)


def digest_fields(data):
    return {
        "Size": str(len(data)),
        "MD5sum": hashlib.md5(data).hexdigest(),
        "SHA1": hashlib.sha1(data).hexdigest(),
        "SHA256": hashlib.sha256(data).hexdigest(),
    }


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    source = pathlib.Path(sys.argv[1])
    output = pathlib.Path(sys.argv[2])
    debs = sorted(source.glob("*.deb"))
    if not debs:
        raise SystemExit(f"No .deb files in {source}")

    (output / "debs").mkdir(parents=True, exist_ok=True)
    stanzas = []
    for deb in debs:
        data = deb.read_bytes()
        fields = parse_control(read_control(data))
        fields["Filename"] = f"./debs/{deb.name}"
        fields.update(digest_fields(data))
        stanzas.append(format_stanza(fields))
        shutil.copyfile(deb, output / "debs" / deb.name)

    packages = "\n".join(stanzas).encode("utf-8")
    indexes = {
        "Packages": packages,
        "Packages.gz": gzip.compress(packages, mtime=0),
        "Packages.bz2": bz2.compress(packages),
        "Packages.xz": lzma.compress(packages),
    }
    for name, content in indexes.items():
        (output / name).write_bytes(content)

    release = "".join(f"{key}: {value}\n" for key, value in REPO_FIELDS.items())
    for algorithm, label in (("md5", "MD5Sum"), ("sha1", "SHA1"), ("sha256", "SHA256")):
        release += f"{label}:\n"
        for name, content in indexes.items():
            digest = hashlib.new(algorithm, content).hexdigest()
            release += f" {digest} {len(content)} {name}\n"
    (output / "Release").write_text(release, encoding="utf-8")
    print(f"Repository with {len(debs)} package(s) written to {output}")


if __name__ == "__main__":
    main()
