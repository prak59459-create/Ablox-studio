#!/usr/bin/env python3
"""Checks that the app can actually be shown in both languages.

Two things go wrong here that nothing else notices. Neither breaks the build,
neither shows up in a test, and both look finished in a diff:

1. A user-facing literal that was never wrapped in ``L(...)``. It renders in
   English however the language is set.
2. An ``L("…")`` with no row in ``Strings.swift``. It falls back to English —
   correct behaviour, but one English line in an otherwise Japanese screen.

Written in Python rather than bash because both checks need to understand Swift
string literals: escaped quotes, and ``\\(interpolations)`` that must not be
mistaken for words needing translation.

Usage: scripts/check-translations.py <repo root>
"""

import pathlib
import re
import sys

# SwiftUI initialisers whose first argument is shown to a person.
CONSTRUCTORS = (
    "Text|Label|Button|TextField|SecureField|Picker|Toggle|Badge|"
    "SectionHeader|EmptyStateView|InspectorGroup|Stepper|Link|Menu"
)

# `\b` matters: without it `toolbarButton("scope"` matches the `Button` rule and
# reports an SF Symbol name as untranslated text.
# The alternation must be grouped. Without `(?:…)` the `\(` applies only to
# the last name in the list, so every other constructor matches on its own
# and captures nothing — the check then reports no problems, ever.
LITERAL = re.compile(rf'(?<![A-Za-z])(?:{CONSTRUCTORS})\(\s*"((?:[^"\\]|\\.)*)"')
CALL = re.compile(r'(?<![A-Za-z])L\(\s*"((?:[^"\\]|\\.)*)"')
KEY = re.compile(r'^\s*\("((?:[^"\\]|\\.)*)",', re.M)

INTERPOLATION = re.compile(r'\\\([^)]*\)')
HAS_WORD = re.compile(r"[A-Za-z]{2,}")

# Strings that are the same in every language: the brand, an example room code,
# units, and symbols. Translating them would mean catalogue rows that translate
# to themselves.
LANGUAGE_NEUTRAL = {
    "ABLOX", "Ablox", "Ablox Studio", "ABC DEF",
    "0.25 m", "0.5 m", "1 m", "2 m", "15°", "45°", "90°",
    "+", "−", "×", "%",
}

SYMBOL = re.compile(r"^[a-z0-9]+(\.[a-z0-9]+)+$")


def needs_translation(literal: str) -> bool:
    """True if the literal contains words a person would read.

    A literal that is only an interpolated number — `Text("\\(player.score)")` —
    has nothing to translate, and demanding it be wrapped would be noise that
    trains people to ignore this check.
    """
    if literal in LANGUAGE_NEUTRAL or SYMBOL.match(literal):
        return False
    return bool(HAS_WORD.search(INTERPOLATION.sub("", literal)))


def main() -> int:
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    apps = list(root.glob("*.swiftpm"))
    if not apps:
        print(f"no .swiftpm found under {root}", file=sys.stderr)
        return 2

    status = 0
    for app in apps:
        catalogue = app / "Sources/AbloxCore/Strings.swift"
        if not catalogue.exists():
            print(f"  \033[31m✗\033[0m {catalogue} is missing")
            status = 1
            continue

        keys = set(KEY.findall(catalogue.read_text()))
        unwrapped: list[str] = []
        used: dict[str, str] = {}

        for path in sorted(app.rglob("Sources/**/*.swift")):
            if path.name == "Strings.swift":
                continue
            text = path.read_text()
            relative = path.relative_to(root)

            for line_number, line in enumerate(text.split("\n"), start=1):
                for literal in LITERAL.findall(line):
                    if needs_translation(literal):
                        unwrapped.append(f"{relative}:{line_number}: {literal}")

            for key in CALL.findall(text):
                used.setdefault(key, str(relative))

        # Keys are written in the source with Swift escapes and stored in the
        # catalogue the same way, so they compare directly.
        missing = sorted(key for key in used if key not in keys)

        if unwrapped:
            status = 1
            print(f"  \033[31m✗\033[0m {app.name}: user-facing text not wrapped in L(...), "
                  "so it can never be translated:")
            for entry in unwrapped:
                print(f"      {entry}")

        if missing:
            status = 1
            print(f"  \033[31m✗\033[0m {app.name}: wrapped in L(...) but missing from Strings.swift:")
            for key in missing:
                print(f"      {used[key]}: {key}")

        if not unwrapped and not missing:
            print(f"  \033[32m✓\033[0m {app.name}: {len(used)} strings, all translated")

    return status


if __name__ == "__main__":
    sys.exit(main())
