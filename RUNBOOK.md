# Hardware validation runbook

Steps to exercise the app against the physical MX Ergo. They are ordered, and
the order is load-bearing: later steps depend on evidence that earlier steps
establish, and the app's gates enforce that chain.

Before any step that can reach the device:

1. Quit BetterTouchTool **completely**. It relaunches itself; confirm it is gone
   rather than assuming. An automatic restart already confounded one observation
   on 2026-08-30.
2. Quit Logi Options / Options+ and any other MX Ergo software.
3. Power-cycle the trackball.
4. Record the SHA-256 of `device-state-journal.json` before and after.

If a SET produces an ambiguous result, stop. Do not retry it and do not send an
inverse command. See [SAFETY.md](SAFETY.md).

---

## Hardware validation

1. Leave BetterTouchTool running for passive observer tests.
2. Build and run `MXErgoController` from Xcode.
3. Grant Input Monitoring if macOS asks, then restart the app.
4. Confirm the menu shows `046D / B01D` and `Bluetooth Low Energy`.
5. Move the ball and press buttons. The report count should increase without changing existing BetterTouchTool behavior.
6. In **Control calibration**, press one physical button at a time. Logitech controls are named; the wheel click appears as a standard mouse-button transition.
7. Power the trackball off and on. Connection state should recover within five seconds.
8. If the device appears but report counts never change, quit BetterTouchTool and retry. That establishes whether both apps can observe the vendor interface simultaneously.
9. For HID++ discovery, fully quit BetterTouchTool, power the MX Ergo off and on, then send the Root query once.
10. After Root succeeds, review and run **Read-only control enumeration** once. Confirm that every reported index appears with a CID, task ID, and capability flags.
11. Review and run **Read-only baseline snapshot** once. Confirm that all 9 controls appear with reporting flags and mapped CIDs, and that the status says the baseline was saved and verified.
12. In a fresh build, run **Recovery transaction rehearsal**. Confirm that it reports 9 controls × 5 verified phases and explicitly says the journal was unchanged and no HID output was used.
13. Run **Schema-v3 coordinator self-test**. Confirm it reports all 9 controls, all 16 apply/restore transport scenarios, all 6 durable commit boundaries, 14 exact recovery classifications, 14 reconnect identity bindings, 15 immutable feature-v3 wire bytes, two interrupted restart recoveries, and an unchanged live schema-v2 baseline.
14. In a newly launched build, review and run **Read-only firmware fingerprint** exactly once. Confirm that Device Information feature `0x0003`, the unit/model identifiers, and every firmware entity are shown, and that the UI says the canonical identity remains memory-only.
15. After firmware discovery, run **Firmware identity migration dry-run**. Confirm that it reports one proposed field, preserves schema v2 and the transaction, and explicitly says no journal bytes were written and no HID request was sent.
16. Only after separately authorizing persistence, review **Durable firmware identity commit**. Verify the displayed live path, full source hash, transaction ID, unchanged schema, sole changed field, and backup path before selecting **Commit journal metadata**. The commit sends no HID command.
17. In a fresh session, resolve `REPROG_CONTROLS_V4` and rediscover firmware, then run **Restore-only packet preview**. Confirm each feature-v3 SET uses only flag `02` and mapped CID `0000`, shows a separate VERIFY packet, and explicitly says no sender exists. Verify the live journal hash is unchanged.
18. Run **Dormant Precision trial self-test**. Confirm it reports Precision CID `00ED`, four durable commits, one scripted SET, two independent device-state reads, two exact live-baseline validations, one operation-wide lease, final `baselineVerified`, and an unchanged live journal/device. This self-test has no IOHID transport.
19. Fully quit BetterTouchTool and `MX Ergo Controller`, then launch the signed `MXErgoRestoreTrialProbe` helper with `--confirmed-read-only-probe`. Grant Input Monitoring to the helper if macOS asks, relaunch it once, and do not run either Logitech software or the menu app concurrently.
20. Inspect `~/Library/Application Support/com.phib.MXErgoController/restore-trial-probe-result.json`. Confirm that it reports the exact MX Ergo identity, firmware-bound journal, one Precision CID `00ED` GET using software ID `0x0D`, flags `0000`, map `0000`, synchronous IOHID closure, and unchanged journal/backup hashes. The helper has no SET request, automatic retry, or journal write path.
21. Do not launch `MXErgoPrecisionRestoreTrial` from Xcode. Its scheme has no confirmation argument and therefore exits before IOHID. A physical trial requires a separate explicit approval, a fresh signature/build-graph audit, BetterTouchTool and Logi Options fully stopped, and the exact command-line argument. After a trial, inspect `restore-only-precision-trial.json` and `restore-only-precision-trial-result.json` before any further attempt.
22. If a physical SET has an ambiguous transport result, never rerun it. Build the GET-only probe from the current source, preserve the prior result, and capture the exact Precision response only after synchronous IOHID shutdown and unchanged protected hashes.
23. If temporary diversion remains active, keep competing software stopped, power-cycle the MX Ergo, and run one further GET-only probe. Do not design another write unless the clean baseline still fails to return.
24. `MXErgoPrecisionTrialReconciler` is an offline, HID-free helper for the first authorized trial only. It accepts `--confirmed-read-only-reconcile-baseline`, pins the exact outcome-unknown journal and signed post-power-cycle probe hashes, uses the existing restart reconciliation reducer, and atomically advances only the dedicated trial journal. It refuses any repeat or changed evidence.
25. After a successful exact-baseline preflight, select **Review Precision lifecycle readiness…**. With BetterTouchTool and Logi Options fully quit, confirm the result says `NOT AUTHORIZED`, shows the immutable apply/restore packet projections and baseline SHA-256, and explicitly reports that no coordinator, transaction journal, transport, or HID operation is reachable. Launching a competitor must invalidate the result.
26. After that review, select **Bind dormant runtime owner…** and confirm. The observer should keep running. Stop it, then confirm **Start observer** stays disabled until **Release for session rollover…**. Quit must not lift the fence; a later launch has no persisted fence. This bind still sends no SET and does not admit the Precision runtime.
27. To admit, keep BetterTouchTool and Logi Options fully quit, leave the observer running after bind, then select **Admit Precision runtime…** and confirm. The observer should stop. Enable the Audio test, then tap Precision to mute. Hold Precision and scroll to change volume without scrolling the frontmost app. Select **Deactivate Precision…** before quit if you need the baseline restored. **Release for session rollover…** stays disabled while admitted.
28. While admitted, power the MX Ergo off. The status should become recovery-required, mute/volume should stop, no restore SET should be sent, and **Release for session rollover…** should enable. Powering the trackball back on must not re-admit or retry a SET. After rollover, start the observer again on the new connection; do not expect the previous session epoch to be reusable.
29. After that new observer run, resolve Root and firmware again, then run Precision preflight. If live Precision still differs from baseline, the app should keep that GET as recover evidence. Review readiness, bind, then confirm **Recover Precision…**. That can send one restore SET. It must not retry if the SET is ambiguous. If Recover reports an unknown SET outcome, the control stays locked; use a GET-only probe and do not send another SET.
30. With a clean firmware-bound baseline, select **Review mapped-control diversion…**. With BetterTouchTool and Logi Options fully quit, confirm it lists wheel click, both thumbs, and both tilts with apply flags `03`, restore flags `02`, and independent GET/VERIFY packets, shows the journal SHA-256, lists desktop left/right, back/forward, and Mission Control as the BTT-replacement actions, reports event delivery as `0 of 5` CIDs admitted, says `NOT AUTHORIZED`, and does not change the MX Ergo or post those events. Launching a competitor must invalidate the result.
31. After that review, select **Send mapped-control GET preflight…**. Confirm five sequential `GetCidReporting` requests, exact baseline matches, `NOT AUTHORIZED`, no SET, and an unchanged journal. Any mismatch, timeout, or disconnect must stop the sequence with no retry.

---

## Read-only diagnostic: which buttons need HID++ diversion at all?

Zero risk. No SET, no admission, no diversion — just the observer and the
calibration panel, which prints the raw hex of every report it receives
(`ObserverMenuView.swift`, calibration section).

**Why this matters.** The 2026-08-27 baseline snapshot recorded all nine
reprogrammable controls at `flags 0000` — nothing diverted — while
BetterTouchTool was in daily use. BetterTouchTool therefore does **not** use
HID++ diversion for the thumb buttons, wheel tilt, or wheel click. It must be
acting on events macOS already delivers, which means those controls appear in
the MX Ergo's ordinary HID reports.

If that is so, the five mapped CIDs may not need HID++ diversion at all, and the
planned multi-CID SET path would be solving a problem that does not exist. Only
the Precision button (CID `00ED`), which has no ordinary representation, would
genuinely require diversion.

**Procedure.**

1. Quit BetterTouchTool and Logi Options so nothing else consumes the buttons.
2. Start the observer. Do **not** bind, admit, or send anything.
3. In **Control calibration**, press one control at a time, pausing between
   each: left, right, wheel click, lower thumb, upper thumb, wheel tilt left,
   wheel tilt right, Precision.
4. For each, record the raw hex line.

**Reading the result.** A report beginning `02` is the ordinary mouse report;
its second byte is an 8-bit button mask (`Observation.swift`,
`standardMouseButtonMask`). A control that changes a bit in that mask is already
visible to macOS and needs no diversion. A control that produces nothing, or
produces only a `11 …` vendor report, has no ordinary representation and is a
genuine diversion candidate.

Record the result in `Evidence/VALIDATION-RECORDS.md` before designing any
mapped-control SET path.

---

## Precision audio verification

Confirms tap-to-mute, hold+scroll volume, and the scroll swallow, and captures
the evidence for the validation record. One full admit cycle.

**Before starting**

- Quit BetterTouchTool and Logi Options completely, and power-cycle the
  trackball.
- Rebuild in Xcode. The `last press` line in the input-evidence panel is recent;
  an older build silently omits it.
- Confirm the schema-v2 baseline is still
  `60ab614927d20871994ad0ebe7368158af9a26b2c1d60f7a2ab3c51635f77097`.

**1. Launch and read the permission rows — before anything else**

Note whether **Accessibility** says granted. This matters: the scroll swallow
uses a `CGEvent` tap created with `.defaultTap`, which can suppress events, and a
suppressing tap requires Accessibility rather than Input Monitoring alone. If it
is not granted, expect the page to scroll while Precision is held even when
volume works.

**2. Retire the spent journal**

A completed journal blocks admission. **Retire completed runtime journal…** →
*Archive and retire*. It renames rather than deletes and sends no HID command.

**3. Read-only chain — keep the Audio test OFF for all of it**

Each is review-then-confirm:

1. Review one-shot query… → *Send exactly once* — expect feature index `0x0A`, version 3
2. Review firmware discovery… → *Discover exactly once*
3. Review offline restore packets… → *Build without sending*
4. Review dormant trial self-test… → *Run isolated trial*
5. Review live Precision preflight… → *Send one read-only GET* — expect exact baseline
6. Review Precision lifecycle readiness… — must say `NOT AUTHORIZED`

**4. Bind and admit — back to back, no pause**

The one-use authorization is minted at bind with a ten-minute lifetime, so any
delay between these two expires it and the bound intent can never succeed.

7. **Bind dormant runtime owner…** → *Bind without admitting*
8. **Admit Precision runtime…** → *Admit and send SET*

Status should read `Precision diverted (active)`.

**5. The measurement**

9. Turn **on** "Execute mute and volume".
10. **Tap Precision quickly** — under a third of a second. A slower press is a
    hold by design and emits no mute intent.
11. **Hold Precision and scroll** over a long page. Volume should change and the
    page should not move.
12. Click **Refresh input evidence**.

**6. Record**

Capture the input-evidence panel: the counts, `last frame`, and `last press`.
A press frame reading `11 FF 0A 00 00 ED …` confirms the notification carries
Precision's CID. Note what `Last preview` showed for each action.

**7. Finish**

13. **Deactivate Precision…** → *Deactivate and send SET*. Status should turn
    green: `Precision restored to baseline; runtime still admitted`.
14. Quit. Quit alone never sends an inverse SET, so deactivating first is what
    returns the button.
15. Confirm the runtime journal reads `restoredVerified` and the schema-v2
    baseline hash is unchanged.
