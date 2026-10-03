# MX Ergo Controller

A small personal macOS menu-bar app for one Logitech MX Ergo trackball.

It remaps the thumb buttons, wheel tilt, and wheel click, and provides explicitly
enabled Precision tap-to-mute and hold-and-scroll volume over Bluetooth LE.
Start with the [everyday-use guide](USER-GUIDE.md). Personal-v1 acceptance is
still in progress; see [release readiness](RELEASE-CHECKLIST.md).

Because a wrong write can leave the trackball in a state its vendor software
will not repair, the project treats every device write as hazardous. Capabilities
are built as productless SwiftPM targets that cannot link into a shipping binary,
proved with tests, and promoted only behind an explicit review. Read
[SAFETY.md](SAFETY.md) before changing anything.

## Where things stand

The September 28 source adds an orderly active-Precision sleep rollover. Before
sleep it closes the old HID endpoint without restoring or rewriting the button;
after wake it creates a fresh endpoint and performs GET-only resume. The wake
credential is one-use, bound to the exact unchanged active journal and sleep
cycle, and cannot authorize a SET. Hardware acceptance of the new wake path is
pending.

The September 11 automatic-start candidate adds **Start Precision automatically**.
It remembers a device-bound opt-in and checks each new launch before resuming
audio or activating a verified clean baseline. One bounded flow handles completed
session archival and a fresh observer; ambiguous states remain blocked. The
setting defaults off and hardware restart acceptance remains pending. See
[restart development](RESTART-DEVELOPMENT.md).

The earlier restart-validation source added **Resume previous Precision
session**. It sequences fresh checks and performs GET-only resumption through
the existing owner facade; it cannot fall back to an activate or restore SET.
A device returning to baseline is recorded and left inactive. Hardware acceptance
of the new notification connection is pending. The persistent preference and
restart decision policy are implemented as non-authorizing package types; that earlier candidate did not enable
unattended Precision startup. See [restart development](RESTART-DEVELOPMENT.md).

The previous September 9 volume-feedback candidate (`b0bdf27`) includes guarded
lifecycle handling, fresh endpoint identity verification, Controls/Advanced,
guided Precision preparation, session cleanup, quiet routine-login presentation,
and a volume/mute popup. All 521 tests and signed-build checks passed. Both Off
and On preferences survived normal app restarts in September 10 UI checks.
The user confirmed the volume/mute popups work on September 10, and two
completed sessions retain verified activation/restoration evidence. Login/reboot,
coexistence, and sustained-use acceptance remain open. Use
[the current acceptance checklist](ACCEPTANCE.md); detailed outcomes
and their build identities are in [the validation history](Evidence/VALIDATION-RECORDS.md).

The dated hardware results below are historical evidence for their named builds.

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

**Working, proved on hardware 2026-09-04:** Precision tap-to-mute, hold+scroll
volume, and the scroll swallow. The press notification carries CID `00ED`, and
decoding, intent resolution and execution all function. The app requires
**Accessibility** as well as Input Monitoring: the scroll swallow uses a
suppressing `CGEvent` tap, which Input Monitoring alone does not permit.

**Answered 2026-09-04: no mapped control needs HID++ diversion.** Every one of
the five is already delivered to macOS as an ordinary mouse button or scroll
axis — both thumb buttons as HID buttons `0x08` and `0x10`, both wheel tilts as
horizontal scroll, wheel click as middle click. Only the Precision button
produces no ordinary report, which is why it required diversion and why that
runtime was worth building.

Replacing BetterTouchTool for the other five is therefore an event-layer
problem — observe, suppress, post replacements — with **no device write at
all**. See [Evidence/VALIDATION-RECORDS.md](Evidence/VALIDATION-RECORDS.md).

**Working, proved on hardware 2026-09-05:** the event layer, which replaces
BetterTouchTool for all five remaining controls with **no device write at all**.
Wheel click opens Mission Control, both thumbs switch Spaces, and both wheel
tilts navigate back and forward.

`MXErgoEventSynthesis` decides — a pure value policy with no CoreGraphics import
at all — and `MXErgoEventTap` acts, holding the project's only `CGEvent.post`
call site. Both remain productless and `package`-only; the app reaches them
through the `MXErgoEventLayer` facade, whose public surface is a pinned list.

A toggle in the menu turns it on, and since 2026-09-05 that switch is
remembered, so the trackball works before anyone opens the menu. A remembered
"on" still requires Accessibility and says so plainly rather than failing
quietly if the grant has gone — and arms itself once the grant returns, without
a relaunch. A remembered "off" is never overridden by anything.

The escape hatch is structural rather than promised: the tap's event mask
excludes the primary and secondary buttons, so an ordinary click can never be
swallowed and the menu always stays reachable. Stopping the layer restores
everything at once — there is no inverse command to send.

**Launch at login** is a separate toggle. It reports what macOS currently
believes rather than what the app last asked for, because registration can
succeed and still sit in `requiresApproval`, where the app is listed in Login
Items and silently never starts until a person approves it.

Three findings from making it work, each recorded in
[Evidence/VALIDATION-RECORDS.md](Evidence/VALIDATION-RECORDS.md):

- A synthetic arrow key must carry the numeric-pad and secondary-function flags
  a real one does, or the window server's hotkey matcher ignores it. This broke
  all three chords at once.
- The horizontal scroll sign is not a property of the trackball. It inverts with
  the "natural scrolling" preference, so it is derived from that rather than
  compiled in.
- BetterTouchTool's back and forward were a three-finger swipe, which every
  application honours and macOS cannot synthesize. The substitution is the
  back/forward mouse buttons, plus Command+Arrow for Safari and Finder, which
  ignore them.

**Reviewed but deliberately unauthorized:** the five BetterTouchTool-mapped CIDs
(`0052`, `0053`, `0056`, `005B`, `005D`). Their diversion plan, readiness audit,
action plan, event pump and live GET-only preflight all exist and all return
`notAuthorizedForExecution`. No mapped-control HID++ SET is sent. Ordinary
button remapping uses the separately promoted event layer described above.

Audio execution is disabled after every launch and must be explicitly enabled.

## Documentation

| File | What it holds |
|---|---|
| [USER-GUIDE.md](USER-GUIDE.md) | Everyday controls, Precision audio, finishing a session, and troubleshooting |
| [RELEASE-CHECKLIST.md](RELEASE-CHECKLIST.md) | Exact installed candidate, completed/pending gates, and update/rollback boundaries |
| [SAFETY.md](SAFETY.md) | The eleven invariants, and the questions to ask before changing anything |
| [RUNBOOK.md](RUNBOOK.md) | The ordered hardware-validation steps |
| [ACCEPTANCE.md](ACCEPTANCE.md) | Current installed-build, login, ordinary-control, and guided Precision checks |
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
- `Packages/MXErgoKit/Sources/MXErgoPrecisionIOHIDOutput/` — productless bridge containing the Precision runtime's sole SetReport call; its fileprivate real-device constructor is reached through the guarded runtime composition behind the owner facade
- `Packages/MXErgoKit/Sources/MXErgoPrecisionIOHIDOwnership/` — productless, IOKit-free admission, full-bundle quarantine, and explicit post-quiescence resource-release contract
- `Packages/MXErgoKit/Sources/MXErgoPrecisionIOHIDAssembly/` — productless same-handle composition root for the input, output, and ownership factories; used internally by the runtime with no direct app entry point
- `Packages/MXErgoKit/Sources/MXErgoPrecisionIOHIDAcquisition/` — productless independent-manager enumeration and direct-open owner; one validated device is closed by the quarantined release anchor
- `Packages/MXErgoKit/Sources/MXErgoPrecisionRuntimeJournal/` — productless package-only schema-v3 create-or-reuse bootstrap and canonical durable repository/snapshot source
- `Packages/MXErgoKit/Sources/MXErgoPrecisionRuntimeComposition/` — productless package-only owner that composes acquisition, transport, coordinator, and lifecycle with preflight validation and ordered shutdown
- `Packages/MXErgoKit/Sources/MXErgoPrecisionRuntimeAdmission/` — productless package-only explicit-authorization, observer-handoff, canonical-lease, state-policy, and shutdown supervisor
- `Packages/MXErgoKit/Sources/MXErgoPrecisionRuntimeHostHandoff/` — productless, IOKit-free exact-run observer drain adapter with mandatory post-stop session and Root evidence reread
- `Packages/MXErgoKit/Sources/MXErgoPrecisionRuntimeLifecycle/` — productless owner that binds one observer run into authorization and holds the restart fence through shutdown and rollover
- `Packages/MXErgoKit/Sources/MXErgoEventLayer/` — public executable façade for the event layer: start, stop, the reviewed bindings, and read-only counters; it exposes no tap, poster, or policy, and its public API list is pinned by a test
- `Packages/MXErgoKit/Sources/MXErgoEventSynthesis/` — productless, CoreGraphics-free BetterTouchTool-replacement policy; it decides what to suppress and what to inject, and structurally cannot cause an event to exist
- `Packages/MXErgoKit/Sources/MXErgoEventTap/` — productless CGEvent seam holding the sole `CGEvent.post` call site; refuses to start without Accessibility and fails open on every error path
- `Packages/MXErgoKit/Sources/MXErgoPrecisionRuntimeOwner/` — public executable facade for binding, explicitly confirmed admission/recovery/deactivation, quit, and session rollover; it keeps raw device output behind the guarded runtime
- `Packages/MXErgoKit/Tests/` — unit and boundary tests, including observer handoff/drain races, admission authorization, composition validation, acquisition failure cleanup, source-assembly rollback, teardown, cancellation, abandonment, and build-graph isolation

For daily use the app lives in `/Applications`, built Release:

```bash
xcodebuild -project MXErgoController.xcodeproj -scheme MXErgoController \
    -configuration Release -derivedDataPath DerivedData build
cp -R "DerivedData/Build/Products/Release/MX Ergo Controller.app" /Applications/
```

Both permissions are keyed to the app's location, so a copy in `/Applications`
needs Accessibility and Input Monitoring granted separately from any build run
out of DerivedData. Launch at login also wants a stable location: registering
from a temporary path reports `notFound`.

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
