---
name: verify
description: Run the MX Ergo project's full verification chain and interpret its failures. Use when running tests or builds in this repo, when asked whether the suite passes, or when a build-graph isolation test, forensic evidence audit, or codesign check fails in a way that looks baffling.
---

# Verify

```bash
scripts/verify.sh              # tests + all four signed builds + signature audit
scripts/verify.sh --tests-only # faster loop
```

Always prefer this to a bare `swift test`. Running the stages out of order
produces failures that look like real bugs but are not.

## What it does and why the order matters

1. **`xcodegen generate`** — twelve build-graph isolation tests read
   `MXErgoController.xcodeproj/project.pbxproj` as evidence that dormant targets
   are absent from the shipping app. Without this they throw.
2. **Builds `MXErgoTransactionCrashHarness`** and exports
   `MX_ERGO_CRASH_HARNESS_PATH`. Two subprocess durability tests skip without it.
3. **Runs the suite** and warns if anything was skipped.
4. **Builds all four signed targets**, then checks bundle identifier, Team ID
   `XW848M73T3`, hardened runtime, and the designated requirement.
5. **Audits `App/` sources** for `PrecisionRuntimeAdmissionFactory`,
   `IOHIDDeviceSetReport` and `recoverExplicitly()`.

Expected: **344 tests, 0 skipped.**

## Interpreting failures

### An isolation test fails after you added a dependency

Most likely the **pinned occurrence count**, not a real leak. Several tests
assert a target name appears in `Package.swift` an exact number of times:

| Target | Expected occurrences |
|---|---|
| `MXErgoPrecisionRuntimeAdmission` | 8 |
| `MXErgoPrecisionRuntimeComposition` | 7 |
| `MXErgoPrecisionIOHIDOwnership` | 7 |
| `MXErgoPrecisionRuntimeJournal` | 6 |
| `MXErgoPrecisionIOHIDAcquisition` | 4 |
| `MXErgoPrecisionIOHIDAssembly` | 3 |
| `MXErgoPrecisionIOHIDOutput` | 3 |
| `MXErgoRestoreTrialIOHID` | 2 |

This friction is deliberate — it forces a human to notice the graph changed.
Update the number **only** after confirming the new edge is intended, and say so
in the commit.

### An isolation test fails mentioning `project.pbxproj`

Either `xcodegen generate` has not run, or a dormant target really was wired
into an app. Check `project.yml` first.

### The forensic evidence audit fails

It defaults to the tracked `Evidence/2026-08-30` fixtures. A failure means those
files changed — they never should. Restore them from git rather than repinning
the hashes. To audit the live journals instead:

```bash
MX_ERGO_FORENSIC_EVIDENCE_DIRECTORY="$HOME/Library/Application Support/com.phib.MXErgoController" \
  swift test --package-path Packages/MXErgoKit --filter Forensic
```

### `project.pbxproj changed` warning

`project.yml` was edited without committing the regenerated project. Review the
diff — this is exactly the signal that a target's wiring moved.

### Schemes look modified

They are gitignored. Xcode rewrites them on open and xcodegen rewrites them
back; that fight is why they are not tracked.

## Reporting results

Give the real number and say whether anything skipped. "The suite passes" is not
a useful claim in this repo — five tests used to pass while verifying nothing.
