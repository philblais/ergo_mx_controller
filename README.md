# MX Ergo Controller

A small personal macOS menu-bar app for one Logitech MX Ergo trackball.

It speaks HID++ 2.0 to the device over Bluetooth LE, with the long-term goal of
taking over the thumb buttons, wheel tilt, wheel click and Precision button so
BetterTouchTool can be retired.

Because a wrong write can leave the trackball in a state its vendor software
will not repair, the project treats every device write as hazardous. Capabilities
are built as productless SwiftPM targets that cannot link into a shipping binary,
proved with tests, and promoted only behind an explicit review. Read
[SAFETY.md](SAFETY.md) before changing anything.

## Where things stand

**Working, and proved on hardware:** device matching and observation, bounded
read-only HID++ discovery (Root, Device Information, control enumeration,
reporting snapshot), the durable schema-v2 recovery baseline, and one authorized
single-control restore trial that was reconciled clean.

**Proved on hardware 2026-09-04:** the full Precision temporary-diversion
runtime — acquisition, assembly, ownership, composition, admission, observer
host-handoff, lifecycle and the public owner facade. One apply SET verified by an
independent GET, one restore SET verified back to the exact baseline, both
`verified`, schema-v2 baseline untouched. The MX Ergo does not echo
`SetCidReporting`, which is precisely why an acknowledgement is treated as
evidence and only a GET as proof. See
[Evidence/VALIDATION-RECORDS.md](Evidence/VALIDATION-RECORDS.md).

**Tried and does not work:** Precision tap-to-mute and hold+scroll volume. With
Precision verified diverted (`flags 01`) and audio execution enabled, tapping did
not mute and hold+scroll did not change volume — the page underneath scrolled
normally, so the scroll swallow never engaged either. No diverted control
notification reaches the intent path. The cause is still undetermined, but the
runtime can now report it: input diagnostics show how many frames arrived, how
many were routed as notifications, and the last frame's bytes. One short
hardware session should settle it.

**Reviewed but deliberately unauthorized:** the five BetterTouchTool-mapped CIDs
(`0052`, `0053`, `0056`, `005B`, `005D`). Their diversion plan, readiness audit,
action plan, event pump and live GET-only preflight all exist and all return
`notAuthorizedForExecution`. No mapped SET is sent and no synthetic event is
posted — there is no `CGEvent` posting anywhere in the project yet.

Audio execution is disabled after every launch and must be explicitly enabled.

## Documentation

| File | What it holds |
|---|---|
| [SAFETY.md](SAFETY.md) | The ten invariants, and the questions to ask before changing anything |
| [RUNBOOK.md](RUNBOOK.md) | The ordered hardware-validation steps |
| [CHANGELOG.md](CHANGELOG.md) | The full capability ledger and milestone history |
| [Evidence/VALIDATION-RECORDS.md](Evidence/VALIDATION-RECORDS.md) | What the physical trackball actually did |
| [Evidence/2026-08-30/](Evidence/2026-08-30/) | Preserved durable journals, pinned by SHA-256 |

## Structure

- `App/` — SwiftUI menu-bar interface and main-actor presentation model
- `HelperProbe/` — standalone, short-lived read-only helper with a closed GET-only operation set and no package dependency
- `HelperTrial/` — separately signed, argument-gated one-control restore helper; not linked into the menu app or read-only probe
- `Packages/MXErgoKit/Sources/MXErgoCore/` — hardware-independent models and bounded diagnostics
- `Packages/MXErgoKit/Sources/MXErgoHIDPP/` — pure HID++ packet, single-flight correlation, and recovery-journal logic; no IOKit imports
- `Packages/MXErgoKit/Sources/MXErgoHID/` — IOHID matching and observation on its own run loop, with run-scoped request draining and package-only handoff receipts
- `Packages/MXErgoKit/Sources/MXErgoRestoreTrialIOHID/` — unexported, test-only Precision trial IOHID boundary; deliberately absent from the app graph
- `Packages/MXErgoKit/Sources/MXErgoPrecisionTransport/` — unexported Precision lifecycle adapter and bounded request-scoped callback inbox with injected report I/O, no IOKit linkage, and no concrete writer
- `Packages/MXErgoKit/Sources/MXErgoPrecisionIOHIDInput/` — productless callback owner for one already-open device; exposed across modules only as a narrow input-lifetime factory
- `Packages/MXErgoKit/Sources/MXErgoPrecisionWriteLifecycle/` — unexported, IOKit-free lifecycle for a mandatory injected blocking call; exact three-packet allowlist, prompt logical cancellation, and explicit physical drain
- `Packages/MXErgoKit/Sources/MXErgoPrecisionIOHIDOutput/` — productless bridge containing the sole new SetReport call; its real-device constructor is fileprivate and its narrow factory is absent from runnable graphs
- `Packages/MXErgoKit/Sources/MXErgoPrecisionIOHIDOwnership/` — productless, IOKit-free admission, full-bundle quarantine, and explicit post-quiescence resource-release contract
- `Packages/MXErgoKit/Sources/MXErgoPrecisionIOHIDAssembly/` — productless same-handle composition root for the input, output, and ownership factories; no discovery, open/close, product, or runnable dependency edge
- `Packages/MXErgoKit/Sources/MXErgoPrecisionIOHIDAcquisition/` — productless independent-manager enumeration and direct-open owner; one validated device is closed by the quarantined release anchor
- `Packages/MXErgoKit/Sources/MXErgoPrecisionRuntimeJournal/` — productless package-only schema-v3 create-or-reuse bootstrap and canonical durable repository/snapshot source
- `Packages/MXErgoKit/Sources/MXErgoPrecisionRuntimeComposition/` — productless package-only owner that composes acquisition, transport, coordinator, and lifecycle with preflight validation and ordered shutdown
- `Packages/MXErgoKit/Sources/MXErgoPrecisionRuntimeAdmission/` — productless package-only explicit-authorization, observer-handoff, canonical-lease, state-policy, and shutdown supervisor
- `Packages/MXErgoKit/Sources/MXErgoPrecisionRuntimeHostHandoff/` — productless, IOKit-free exact-run observer drain adapter with mandatory post-stop session and Root evidence reread
- `Packages/MXErgoKit/Sources/MXErgoPrecisionRuntimeLifecycle/` — productless owner that binds one observer run into authorization and holds the restart fence through shutdown and rollover
- `Packages/MXErgoKit/Sources/MXErgoPrecisionRuntimeOwner/` — public executable façade for bind, quit, and session rollover; it does not expose admit or a SET sender
- `Packages/MXErgoKit/Tests/` — unit and boundary tests, including observer handoff/drain races, admission authorization, composition validation, acquisition failure cleanup, source-assembly rollback, teardown, cancellation, abandonment, and build-graph isolation

The stable bundle identifier is `com.phib.MXErgoController`, and local development builds use Personal Team `XW848M73T3`. App Sandbox is disabled because direct HID observation is required; Hardened Runtime remains enabled.

## Generate, build, and test

```sh
scripts/verify.sh
```

That is the supported path. It runs the commands below in order — the order is
load-bearing, because twelve build-graph isolation tests read the generated
`project.pbxproj`, and two subprocess durability tests need a built crash
harness and skip without it.

```sh
xcodegen generate
swift build --package-path Packages/MXErgoKit --product MXErgoTransactionCrashHarness
MX_ERGO_CRASH_HARNESS_PATH=<built path> swift test --package-path Packages/MXErgoKit
xcodebuild -project MXErgoController.xcodeproj -scheme MXErgoController -configuration Debug build
xcodebuild -project MXErgoController.xcodeproj -scheme MXErgoRestoreTrialProbe -configuration Release build
xcodebuild -project MXErgoController.xcodeproj -scheme MXErgoPrecisionRestoreTrial -configuration Release build
xcodebuild -project MXErgoController.xcodeproj -scheme MXErgoPrecisionTrialReconciler -configuration Release build
```

`scripts/verify.sh --tests-only` skips the xcodebuild and codesign stages.

The forensic evidence audit runs against the tracked `Evidence/2026-08-30`
fixtures by default. Set `MX_ERGO_FORENSIC_EVIDENCE_DIRECTORY` to audit the live
journals in `~/Library/Application Support/com.phib.MXErgoController` instead.

## Hardware validation

See [RUNBOOK.md](RUNBOOK.md). In short: quit BetterTouchTool and Logi Options
completely, power-cycle the trackball, record journal hashes before and after,
and never retry an ambiguous SET.
