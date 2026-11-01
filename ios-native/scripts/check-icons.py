#!/usr/bin/env python3
"""Fail when a view writes an SF Symbol name inline instead of using AppIcon.

Every icon in HPlayer comes from `Views/Icons.swift`, which keeps the whole app
on one outline family and reserves filled glyphs for active states.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1] / "HPlayer"
ALLOWED = {"Icons.swift"}

# systemName: "x", systemImage: "x", symbol: "x", icon: "x", and ternaries such as ? "x" : "y"
# on a line that also names one of those arguments.
ARGUMENT = re.compile(r'\b(systemName|systemImage|symbol|icon|controlIcon)\b')
LITERAL = re.compile(r'"([a-z][a-z0-9]*(?:\.[a-z0-9]+)+|house|circle|plus|trash|photo|film|tv|link|key|doc|folder|clock|camera|play|iphone|icloud|person|moon|checkmark|xmark|ellipsis|magnifyingglass|gearshape|return|sparkles|waveform|checklist|viewfinder|goforward)"')
SAFE_PREFIXES = ("screen.", "home.", "library.", "settings.", "search.", "player.", "playback.", "scan.", "series.",
                 "magnet.", "torrent.", "account.", "metadata.", "detail.", "tab.", "cloud.", "mine.", "performer.", "manage.", "catalog.", "history.")


def main() -> int:
    problems = []
    for path in sorted((ROOT / "Views").glob("*.swift")):
        if path.name in ALLOWED:
            continue
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if "accessibilityIdentifier" in line or "designScreen" in line:
                continue
            if not ARGUMENT.search(line):
                continue
            for match in LITERAL.finditer(line):
                if match.group(1).startswith(SAFE_PREFIXES):
                    continue
                problems.append(f"{path.relative_to(ROOT.parent)}:{number}: inline symbol \"{match.group(1)}\" — use AppIcon")
    for problem in problems:
        print(problem)
    if problems:
        print(f"{len(problems)} inline SF Symbol name(s) found; add a case to AppIcon instead.", file=sys.stderr)
        return 1
    print("check-icons: every icon comes from AppIcon")
    return 0


if __name__ == "__main__":
    sys.exit(main())
