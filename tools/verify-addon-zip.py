#!/usr/bin/env python3
"""Verify an EZAssist addon zip contains only runtime files.

The zip must use a single top-level EZAssist/ folder, which is what
tools/pack.ps1 writes and what `git archive --prefix=EZAssist/` writes.
Pass --prefix NAME to require a different top-level folder (NAME or NAME/).

Allowed files are EZAssist.mod, EZAssistConfig.xml, paths referenced by
<File name="..."> and <Script file="...">, and root README.md / LICENSE
when those entries are present. Safe directory entries are ignored.

Prints a reason and exits non-zero on failure.

    python3 tools/verify-addon-zip.py [--prefix EZAssist] <zip>
    python3 tools/verify-addon-zip.py self-test
"""

from __future__ import annotations

import argparse
import re
import sys
import tempfile
import zipfile
from pathlib import Path

REQUIRED_FILES = ("EZAssist.mod", "EZAssistConfig.xml")
OPTIONAL_ROOT_FILES = {"README.md", "LICENSE"}
FORBIDDEN_EXTENSIONS = {
    ".ps1",
    ".psm1",
    ".sh",
    ".py",
    ".bat",
    ".cmd",
    ".exe",
    ".dll",
}
FORBIDDEN_SEGMENTS = {
    "tools",
    "scripts",
    ".github",
    ".cursor",
    "spec",
}

FILE_RE = re.compile(
    r"""<File\b[^>]*\bname\s*=\s*(?:"([^"]*)"|'([^']*)')"""
)
SCRIPT_RE = re.compile(
    r"""<Script\b[^>]*\bfile\s*=\s*(?:"([^"]*)"|'([^']*)')"""
)


class VerifyError(Exception):
    """The zip is not a clean EZAssist addon archive."""


def normalize_prefix(prefix: str) -> str:
    cleaned = prefix.strip().replace("\\", "/").strip("/")
    if (
        not cleaned
        or "/" in cleaned
        or cleaned in {".", ".."}
        or is_absolute(cleaned)
    ):
        raise VerifyError(f"invalid --prefix {prefix!r}")
    return cleaned


def is_absolute(name: str) -> bool:
    if name.startswith("/") or name.startswith("\\"):
        return True
    for part in re.split(r"[\\/]", name):
        if len(part) >= 2 and part[0].isalpha() and part[1] == ":":
            return True
    return False


def has_dotdot(name: str) -> bool:
    return any(part == ".." for part in re.split(r"[\\/]", name))


def extension_of(rel: str) -> str:
    base = rel.rsplit("/", 1)[-1]
    dot = base.rfind(".")
    if dot <= 0:
        return ""
    return base[dot:].lower()


def check_forbidden(rel: str, display: str) -> None:
    for segment in rel.split("/"):
        lowered = segment.lower()
        if lowered in FORBIDDEN_SEGMENTS or lowered.startswith(".git"):
            raise VerifyError(f"forbidden path segment '{segment}' in {display}")
        if lowered.startswith("test-") or lowered.endswith("_test.lua"):
            raise VerifyError(f"forbidden test file name: {display}")
    ext = extension_of(rel)
    if ext in FORBIDDEN_EXTENSIONS:
        raise VerifyError(f"forbidden extension {ext}: {display}")


def normalize_ref(raw: str, source: str) -> str:
    text = raw.strip().replace("\\", "/")
    if not text:
        raise VerifyError(f"empty file reference in {source}")
    if is_absolute(text):
        raise VerifyError(f"absolute file reference in {source}: {raw}")
    parts: list[str] = []
    for part in text.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            raise VerifyError(f"file reference escapes the addon folder ({source}): {raw}")
        parts.append(part)
    if not parts:
        raise VerifyError(f"empty file reference in {source}")
    rel = "/".join(parts)
    check_forbidden(rel, f"{source} reference {rel}")
    return rel


def attr_value(match: re.Match[str]) -> str:
    return match.group(1) if match.group(1) is not None else match.group(2)


def referenced_paths(mod_text: str, xml_text: str) -> set[str]:
    refs: set[str] = set()
    for match in FILE_RE.finditer(mod_text):
        refs.add(normalize_ref(attr_value(match), "EZAssist.mod"))
    for match in SCRIPT_RE.finditer(xml_text):
        refs.add(normalize_ref(attr_value(match), "EZAssistConfig.xml"))
    if not any(True for _ in FILE_RE.finditer(mod_text)):
        raise VerifyError('no <File name="..."> entries in EZAssist.mod')
    if not any(True for _ in SCRIPT_RE.finditer(xml_text)):
        raise VerifyError('no <Script file="..."> entries in EZAssistConfig.xml')
    return refs


def relative_to_prefix(stripped: str, prefix: str) -> str:
    if stripped == prefix:
        return ""
    head = prefix + "/"
    if not stripped.startswith(head):
        raise VerifyError(f"zip entry is outside {prefix}/: {stripped}")
    rel = stripped[len(head):]
    if rel == "":
        raise VerifyError(f"zip entry is outside {prefix}/: {stripped}")
    if rel == prefix or rel.startswith(prefix + "/"):
        raise VerifyError(f"zip entry is nested as {prefix}/{prefix}/: {stripped}")
    return rel


def classify_entry(name: str, prefix: str) -> str | None:
    """Return the addon-relative file path, or None for an ignored directory."""
    if "\\" in name:
        raise VerifyError(f"zip entry uses backslashes: {name}")
    if is_absolute(name):
        raise VerifyError(f"zip entry is absolute: {name}")
    if has_dotdot(name):
        raise VerifyError(f"zip entry escapes the archive: {name}")
    if name == "":
        raise VerifyError("zip entry has an empty name")

    is_dir = name.endswith("/")
    stripped = name[:-1] if is_dir else name
    if stripped == "":
        raise VerifyError(f"zip entry is absolute: {name}")
    rel = relative_to_prefix(stripped, prefix)
    if rel == "":
        if is_dir:
            return None
        raise VerifyError(f"zip entry is outside {prefix}/: {name}")
    check_forbidden(rel, name)
    if is_dir:
        return None
    return rel


def read_text_member(zf: zipfile.ZipFile, entry: str) -> str:
    try:
        data = zf.read(entry)
    except KeyError as exc:
        raise VerifyError(f"missing {entry}") from exc
    try:
        return data.decode("utf-8-sig")
    except UnicodeDecodeError as exc:
        raise VerifyError(f"{entry} is not utf-8") from exc


def verify_zip(path: str, prefix: str = "EZAssist") -> str:
    root = normalize_prefix(prefix)
    zip_path = Path(path)
    if not zip_path.is_file():
        raise VerifyError(f"zip not found: {path}")
    try:
        zf = zipfile.ZipFile(zip_path)
    except zipfile.BadZipFile as exc:
        raise VerifyError(f"cannot read zip: {exc}") from exc

    with zf:
        files: dict[str, str] = {}
        for info in zf.infolist():
            raw_name = getattr(info, "orig_filename", info.filename)
            for candidate in (info.filename, raw_name):
                if "\\" in candidate:
                    raise VerifyError(f"zip entry uses backslashes: {candidate}")
            rel = classify_entry(info.filename, root)
            if rel is None:
                continue
            if rel in files:
                raise VerifyError(f"duplicate zip entry: {info.filename}")
            files[rel] = info.filename

        for required in REQUIRED_FILES:
            if required not in files:
                raise VerifyError(f"missing {required}")

        mod_text = read_text_member(zf, files["EZAssist.mod"])
        xml_text = read_text_member(zf, files["EZAssistConfig.xml"])
        refs = referenced_paths(mod_text, xml_text)
        for ref in sorted(refs):
            if ref not in files:
                raise VerifyError(f"referenced file missing from zip: {ref}")

        allowed = set(REQUIRED_FILES)
        allowed.update(OPTIONAL_ROOT_FILES)
        allowed.update(refs)
        for rel in sorted(files):
            if rel not in allowed:
                raise VerifyError(f"unreferenced file is not allowed: {files[rel]}")

    return f"ok: {zip_path} ({len(files)} files under {root}/)"


def _zip_info(name: str) -> zipfile.ZipInfo:
    info = zipfile.ZipInfo(filename=name)
    info.date_time = (2026, 1, 1, 0, 0, 0)
    info.compress_type = zipfile.ZIP_DEFLATED
    return info


def write_zip(path: Path, entries: list[tuple[str, bytes]]) -> None:
    with zipfile.ZipFile(path, "w") as zf:
        for name, data in entries:
            zf.writestr(_zip_info(name), data)


MOD_MIN = b"""<?xml version="1.0" encoding="UTF-8"?>
<ModuleFile>
    <UiMod name="EZAssist" version="0.0.0">
        <Files>
            <File name="EZAssist.lua" />
            <File name="EZAssistConfig.xml" />
        </Files>
    </UiMod>
</ModuleFile>
"""

XML_MIN = b"""<?xml version="1.0" encoding="UTF-8"?>
<Interface>
    <Scripts>
        <Script file="EZAssist_Config.lua"/>
    </Scripts>
</Interface>
"""

MOD_FULL = b"""<?xml version="1.0" encoding="UTF-8"?>
<ModuleFile>
    <UiMod name="EZAssist" version="0.0.0">
        <Files>
            <File name="EZAssist.lua" />
            <File name="EZAssistConfig.xml" />
            <File name="assets/icon.tga" />
        </Files>
    </UiMod>
</ModuleFile>
"""


def minimal_entries() -> list[tuple[str, bytes]]:
    return [
        ("EZAssist/EZAssist.mod", MOD_MIN),
        ("EZAssist/EZAssistConfig.xml", XML_MIN),
        ("EZAssist/EZAssist.lua", b"-- lua\n"),
        ("EZAssist/EZAssist_Config.lua", b"-- config\n"),
    ]


def full_entries() -> list[tuple[str, bytes]]:
    return [
        ("EZAssist/", b""),
        ("EZAssist/assets/", b""),
        ("EZAssist/EZAssist.mod", MOD_FULL),
        ("EZAssist/EZAssistConfig.xml", XML_MIN),
        ("EZAssist/EZAssist.lua", b"-- lua\n"),
        ("EZAssist/EZAssist_Config.lua", b"-- config\n"),
        ("EZAssist/assets/icon.tga", b"TGA"),
        ("EZAssist/README.md", b"readme\n"),
        ("EZAssist/LICENSE", b"license\n"),
    ]


def verdict(path: Path, prefix: str = "EZAssist") -> tuple[bool, str]:
    try:
        return True, verify_zip(str(path), prefix=prefix)
    except VerifyError as exc:
        return False, str(exc)


def self_test() -> int:
    failures: list[str] = []

    def check(label: str, path: Path, *, ok: bool, needle: str | None = None, prefix: str = "EZAssist") -> None:
        passed, reason = verdict(path, prefix=prefix)
        if passed != ok or (needle is not None and needle not in reason):
            expected = "pass" if ok else f"fail mentioning {needle!r}"
            failures.append(f"{label}: expected {expected}; got {reason!r}")
            print(f"self-test FAIL {label}: {reason}", file=sys.stderr)
            return
        print(f"self-test {label}: {reason}")

    with tempfile.TemporaryDirectory(prefix="ezassist-zip-") as tmp:
        root = Path(tmp)
        clean = root / "clean.zip"
        write_zip(clean, full_entries())
        check("clean zip passes", clean, ok=True)

        packed = root / "packed.zip"
        write_zip(packed, minimal_entries())
        check("packed layout passes", packed, ok=True)
        check("prefix flag passes", packed, ok=True, prefix="EZAssist/")

        cases: list[tuple[str, str, bytes, str]] = [
            ("ps1 fails", "EZAssist/deploy.ps1", b"echo hi\n", "forbidden extension .ps1"),
            ("tools path fails", "EZAssist/tools/note.txt", b"x\n", "forbidden path segment 'tools'"),
            ("github fails", "EZAssist/.github/workflows/evil.yml", b"name: x\n", "forbidden path segment '.github'"),
            ("cursor fails", "EZAssist/.cursor/rules/x.mdc", b"x\n", "forbidden path segment '.cursor'"),
            ("git file fails", "EZAssist/.gitignore", b"*.zip\n", "forbidden path segment '.gitignore'"),
            ("nested fails", "EZAssist/EZAssist/EZAssist.lua", b"-- nested\n", "nested"),
            ("unreferenced lua fails", "EZAssist/Extra.lua", b"-- extra\n", "unreferenced"),
            ("py fails", "EZAssist/helper.py", b"print(1)\n", "forbidden extension .py"),
            ("sh fails", "EZAssist/run.sh", b"#!/bin/sh\n", "forbidden extension .sh"),
            ("scripts path fails", "EZAssist/scripts/hook.lua", b"-- hook\n", "forbidden path segment 'scripts'"),
            ("spec path fails", "EZAssist/spec/demo.lua", b"-- spec\n", "forbidden path segment 'spec'"),
            ("test- file fails", "EZAssist/test-foo.lua", b"-- test\n", "forbidden test file name"),
            ("_test.lua fails", "EZAssist/foo_test.lua", b"-- test\n", "forbidden test file name"),
            ("dotdot fails", "EZAssist/../../secret.lua", b"x\n", "escapes the archive"),
            ("absolute fails", "/etc/passwd", b"x\n", "absolute"),
            ("outside prefix fails", "README.md", b"readme\n", "outside EZAssist/"),
        ]
        for label, name, data, needle in cases:
            path = root / (label.split()[0] + ".zip")
            write_zip(path, minimal_entries() + [(name, data)])
            check(label, path, ok=False, needle=needle)

        backslash = root / "backslash.zip"
        write_zip(backslash, minimal_entries() + [("EZAssist\\sneaky.lua", b"-- bad\n")])
        check("backslash fails", backslash, ok=False, needle="backslash")

        other = root / "other-prefix.zip"
        renamed = [(name.replace("EZAssist/", "Addon/", 1), data) for name, data in minimal_entries()]
        write_zip(other, renamed)
        check("other prefix passes", other, ok=True, prefix="Addon")
        check("wrong prefix fails", other, ok=False, needle="outside EZAssist/")

    if failures:
        print(f"self-test failed ({len(failures)})", file=sys.stderr)
        return 1
    print("verify-addon-zip self-test ok")
    return 0


def main(argv: list[str]) -> int:
    if argv[:1] == ["self-test"]:
        if len(argv) != 1:
            print("usage: verify-addon-zip.py self-test", file=sys.stderr)
            return 2
        return self_test()

    parser = argparse.ArgumentParser(description="Verify an EZAssist addon zip.")
    parser.add_argument(
        "--prefix",
        default="EZAssist",
        help="Required top-level folder (default: EZAssist). "
        "Use EZAssist for tools/pack.ps1 and for git archive --prefix=EZAssist/.",
    )
    parser.add_argument("zip_path", help="Path to the addon zip")
    args = parser.parse_args(argv)
    try:
        print(verify_zip(args.zip_path, prefix=args.prefix))
    except VerifyError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
