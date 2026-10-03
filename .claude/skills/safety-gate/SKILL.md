---
name: safety-gate
description: Check a proposed change against the MX Ergo project's eleven safety invariants before writing code. Use whenever a change touches HID output, event synthesis or CGEvent posting, the Precision or mapped-control runtime, the durable transaction journals, SwiftPM target wiring, package products, project.yml, or anything named Precision/Transport/IOHID/Admission/Journal/EventTap. Also use when asked whether something is safe to run against the trackball.
---

# Hardware safety gate

This project writes to a physical input device. A wrong write can leave the
trackball in a state its vendor software will not repair. Work through this
before writing code, not after.

Read [SAFETY.md](../../../SAFETY.md) for the full statement of each rule.

## The eight questions

Answer each one explicitly. If any answer is yes, stop and tell the user the
change needs an explicit review rather than a commit.

1. **Does this add a dependency edge out of a productless target?**
   Fifteen of twenty-one package targets deliberately have no library product,
   so nothing can link against them directly. Check
   `Packages/MXErgoKit/Package.swift` — a target is productless if its name
   appears only in the `targets:` half of the manifest, split on a
   line-anchored `"\n    targets: ["`.

   Productless does not always mean unreachable: several are reached through
   `MXErgoPrecisionRuntimeOwner`, and the event layer through
   `MXErgoEventLayer`. What must stay true is that no app or helper names them
   directly. Promoting a capability means adding a facade with a pinned public
   API list, never giving the working target a product.

2. **Does this add a second `IOHIDDeviceSetReport` call site?**
   The Precision runtime has exactly one, in `MXErgoPrecisionIOHIDOutput`.
   `MXErgoObserver` has six for read-only HID++ GETs, which travel as output
   reports — those are existing and expected. Adding a new one anywhere is a
   review.

3. **Does this let a SET acknowledgement stand in for a verification GET?**
   A correlated non-echo reply is diagnostic evidence only. Only a separate
   `GetCidReporting` may move a control to `appliedVerified` or
   `restoredVerified`.

4. **Does this introduce a retry, an inverse command, or automatic recovery?**
   There are none in this project and there must be none. Once a SET may have
   crossed the writer boundary, the epoch is poisoned and the operation stops.

5. **Does this let a durable ambiguity be resolved without a human?**
   `outcomeUnknown` is resolved by a GET-only probe plus an offline reconciler,
   never in-process.

6. **Does this rewrite journal bytes something else is pinning?**
   `device-state-journal.json` is the recovery ground truth and is never
   rewritten. Its SHA-256 and four sibling files are pinned by
   `PrecisionForensicEvidenceAudit`.

7. **Does this add a second `CGEvent.post` call site, or a third suppressing
   tap?**
   There is exactly one post site, in `MXErgoEventTap`, and exactly two
   `CGEvent.tapCreate` sites: the Precision scroll swallow in `MXErgoHID` and
   the synthesis tap. `eventLayerIsProductlessUnwiredAndHoldsExactlyOneInjectionSite`
   counts all three across the whole `Sources` tree.

8. **Does this make the event layer fail closed?**
   Every error path must pass the original event through. An unrecognised
   event, a failed injection, a continuous (trackpad) horizontal scroll and a
   mixed-axis scroll are all passed through. A release is suppressed only if
   this policy suppressed its press. Suppressing input on an error makes the
   pointing device feel broken while offering no way to click out of it.

   Re-enabling a tap macOS disabled by timeout is not the question-4 retry.
   That rule is about re-sending a command the device may have acted on.

## Currently protected hashes

`Evidence/2026-08-30/` and the live Application Support directory must both
still match these. `scripts/verify.sh` checks them.

| File | SHA-256 |
|---|---|
| `device-state-journal.json` | `60ab6149…f77097` |
| `device-state-journal.pre-firmware-identity.json` | `4ef802eb…cdf3aa` |
| `restore-trial-probe-result.json` | `7887950e…36c5460` |
| `restore-only-precision-trial.json` | `1efee23b…cba66ac` |
| `restore-only-precision-reconciliation-result.json` | `f208abe8…7c6593` |

## Current authorization state

- **September 11 automatic restart:** the user authorized a visible persistent
  opt-in through the existing owner facade. Fresh one-use automatic capabilities
  permit GET-only resume or one checked clean activation per launch. A baseline
  resume result requires successful drain/close/fence release, CAS archival and
  a fresh observer/evidence sequence before activation. Revocation is checked
  through admission and at physical write entry; uncertainty never triggers a
  retry, inverse command or automatic recovery. Pinned files are untouched. The
  setting defaults off; attended automatic-start hardware acceptance is pending.
- **September 28 sleep/wake reconnect:** while that opt-in remains current, an
  active endpoint may be rolled over at `willSleep` only after ordered shutdown,
  exact active classification, zero close, unchanged runtime bytes, and a clear
  synchronous disconnect witness. The resulting one-use capability permits only
  GET-only `.resume` on a different fresh observer run after `didWake`; it carries
  no SET authority and has no baseline-to-activate fallback. Any changed evidence,
  disconnect, failed close, stale cycle or opt-out leaves audio off for review.

Keep this accurate; it is the thing most likely to drift.

- **Precision CID `00ED`** — full runtime exists, is wired to the menu app
  through `MXErgoPrecisionRuntimeOwner`, and **ran successfully on hardware
  2026-09-04**: apply verified, restore verified, back at baseline. The durable
  runtime journal `precision-runtime-v3.json` now exists at revision 6,
  `restoredVerified`. **Tap-to-mute, hold+scroll volume and the scroll swallow
  all work on hardware** (2026-09-04). The press notification carries CID `00ED`
  with device index `0xFF`. The app needs **Accessibility** as well as Input
  Monitoring, because the scroll swallow uses a suppressing `CGEvent` tap. A
  spent journal is retired with **Retire completed runtime journal…**, which is
  HID-free and refuses any journal still holding active, ambiguous, conflicted,
  or recovery-required evidence.
- **No mapped control needs diversion.** Observed 2026-09-04: thumb buttons are
  ordinary HID buttons `0x08`/`0x10`, both wheel tilts are ordinary horizontal
  scroll. Wheel click was *inferred* to be middle click that day and only
  **observed on 2026-09-05** as mask `0x04`. Only Precision (`00ED`) produces no
  ordinary report. **Do not build a multi-CID SET path.** All five are handled
  by the event layer with no device write at all.
- **Mapped CIDs `0052`, `0053`, `0056`, `005B`, `005D`** — the HID++ diversion
  plan, readiness, action plan, event pump and live GET-only preflight all still
  exist and all still return `notAuthorizedForExecution`. **No mapped SET has
  ever been sent and none should be.** That path is cancelled, not pending: the
  hardware does not need it. These artefacts remain as reviewed evidence.
- **`CGEvent` posting — exists, is live, and arms itself at login.** This
  changed on 2026-09-05 and is the largest shift in the project's posture.
  - Exactly **one** `CGEvent.post` call site, in `MXErgoEventTap`'s
    `PreparedCoreGraphicsEvents`. A test counts it across the whole `Sources`
    tree. Exactly **two** suppressing `CGEvent.tapCreate` sites: the Precision
    scroll swallow in `MXErgoHID` and the synthesis tap.
  - `MXErgoEventSynthesis` and `MXErgoEventTap` stay productless and
    `package`-only. The app reaches them solely through the `MXErgoEventLayer`
    facade, whose public surface is a pinned list — widening it fails a test.
  - `verify.sh` refuses `.post(tap:` and `CGEvent.tapCreate` in `App/`.
  - It is **on by default now**, because the switch is remembered and the app is
    a login item. A remembered "on" still requires Accessibility and refuses
    visibly without it.
  - Three things learned the hard way, all in `Evidence/VALIDATION-RECORDS.md`:
    a synthetic arrow key needs the numeric-pad and secondary-function flags or
    the window server ignores it; the horizontal scroll sign inverts with the
    "natural scrolling" preference and must be derived from it; and Safari
    ignores the back/forward mouse buttons, so it gets Command+Arrow instead.
- **What still must not happen.** No second post call site. No third suppressing
  tap. No mapped-control SET. No gesture synthesis through private API — macOS
  exposes none publicly, which is why the swipe became a substitution. And the
  event layer must keep failing **open**: every error path passes the original
  event through.

## After the change

Run `scripts/verify.sh`. Then state plainly, in the same terms the changelog
uses, whether any live HID operation was performed. If none was, say so.
