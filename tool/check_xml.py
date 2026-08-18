#!/usr/bin/env python3
"""Fails if any XML in the package is malformed, or holds `--` inside a comment.

Both of these break the *consumer's* Android build rather than anything here: a plugin
manifest that does not parse fails `:nfc_util:processDebugManifest` in every app that depends
on the package, with an error naming a file the app author has never opened.

`--` inside a comment is the trap worth a dedicated check. It is illegal in XML but legal
everywhere else in this codebase, which spells em-dashes exactly that way in Kotlin, Dart and
Markdown -- so it arrives by habit, and no other layer looks at these files.
"""

import io
import re
import subprocess
import sys
import xml.dom.minidom

EXTRA = [
    "android/src/main/AndroidManifest.xml",
    "example/android/app/src/main/AndroidManifest.xml",
]

tracked = subprocess.run(
    ["git", "ls-files", "*.xml"], capture_output=True, text=True, check=False
).stdout.split()

problems = []
for path in sorted(set(tracked) | set(EXTRA)):
    try:
        source = io.open(path, encoding="utf-8").read()
    except OSError:
        continue

    try:
        xml.dom.minidom.parseString(source)
    except Exception as error:  # noqa: BLE001 - any parse failure is the same verdict
        problems.append(f"{path}: {error}")
        continue

    for match in re.finditer(r"<!--(.*?)-->", source, re.S):
        if "--" in match.group(1):
            line = source[: match.start()].count("\n") + 1
            problems.append(f'{path}:{line}: "--" inside an XML comment; use a comma or "..."')

if problems:
    print("\n".join(problems), file=sys.stderr)
    sys.exit(1)

print(f"{len(set(tracked) | set(EXTRA))} XML files parse, and no comment holds `--`.")
