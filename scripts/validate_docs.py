"""Check the ElektroPOS documentation bundle using Python's standard library.

This validates structure and traceability, not business correctness or an app.
Run from any directory: python <repo>/scripts/validate_docs.py
"""

from __future__ import annotations

import hashlib
import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
ARCHIVE = ROOT / "docs/archive/PRD-ElektroPOS-v1.0.md"
ARCHIVE_SHA256 = "f0f0b7dd1bf92cbe404ed3046836553368b405c7b8bfbbefbef860ba76be4478"
files = [ROOT / name for name in ("README.md", "AGENTS.md", "PRD-ElektroPOS.md", "PROMPT-PERTAMA.md")]
files += sorted(p for p in (ROOT / "docs").rglob("*.md") if "archive" not in p.parts)
errors: list[str] = []
texts: dict[Path, str] = {}

for path in files:
    if not path.is_file():
        errors.append(f"Missing required file: {path.relative_to(ROOT)}")
        continue
    body = path.read_text(encoding="utf-8-sig")
    texts[path] = body
    if "\ufffd" in body:
        errors.append(f"Replacement character found: {path.relative_to(ROOT)}")
    fences = re.findall(r"^\s*```", body, re.MULTILINE)
    if len(fences) % 2:
        errors.append(f"Unbalanced code fence: {path.relative_to(ROOT)}")
    for match in re.finditer(r"!?\[[^\]\n]+\]\(([^)\n]+)\)", body):
        raw = match.group(1).strip().strip("<>")
        if urlsplit(raw).scheme or raw.startswith("#"):
            continue
        local = unquote(raw.split("#", 1)[0])
        if not local:
            continue
        target = (path.parent / local).resolve()
        try:
            target.relative_to(ROOT)
        except ValueError:
            errors.append(f"Local link escapes repository: {path.relative_to(ROOT)} -> {raw}")
            continue
        if not target.exists():
            errors.append(f"Broken local link: {path.relative_to(ROOT)} -> {raw}")


def definitions(prefix: str) -> dict[str, Path]:
    result: dict[str, Path] = {}
    pattern = rf"^#{{2,3}}\s+({prefix})\s+[—–-]"
    for path, body in texts.items():
        for identifier in re.findall(pattern, body, re.MULTILINE):
            if identifier in result:
                errors.append(f"Duplicate definition {identifier}: {path.name}")
            result[identifier] = path
    return result


fr = definitions(r"FR-[A-Z]+-\d{2}")
at = definitions(r"AT-\d{2}")
br = definitions(r"BR-\d{2}")
dec = definitions(r"DEC-[UD]\d{2}")
decision_text = texts.get(ROOT / "docs/01-SCOPE-DECISIONS.md", "")
for identifier in re.findall(r"^\|\s*(DEC-O\d{2})\s*\|", decision_text, re.MULTILINE):
    if identifier in dec:
        errors.append(f"Duplicate decision definition: {identifier}")
    dec[identifier] = ROOT / "docs/01-SCOPE-DECISIONS.md"

for label, known, pattern in (
    ("feature", fr, r"\bFR-[A-Z]+-\d{2}\b"),
    ("acceptance test", at, r"\bAT-\d{2}\b"),
    ("business rule", br, r"\bBR-\d{2}\b"),
    ("decision", dec, r"\bDEC-[UDO]\d{2}\b"),
):
    if not known:
        errors.append(f"No {label} definitions found")
    for path, body in texts.items():
        for identifier in set(re.findall(pattern, body)):
            if identifier not in known:
                errors.append(f"Unknown {label} {identifier}: {path.relative_to(ROOT)}")

trace = texts.get(ROOT / "docs/10-TRACEABILITY.md", "")
mapped: dict[str, list[str]] = {}
for line in trace.splitlines():
    feature = re.match(r"^\|\s*(FR-[A-Z]+-\d{2})\s*\|", line)
    if feature:
        identifier = feature.group(1)
        if identifier in mapped:
            errors.append(f"Duplicate traceability row: {identifier}")
        mapped[identifier] = re.findall(r"\bAT-\d{2}\b", line)
        if not mapped[identifier]:
            errors.append(f"Feature has no acceptance mapping: {identifier}")

for identifier in sorted(set(fr) - set(mapped)):
    errors.append(f"Missing feature traceability row: {identifier}")
for identifier in sorted(set(mapped) - set(fr)):
    errors.append(f"Traceability feature not in PRD: {identifier}")
used_tests = {identifier for ids in mapped.values() for identifier in ids}
for identifier in sorted(set(at) - used_tests):
    errors.append(f"Acceptance test has no feature mapping: {identifier}")

if not ARCHIVE.is_file():
    errors.append("Original PRD archive is missing")
elif hashlib.sha256(ARCHIVE.read_bytes()).hexdigest() != ARCHIVE_SHA256:
    errors.append("Original PRD archive hash differs from preserved v1.0")

if errors:
    print("FAIL: documentation checks")
    for error in errors:
        print(f"- {error}")
    sys.exit(1)

print(f"PASS: {len(texts)} active Markdown documents, local links and code fences checked")
print(f"PASS: {len(fr)} features, {len(at)} acceptance cases, {len(br)} business rules, {len(dec)} decisions")
print("PASS: every feature/test is mapped; original PRD archive SHA256 unchanged")
print("Scope: structural checks only; application implementation, tests and production readiness are not verified.")
