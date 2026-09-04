---
name: safety-gate
description: Check a proposed change against the MX Ergo project's ten hardware-safety invariants before writing code. Use whenever a change touches HID output, the Precision or mapped-control runtime, the durable transaction journals, SwiftPM target wiring, package products, project.yml, or anything named Precision/Transport/IOHID/Admission/Journal. Also use when asked whether something is safe to run against the trackball.
---

# Hardware safety gate

This project writes to a physical input device. A wrong write can leave the
trackball in a state its vendor software will not repair. Work through this
before writing code, not after.

Read [SAFETY.md](../../../SAFETY.md) for the full statement of each rule.

## The six questions

Answer each one explicitly. If any answer is yes, stop and tell the user the
change needs an explicit review rather than a commit.

1. **Does this add a dependency edge out of a productless target?**
   Fourteen of twenty package targets deliberately have no library product and
   no app/helper edge, so the linker cannot pull them into a signed binary.
   Check `Packages/MXErgoKit/Package.swift` — a target is productless if its
   name appears only in the `targets:` half of the manifest.

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

Keep this accurate; it is the thing most likely to drift.

- **Precision CID `00ED`** — full runtime exists, is wired to the menu app
  through `MXErgoPrecisionRuntimeOwner`, and **ran successfully on hardware
  2026-09-04**: apply verified, restore verified, back at baseline. The durable
  runtime journal `precision-runtime-v3.json` now exists at revision 6,
  `restoredVerified`. **Tap-to-mute and hold+scroll volume were tried and do
  not work** — no diverted control notification reaches the intent path, cause
  undetermined. The runtime now reports input diagnostics (observed vs routed
  frame counts plus the last frame's bytes); a short hardware session should
  settle it. A spent journal is retired with **Retire completed runtime
  journal…**, which is HID-free and refuses any journal still holding active,
  ambiguous, conflicted, or recovery-required evidence.
- **No mapped control needs diversion.** Observed 2026-09-04: thumb buttons are
  ordinary HID buttons `0x08`/`0x10`, both wheel tilts are ordinary horizontal
  scroll, wheel click is middle click. Only Precision (`00ED`) produces no
  ordinary report. **Do not build a multi-CID SET path.** Replacing
  BetterTouchTool for the other five is an event-layer problem with no device
  write; it needs an Accessibility gate and a horizontal scroll path, not HID++.
- **Mapped CIDs `0052`, `0053`, `0056`, `005B`, `005D`** — plan, readiness,
  action plan, event pump and live GET-only preflight all exist and all return
  `notAuthorizedForExecution`. No SET, no CGEvent posting. The project's own
  gate is that these stay unauthorized until the Precision recover lock has been
  exercised on hardware, then are admitted one CID at a time.
- **`CGEvent` posting** — does not exist anywhere. The only `CGEvent` use is a
  listen-only scroll tap in `MXErgoWheelObserver`. Adding posting also needs an
  Accessibility (TCC) permission gate, which does not exist yet.

## After the change

Run `scripts/verify.sh`. Then state plainly, in the same terms the changelog
uses, whether any live HID operation was performed. If none was, say so.
