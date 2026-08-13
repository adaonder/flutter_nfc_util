#!/usr/bin/env bash
# Runs every test layer this package has, and reports which ones failed.
#
# There are five, and three of them only resolve from a directory that is not the package
# root, which is the whole reason this script exists:
#
#   Dart unit        flutter test                      (root)
#   Widget           flutter test                      (example/)
#   Kotlin           ./gradlew :nfc_util:test          (example/android/ -- see below)
#   Swift            xcodebuild ... -only-testing:RunnerTests  (example/ios/, macOS only)
#   Integration      flutter test integration_test     (example/, needs a real phone)
#
# By default it runs what CI runs: the format check, both analyzers, both Dart suites and
# the Kotlin tests. Swift and the on-device suite are opt-in, because one needs macOS with
# Xcode and the other needs a phone with NFC.
#
# Unlike tool/generate_pigeon.sh this does NOT use `set -e`: a test runner that stops at the
# first failure hides the other four layers. Every step runs, and the exit code is non-zero
# if any of them failed.
set -uo pipefail

cd "$(dirname "$0")/.."

usage() {
    cat <<'EOF'
Usage: tool/test_all.sh [options]

  (no options)      format + analyze + Dart suites + Kotlin  -- what CI runs
  --dart            only the Dart layers; skips Kotlin. The fast inner loop.
  --swift           also run the Swift RunnerTests (macOS with Xcode only)
  --device <id>     also run the on-device integration tests on that device
                    (`flutter devices` lists the ids; the device needs NFC)
  --all             everything except the on-device suite, which needs --device
  -h, --help        this

Environment:
  NFC_UTIL_SIM      simulator UDID for the Swift tests; otherwise the first
                    available iPhone is used
EOF
}

run_kotlin=1
run_swift=0
run_dart=1
device=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dart) run_kotlin=0; run_swift=0; shift ;;
        --swift) run_swift=1; shift ;;
        --all) run_kotlin=1; run_swift=1; shift ;;
        --device)
            [[ $# -ge 2 ]] || { echo "--device needs a device id" >&2; exit 2; }
            device="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

failed=()
passed=()

# Runs a labelled step, letting its output through so a failure can be read where it
# happened, and remembers the verdict for the summary.
step() {
    local label="$1"; shift
    printf '\n\033[1m── %s\033[0m\n' "$label"
    if "$@"; then
        passed+=("$label")
    else
        failed+=("$label")
        printf '\033[31m✗ %s failed\033[0m\n' "$label"
    fi
}

in_dir() {
    local dir="$1"; shift
    (cd "$dir" && "$@")
}

# ---------------------------------------------------------------------------------------
# Dart
# ---------------------------------------------------------------------------------------

if [[ $run_dart -eq 1 ]]; then
    # No --line-length: the width comes from the `formatter:` block in analysis_options.yaml,
    # which is also what pana reads when it scores the package on pub.dev.
    step "dart format" dart format --output=none --set-exit-if-changed .
    step "flutter analyze" flutter analyze
    step "flutter analyze (example)" in_dir example flutter analyze --no-pub
    step "flutter test" flutter test
    step "flutter test (example)" in_dir example flutter test
fi

# ---------------------------------------------------------------------------------------
# Kotlin
# ---------------------------------------------------------------------------------------

if [[ $run_kotlin -eq 1 ]]; then
    # android/settings.gradle declares no `include`, so the plugin's own Gradle project
    # cannot resolve :nfc_util on its own. The example pulls it in through
    # dev.flutter.flutter-plugin-loader, which needs flutter.sdk in local.properties --
    # `--config-only` writes that file without building an APK.
    if [[ ! -f example/android/local.properties ]]; then
        step "flutter build apk --config-only" in_dir example flutter build apk --config-only
    fi
    step "kotlin unit tests" in_dir example/android ./gradlew :nfc_util:test --console=plain
fi

# ---------------------------------------------------------------------------------------
# Swift
# ---------------------------------------------------------------------------------------

if [[ $run_swift -eq 1 ]]; then
    if [[ "$(uname)" != "Darwin" ]]; then
        echo "--swift needs macOS with Xcode; skipping" >&2
        failed+=("swift tests (not macOS)")
    else
        sim="${NFC_UTIL_SIM:-}"
        if [[ -z "$sim" ]]; then
            sim=$(xcrun simctl list devices available \
                | grep -E '^ +iPhone' \
                | head -1 \
                | sed -E 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/')
        fi

        if [[ -z "$sim" ]]; then
            echo "no iPhone simulator available; set NFC_UTIL_SIM to a UDID" >&2
            failed+=("swift tests (no simulator)")
        else
            # This build is not optional. Run xcodebuild without it and the Flutter tool has
            # not yet regenerated FlutterGeneratedPluginSwiftPackage, so it comes out
            # declaring iOS 13.0 while the plugin requires 15.6, and the build fails with
            # "requires minimum platform version 15.6" before a single test runs.
            step "flutter build ios (prepares the SwiftPM package)" \
                in_dir example flutter build ios --simulator --no-codesign
            step "swift tests" in_dir example/ios xcodebuild test \
                -workspace Runner.xcworkspace \
                -scheme Runner \
                -destination "id=$sim" \
                -only-testing:RunnerTests
        fi
    fi
fi

# ---------------------------------------------------------------------------------------
# On device
# ---------------------------------------------------------------------------------------

if [[ -n "$device" ]]; then
    # Deliberately tag-free: these check availability, the session guards and the adapter
    # state, none of which need something held to the phone.
    step "integration tests on $device" in_dir example flutter test integration_test -d "$device"
fi

# ---------------------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------------------

printf '\n\033[1m── summary\033[0m\n'
for label in "${passed[@]:-}"; do
    [[ -n "$label" ]] && printf '  \033[32m✓\033[0m %s\n' "$label"
done

if [[ ${#failed[@]} -eq 0 ]]; then
    printf '\n\033[32mAll %d steps passed.\033[0m\n' "${#passed[@]}"
    exit 0
fi

for label in "${failed[@]}"; do
    printf '  \033[31m✗\033[0m %s\n' "$label"
done
printf '\n\033[31m%d of %d steps failed.\033[0m\n' "${#failed[@]}" "$(( ${#failed[@]} + ${#passed[@]} ))"
exit 1
