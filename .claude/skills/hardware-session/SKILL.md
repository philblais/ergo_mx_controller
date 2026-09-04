---
name: hardware-session
description: Prepare, run, or record a physical MX Ergo trackball session — a live HID++ query, preflight, admit, deactivate, or recover. Use when the user is about to run the app against the real device, is reporting what happened during a session, or asks what to capture. Also use when a SET produced an ambiguous or unknown outcome.
---

# Hardware session

Physical sessions are the scarce resource in this project: there is one
trackball, and a bad write can leave it in a state its vendor software will not
repair. Prepare fully before the device is touched.

**You cannot run these steps.** They need the user at the keyboard. Your job is
to prepare the code, hand over an exact sequence, and record what actually
happened. Never write an outcome into `Evidence/` that you did not observe.

## Before the session

1. `scripts/verify.sh` must be green — 344 tests, 0 skipped.
2. Capture the starting hashes:
   ```bash
   shasum -a 256 ~/Library/Application\ Support/com.phib.MXErgoController/*.json
   ```
3. Confirm with the user that **BetterTouchTool is completely quit**. It
   relaunches itself; an automatic restart already confounded one observation on
   2026-08-30. Also Logi Options / Options+ and any other MX Ergo software.
4. Ask the user to power-cycle the trackball.
5. State in advance which step can send a SET, and what the exact bytes will be.

## During

Follow [RUNBOOK.md](../../../RUNBOOK.md). The gate chain is enforced by the app,
so steps cannot be skipped:

```
observer running + 1 BLE device + Input Monitoring
  └─ Root query                    → feature index (expect 0x0A), version 3
      ├─ control enumeration       → 9 controls
      │   └─ baseline snapshot     → schema-v2 journal
      └─ firmware fingerprint
          └─ restore-only packet preview
              └─ dormant trial self-test
                  └─ live Precision GET preflight   → exact baseline 00 ED 00 00 …
                      └─ lifecycle readiness        → must say NOT AUTHORIZED
                          └─ bind  →  admit / recover  →  deactivate  →  rollover
```

Capture for every HID step: the exact 20-byte request and the exact 20-byte
response, as hex.

## If a SET outcome is ambiguous

Stop. This is the one situation the whole design exists for.

- Do **not** retry it.
- Do **not** send an inverse command.
- Do **not** rewrite the journal to a clean state because the button "seems fine".

The recovery path, which worked on 2026-08-30:

1. Quit everything, power-cycle the trackball.
2. Run the signed GET-only probe and preserve its result file.
3. Reconcile offline with `MXErgoPrecisionTrialReconciler`, which has no HID API
   in its executable.
4. Confirm the protected hashes are unchanged on both sides.

After an `outcomeUnknown` restore the Recover control locks by design. Observing
that the button is still diverted does **not** license a second restore SET.

## After the session

Verify nothing moved that should not have:

```bash
shasum -a 256 ~/Library/Application\ Support/com.phib.MXErgoController/*.json
```

`device-state-journal.json` must still be `60ab6149…f77097`.

Then append to `Evidence/VALIDATION-RECORDS.md` in the established house style —
a `### Live validation record — <date>` heading, the exact wire bytes in fenced
`text` blocks, what resolved to what, and an explicit statement of what did not
change. Copy any new durable journal into a fresh dated `Evidence/` directory.

Write only what was observed. If a step was not reached, say so.
