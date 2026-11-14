"""Check that relative links in the repository's Markdown files resolve (T7.8, T11.13).

Usage: python scripts/check_links.py [--root ..]

Reads every tracked *.md file (git ls-files; all *.md under the root without git). For each
Markdown link or image whose target is not a URL, the target file must exist, and a
`#fragment` on a Markdown target must match one of its headings (GitHub's anchor rule) or an
explicit `<a id="...">`. Links inside code blocks and code spans are ignored. Exits 1 and
lists the broken links if any are found.
"""

from __future__ import annotations

import argparse
import re
import subprocess
from pathlib import Path
from urllib.parse import unquote

LINK = re.compile(r"!?\[(?:[^\]\[]|\[[^\]]*\])*\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
FENCE = re.compile(r"^\s*(```|~~~)")
CODE_SPAN = re.compile(r"`[^`\n]*`")
HEADING = re.compile(r"^\s{0,3}#{1,6}\s+(.*?)\s*#*\s*$")
ANCHOR_ID = re.compile(r"<a\s+(?:id|name)=\"([^\"]+)\"")
EXTERNAL = ("http://", "https://", "mailto:", "tel:")


def markdown_files(root: Path) -> list[Path]:
    try:
        out = subprocess.run(
            ["git", "-C", str(root), "ls-files", "-z", "--", "*.md"],
            capture_output=True,
            check=True,
        ).stdout.decode("utf-8")
        files = [root / name for name in out.split("\0") if name]
    except (OSError, subprocess.CalledProcessError):
        files = [p for p in root.rglob("*.md") if ".git" not in p.parts]
    return sorted(p for p in files if p.is_file())


def prose_lines(text: str) -> list[str]:
    """The file's lines with fenced code blocks blanked and code spans removed."""
    lines, fenced = [], False
    for line in text.splitlines():
        if FENCE.match(line):
            fenced = not fenced
            lines.append("")
            continue
        lines.append("" if fenced else CODE_SPAN.sub("", line))
    return lines


def slug(heading: str) -> str:
    """GitHub's heading anchor: lower case, punctuation dropped, spaces to hyphens."""
    text = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", heading)  # link text only
    text = re.sub(r"[`*_]", "", text).strip().lower()
    text = re.sub(r"[^\w\- ]", "", text)
    return text.replace(" ", "-")


def anchors(path: Path) -> set[str]:
    text = path.read_text(encoding="utf-8")
    found = set(ANCHOR_ID.findall(text))
    seen: dict[str, int] = {}
    fenced = False
    for line in text.splitlines():
        if FENCE.match(line):
            fenced = not fenced
            continue
        m = None if fenced else HEADING.match(line)
        if not m:
            continue
        base = slug(m.group(1))
        count = seen.get(base, 0)
        seen[base] = count + 1
        found.add(base if count == 0 else f"{base}-{count}")  # repeated headings get -1, -2
    return found


def check(root: Path) -> list[str]:
    problems = []
    anchor_cache: dict[Path, set[str]] = {}
    for path in markdown_files(root):
        lines = prose_lines(path.read_text(encoding="utf-8"))
        for number, line in enumerate(lines, start=1):
            for target in LINK.findall(line):
                if target.startswith(EXTERNAL):
                    continue
                file_part, _, fragment = target.partition("#")
                dest = (path.parent / unquote(file_part)).resolve() if file_part else path
                where = f"{path.relative_to(root).as_posix()}:{number}"
                if not dest.exists():
                    problems.append(f"{where}: {target} (file not found)")
                    continue
                if fragment and dest.suffix.lower() == ".md":
                    if dest not in anchor_cache:
                        anchor_cache[dest] = anchors(dest)
                    if unquote(fragment).lower() not in anchor_cache[dest]:
                        problems.append(f"{where}: {target} (no such heading)")
    return problems


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()
    root = args.root.resolve()
    problems = check(root)
    for p in problems:
        print(p)
    count = len(markdown_files(root))
    if problems:
        raise SystemExit(f"{len(problems)} broken link(s) in {count} Markdown files")
    print(f"all relative links resolve in {count} Markdown files")


if __name__ == "__main__":
    main()
