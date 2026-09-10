# Safety invariants

This project writes to a physical input device over HID++ 2.0. A wrong write can
leave the trackball in a state its own vendor software will not repair, so the
design treats every device write as hazardous and irreversible.

These are the rules the code enforces. They were previously discoverable only by
reading the 640-line milestone history in [CHANGELOG.md](CHANGELOG.md), which
made them impossible to check against. Anything that violates one of these is a
bug regardless of what the tests say.

---

## 1. Dormant code cannot ship

A capability that can reach hardware is built as a SwiftPM target with **no
library product** and **no dependency edge from any app or helper**. It is
compiled and tested, but the linker cannot pull it into a signed binary.

Fifteen of the twenty-one package targets are productless. Promotion out of
that state is a separate, explicit review — never a side effect of adding a
feature. It has happened once, to the event layer on 2026-09-05, and it took
the shape a promotion should: the two targets that do the work stayed
productless and `package`-only, and a new `MXErgoEventLayer` facade with a
pinned public API list became the single thing the app may name.

Sixteen build-graph isolation tests enforce this by reading `Package.swift`,
`project.yml` and the generated `project.pbxproj` as evidence. They assert the
target name is absent from the products half of the manifest, that its manifest
occurrence count is exactly as expected, and that it appears in neither the
XcodeGen input nor the generated project.

> The occurrence counts are pinned integers. Adding a legitimate dependency edge
> will fail them until the number is updated by hand. That is intentional
> friction: it forces a human to notice the graph changed.

> The products half must be split on a **line-anchored** `"\n    targets: ["`.
> Splitting on a bare `"targets: ["` truncates at the first *product's* own
> targets list, which left twelve of these checks scanning two lines of the
> manifest and passing vacuously until 2026-09-05.

`MXErgoRestoreTrialIOHID` is the one deliberate exception — `project.yml`
compiles its single source file directly into the trial helper. Its isolation
test therefore asserts something narrower: the file reaches exactly one Sources
phase, that phase is the trial helper's, and the menu app never compiles it.

## 2. One door for output

The Precision runtime has exactly **one** `IOHIDDeviceSetReport` call site, in
`MXErgoPrecisionIOHIDOutput`. Its real-device constructor is `fileprivate` and
reachable across modules only through one narrow package factory.

A test concatenates the Input, Output, Ownership and Assembly sources and
asserts the symbol occurs exactly once across all four. Never add a second call
site; route through the existing bridge.

The event layer has the matching rule for the other direction. There is exactly
**one** `CGEvent.post` call site, in `MXErgoEventTap`, so "what can this app
inject into my session" is answerable by reading one function. A test asserts it
occurs once across the whole `Sources` tree, and that only two suppressing
`CGEvent.tapCreate` sites exist: the Precision scroll swallow and the synthesis
tap.

## 3. An acknowledgement is evidence — a GET is proof

A SET response never establishes device state, no matter how well it correlates.

* A correlated non-echo reply is retained as `.correlatedNonEcho` diagnostic
  evidence and does not fail the attempt.
* Only a separate `GetCidReporting` returning the intended flags moves a control
  to `appliedVerified`.
* Only an exact full-baseline GET moves it to `restoredVerified`.

This is why the production runtime is safer than the 2026-08-30 trial helper,
which demanded an exact echo and consequently recorded `outcomeUnknown` for a
SET that had in fact behaved correctly.

## 4. Never retry, never invert

There is no automatic retry anywhere, and no automatic inverse command.

Once a SET may have crossed the writer boundary — the lock-linearized
`queued → entered` transition — timeout, cancellation, disconnect or a late
competitor **poisons the epoch**. The durable state records that ambiguity and
stops. It does not attempt to undo, re-send, or guess.

Recovering from ambiguity is a human decision, made with a GET-only probe and an
offline reconciler, exactly as on 2026-08-30. After an `outcomeUnknown` restore,
the Recover control locks and refuses a second restore SET.

## 5. Ambiguity is durable

Every uncertain outcome is persisted before it can be forgotten. Write-ahead
records are committed with revisioned compare-and-swap, `F_FULLFSYNC`, atomic
replacement, and a directory sync, then read back and compared byte-for-byte.

A failure proved to precede write-ahead may return a reservation to idle.
Anything whose durable visibility is uncertain terminally invalidates it and
requires a journal reload.

## 6. Journal bytes are sacred

The schema-v2 baseline (`device-state-journal.json`) is the recovery ground
truth and is **never rewritten** by any simulation, rehearsal or runtime.

Every reader that matters re-reads the file and compares exact bytes and hashes,
not decoded values. Readiness evidence is invalidated when those bytes change.
An original-byte backup is published durably before any metadata commit.

## 7. Exclusive access is checked twice and held throughout

Before touching the device, the code scans for competing software
(BetterTouchTool, Logi Options, other MX Ergo processes) **on both sides** of
acquiring the canonical device-operation lease, and requires both scans to be
empty and equal.

The lease is an OFD write lock (`F_OFD_SETLK`) on a sidecar file beside the
journal, plus an in-process registry — because OFD locks are per
file-description, so one process could otherwise lease itself twice. It is held
for the entire operation: discovery, arming, the SET boundary, verification, and
ordered shutdown.

`PrecisionCompetingProcessClassifier` is the single source of truth for what
counts as a competitor. Do not hand-roll another rule; three divergent copies
previously disagreed about whether it was safe to proceed.

AppKit's `ThemeWidgetControlViewService` appends its host app's name to its
display title. The classifier excludes that UI helper only when the native
snapshot has both its exact Apple bundle identifier and the exact executable
path under the system AppKit framework. Neither a helper name nor a claimed
Apple identifier alone grants an exception. Missing or mismatched executable
identity uses the ordinary competitor rules. All app/helper scanners supply
the native executable URL; real competing processes remain independently
classified, including other MX Ergo controller instances.

## 8. Review is not permission

Plans and readiness snapshots carry an `authorization` field whose enum has
exactly one case: `notAuthorizedForExecution`. The type system makes such a
value proof that a review happened and *nothing more*.

Execution requires a separate, non-`Codable`, actor-isolated, **one-use**
authorization bound to one launch, one operation, one device and firmware
identity, one feature and session generation, exact journal bytes, the immutable
packet bytes, and a monotonic expiry. It is consumed before effects and
re-checked after every awaited handoff.

Before constructing the live Precision transport, startup must obtain a fresh
read-only Root/firmware transcript from the acquired endpoint that matches the
authorized binding. This evidence grants no SET permission. Verification output
requires a sequence-issued token matching the exact UUID, session, packet bytes,
and endpoint metadata; the normal SET allowlist remains separate. Input is armed
before output, deadlines and candidate limits are bounded, and failure drains
physical output before releasing ownership. Captured observer values remain
authorization context, not a substitute for current endpoint evidence.

## 9. Teardown order is fixed

Shutdown always: closes request admission, disconnects the transport, waits for
in-flight durable work to settle, classifies the final journal state, drains
output, quiesces input callbacks, closes the device, and only then releases the
retained anchor — exactly once.

Abandoning a coordinator must not release the device through ordinary ARC; the
ownership capsule quarantines the endpoint bundle fail-closed.

## 10. Quit does not restore

Quitting the app does **not** send an inverse SET. If a control must return to
its baseline, deactivate it explicitly first. A physical disconnect while
diverted is classified `recovery-required` and never triggers an automatic
re-admit or re-SET on reconnect.

## 11. The event layer fails open

Suppressing input carries a hazard unlike a device write: it is fully
reversible, but while it is wrong the pointing device feels broken, and the user
may not be able to click their way to fixing it.

So every uncertainty resolves toward *letting the event through*.

* The tap's event mask admits exactly `otherMouseDown`, `otherMouseUp` and
  `scrollWheel`. The primary and secondary buttons are not in it and have no
  case in the observed-event type, so no state can swallow an ordinary click.
* An unrecognised or undecodable event is passed through.
* If the replacement cannot be **built**, the original is passed through rather
  than swallowed — losing the input outright is the one outcome worse than not
  remapping at all. Construction is the only failure this layer can detect;
  `CGEvent.post` reports nothing.
* Injection is **deferred until the callback has returned**. The window server
  drops an event posted from inside a tap callback — established on hardware
  2026-09-05, where the identical chord worked posted from a button and did
  nothing posted from the callback. The decision is made synchronously, since
  the callback must return suppress or pass-through; only delivery is deferred,
  onto a block on the tap's own run loop, so it stays on one thread and keeps
  the order events arrived in.
* A release is suppressed only if *this policy suppressed its press*. Consulting
  the plan instead would hand the frontmost app a mouse-up it never saw a
  mouse-down for.
* Continuous horizontal scroll is never suppressed. It is a trackpad gesture,
  and swallowing it would break back and forward for every other pointing
  device on the machine.
* Mixed-axis scroll is passed through, so catching the horizontal half cannot
  silently eat the vertical half.

Re-enabling a tap that macOS disabled by timeout is **not** the retry rule 4
forbids. That rule is about re-sending a command the device may already have
acted on. Nothing here reaches the device, and re-arming is the documented
contract of an event tap.

---

## Before changing anything

Run `scripts/verify.sh`. It runs the six README commands in their load-bearing
order, executes all tests with no silent skips, builds all four signed targets,
and audits the signature and `App/` sources.

Ask, in order:

1. Does this add a dependency edge out of a productless target?
2. Does this add a second `IOHIDDeviceSetReport` call site?
3. Does this let an acknowledgement stand in for a verification GET?
4. Does this introduce a retry, an inverse command, or an automatic recovery?
5. Does this let a durable ambiguity be resolved without a human?
6. Does this rewrite journal bytes that something else is pinning?
7. Does this add a second `CGEvent.post` call site, or a third suppressing tap?
8. Does this make the event layer fail *closed* — swallowing input on an error?

If the answer to any is yes, it needs an explicit review, not a commit.
