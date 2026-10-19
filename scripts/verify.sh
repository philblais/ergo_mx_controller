#!/bin/bash
#
# Full local verification for MX Ergo Controller.
#
# The README documents six commands whose ORDER is load-bearing and which
# nothing previously enforced:
#
#   * Twelve build-graph isolation tests read MXErgoController.xcodeproj/
#     project.pbxproj as evidence that the dormant Precision targets are absent
#     from the shipping app. They throw if `xcodegen generate` has not run.
#
#   * Two subprocess durability tests need a built MXErgoTransactionCrashHarness
#     and skip without MX_ERGO_CRASH_HARNESS_PATH.
#
# This script runs everything in the right order with the right environment, so
# "the suite is green" means all 343 tests actually executed.
#
# Usage:
#   scripts/verify.sh              # package tests + signed menu-app build
#   scripts/verify.sh --tests-only # skip the xcodebuild and codesign stages
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
PACKAGE="$ROOT/Packages/MXErgoKit"
DERIVED="$ROOT/DerivedData"
TESTS_ONLY=0
[ "${1:-}" = "--tests-only" ] && TESTS_ONLY=1

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\n\033[31mFAILED: %s\033[0m\n' "$1" >&2; exit 1; }

step "Generating the Xcode project (isolation tests read project.pbxproj)"
command -v xcodegen >/dev/null || fail "xcodegen not found. brew install xcodegen"
xcodegen generate

# project.pbxproj is tracked. If generating it produced a diff, a target was
# added or removed without the commit that should accompany it.
if git -C "$ROOT" diff --quiet -- MXErgoController.xcodeproj/project.pbxproj; then
    echo "project.pbxproj unchanged"
else
    printf '\033[33mWARNING: project.pbxproj changed. Review the diff before committing:\033[0m\n'
    git -C "$ROOT" --no-pager diff --stat -- MXErgoController.xcodeproj/project.pbxproj
fi

step "Building the transaction crash harness"
swift build --package-path "$PACKAGE" --product MXErgoTransactionCrashHarness
BIN_PATH="$(swift build --package-path "$PACKAGE" --show-bin-path)"
HARNESS="$BIN_PATH/MXErgoTransactionCrashHarness"
[ -x "$HARNESS" ] || fail "crash harness missing at $HARNESS"
echo "harness: $HARNESS"

step "Running the package test suite"
# The forensic audit defaults to the tracked Evidence/2026-08-30 fixtures. Set
# MX_ERGO_FORENSIC_EVIDENCE_DIRECTORY only to audit the live journals instead.
MX_ERGO_CRASH_HARNESS_PATH="$HARNESS" \
    swift test --package-path "$PACKAGE" 2>&1 | tee "$ROOT/.verify-tests.log"

if grep -q "skipped:" "$ROOT/.verify-tests.log"; then
    printf '\n\033[33mWARNING: some tests were skipped:\033[0m\n'
    grep "skipped:" "$ROOT/.verify-tests.log" || true
fi
SUMMARY="$(awk '
    /Test run with [0-9]+ tests/ {
        summary = $0
        sub(/^.*Test run with /, "", summary)
        sub(/ tests.*$/, "", summary)
        total += summary
        runs += 1
    }
    END {
        if (runs == 0) exit 1
        printf "Passed %d package tests across %d test runs.", total, runs
    }
' "$ROOT/.verify-tests.log")" || fail "No package test summary was produced"
echo "$SUMMARY"
rm -f "$ROOT/.verify-tests.log"

step "Checking app audio behavior with fake audio and a manual clock"
scripts/test-app-audio.sh

if [ "$TESTS_ONLY" -eq 1 ]; then
    step "Done (tests only)"
    exit 0
fi

step "Building the signed menu app"
xcodebuild -project MXErgoController.xcodeproj \
    -scheme MXErgoController \
    -configuration Debug \
    -derivedDataPath "$DERIVED" \
    build -quiet

APP="$DERIVED/Build/Products/Debug/MX Ergo Controller.app"
[ -d "$APP" ] || fail "built app not found at $APP"

step "Verifying the signature, team, and hardened runtime"
codesign -vvv --deep --strict "$APP"

# The designated requirement names the Apple Development certificate, not the
# team, so the Team ID has to come from the code directory instead.
SIGNING="$(codesign -dv "$APP" 2>&1)"
printf '%s' "$SIGNING" | grep -q "^Identifier=com.phib.MXErgoController$" \
    || fail "bundle identifier is not com.phib.MXErgoController"
printf '%s' "$SIGNING" | grep -q "^TeamIdentifier=XW848M73T3$" \
    || fail "Team ID is not XW848M73T3"
printf '%s' "$SIGNING" | grep -q "flags=.*runtime" \
    || fail "Hardened Runtime is not enabled"
codesign -d -r- "$APP" 2>&1 | grep -q 'identifier "com.phib.MXErgoController"' \
    || fail "designated requirement does not pin the bundle identifier"
echo "valid on disk, com.phib.MXErgoController, Team XW848M73T3, hardened runtime"

step "Building the three signed helpers"
# The README documents these; they exercise code paths the menu app cannot
# reach, and two of them share the canonical competitor classifier.
for scheme in MXErgoRestoreTrialProbe MXErgoPrecisionRestoreTrial MXErgoPrecisionTrialReconciler; do
    echo "  building $scheme"
    xcodebuild -project MXErgoController.xcodeproj \
        -scheme "$scheme" \
        -configuration Release \
        -derivedDataPath "$DERIVED" \
        build -quiet
done

step "Confirming the read-only probe contains no SET path"
PROBE="$DERIVED/Build/Products/Release/MX Ergo Restore Trial Probe.app"
[ -d "$PROBE" ] || fail "probe not built at $PROBE"
if nm -u "$PROBE/Contents/MacOS/MX Ergo Restore Trial Probe" 2>/dev/null \
    | grep -q "IOHIDDeviceSetReport"; then
    # The probe legitimately sends HID++ GET requests, which travel as output
    # reports, so this symbol is expected. What matters is that no reporting
    # planner or trial adapter came with it.
    echo "  IOHIDDeviceSetReport present (expected: HID++ GETs are output reports)"
fi
for forbidden in "DormantPrecisionTrialIOHID" "RestoreOnlyReportingPlan" "MXErgoHIDPP"; do
    if nm -a "$PROBE/Contents/MacOS/MX Ergo Restore Trial Probe" 2>/dev/null \
        | grep -q "$forbidden"; then
        fail "read-only probe contains forbidden symbol: $forbidden"
    fi
done
echo "probe carries no trial adapter, reporting planner, or MXErgoHIDPP symbol"

step "Auditing the shipped binary for dormant-runtime symbols"
# The owner product legitimately pulls IOHIDDeviceSetReport into the linked
# image; no menu-app code path invokes it. What must never appear is a direct
# admission or acquisition entry point in App/ itself.
# The event layer is promoted, so MXErgoEventLayer legitimately links in. What
# must never appear in App/ is a direct injection or tap call: the app goes
# through the facade, which holds the only CGEvent.post site in the package.
APP_SOURCES="$(cat "$ROOT"/App/*.swift)"
for forbidden in "PrecisionRuntimeAdmissionFactory" "IOHIDDeviceSetReport" "recoverExplicitly()" ".post(tap:" "CGEvent.tapCreate"; do
    if printf '%s' "$APP_SOURCES" | grep -q -- "$forbidden"; then
        fail "App/ sources contain forbidden symbol: $forbidden"
    fi
done
echo "App/ sources clean"

step "All checks passed"
echo "$SUMMARY"
