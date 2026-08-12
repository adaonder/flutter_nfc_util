#!/usr/bin/env bash
# Regenerates the platform channel bindings from pigeon/messages.dart.
#
# The generated files are checked in, so CI does not need to run this -- but it does need
# the output to be current. Run this after any edit to the schema and commit the result.
set -euo pipefail

cd "$(dirname "$0")/.."

dart run pigeon --input pigeon/messages.dart

# Pigeon's own output is not dart-format-clean at this package's width. Normalising it here
# keeps a regeneration diff to the lines that actually changed instead of a whole-file
# reflow. Nothing enforces the width -- it is a convention shared with the hand-written
# sources.
dart format --line-length 120 lib/src/pigeon.g.dart

echo "Generated:"
echo "  lib/src/pigeon.g.dart"
echo "  android/src/main/kotlin/com/onderada/nfc_util/Pigeon.g.kt"
echo "  ios/nfc_util/Sources/nfc_util/Pigeon.g.swift"
