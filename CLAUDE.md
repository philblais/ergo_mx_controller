# CLAUDE.md

Working notes for agents in this repository. Read [SAFETY.md](SAFETY.md) before
changing anything that could reach the trackball.

## What this is

A macOS menu-bar app that speaks HID++ 2.0 to one Logitech MX Ergo over BLE.
Swift 6, SwiftPM package (`Packages/MXErgoKit`, 20 targets) plus an XcodeGen
project (`project.yml`, 4 app targets). Tests are `swift-testing`, not XCTest.

## Verify

```bash
scripts/verify.sh
```

Always use this rather than a bare `swift test`. The order is load-bearing:
twelve isolation tests read the generated `project.pbxproj`, and two subprocess
tests skip silently without `MX_ERGO_CRASH_HARNESS_PATH`. Use
`scripts/verify.sh --tests-only` for a faster loop.

## The rules that are not negotiable

These are expanded in [SAFETY.md](SAFETY.md). The short form:

1. **Productless targets stay productless.** Fourteen of twenty package targets
   deliberately have no library product and no app/helper dependency edge.
   Adding one is a review, not a commit.
2. **One `IOHIDDeviceSetReport` call site** for the Precision runtime, in
   `MXErgoPrecisionIOHIDOutput`. Never add a second.
3. **A SET acknowledgement is never proof.** Only a separate `GetCidReporting`
   establishes device state.
4. **Never write a retry, and never write an inverse command.** Once a SET may
   have been dispatched, ambiguity is persisted and the operation stops.
5. **Never rewrite `device-state-journal.json`.** It is the recovery ground
   truth and its bytes are pinned by tests.
6. **Review is not permission.** `notAuthorizedForExecution` means a review
   happened; execution needs a separate one-use authorization.

If a change touches any of these, say so explicitly rather than burying it.

## Conventions

- **Milestone cadence.** Build in a productless target → add its isolation test
  → run `scripts/verify.sh` → append a `CHANGELOG.md` entry in house style,
  stating the new test count and whether any live HID operation ran.
- **Naming.** Types are spelled out, not abbreviated. Error enums are per-module
  and specific. Comments explain *why a constraint exists*, not what the line does.
- **Tests.** `@Test func` at top level, no `@Suite`. Prefer injected fakes over
  conditional compilation. Adversarial cases (forged authorization, duplicate
  invocation, cancellation on both sides of a boundary) are the point.
- **Generated files.** `project.pbxproj` is tracked because the isolation tests
  read it as evidence; `xcshareddata/xcschemes/` is ignored because Xcode and
  xcodegen fight over it. Run `xcodegen generate` after editing `project.yml`.

## Hardware

Physical sessions need the user. Never claim a hardware result that did not
happen — the `Evidence/` directory and `Evidence/VALIDATION-RECORDS.md` are an
audit trail, not a place for expected outcomes. Follow [RUNBOOK.md](RUNBOOK.md).

The Precision runtime has never run against the trackball. Until it has, treat
everything downstream of it as unvalidated.

## Skills

Project skills live in `.claude/skills/`:

| Skill | Use it when |
|---|---|
| `safety-gate` | Before any change that could reach hardware |
| `verify` | Running the suite, or diagnosing a confusing isolation-test failure |
| `hardware-session` | Preparing or recording a physical trackball session |
| `milestone` | Closing out a unit of work and writing its changelog entry |
