# Live validation records

What the physical MX Ergo actually did, session by session. These are the only
claims in the project backed by hardware rather than by tests.

Byte-identical copies of the durable journals these sessions produced are in
[2026-08-30/](2026-08-30/), and their SHA-256 values are pinned by
`PrecisionForensicEvidenceAudit`.

---

### Live validation record — 2026-08-27

With BetterTouchTool fully stopped and the MX Ergo power-cycled, the signed app sent one 20-byte output report:

```text
11 00 00 0E 1B 04 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

The same physical BLE interface returned the correlated response:

```text
11 00 00 0E 0A 00 03 00 00 00 00 00 00 00 00 00 00 00 00 00
```

For this connection, `REPROG_CONTROLS_V4` resolved to runtime feature index `0x0A`, type `0x00`, version `3`. The implementation must continue resolving that index through Root rather than hardcoding it.

The follow-on bounded enumeration then returned a count of 9 and one complete
metadata record for every index:

```text
[00] CID 0050  task 0038  flags 11
[01] CID 0051  task 0039  flags 11
[02] CID 0052  task 003A  flags 71
[03] CID 0053  task 003C  flags 71
[04] CID 0056  task 003E  flags 71
[05] CID 00ED  task 00C4  flags 71
[06] CID 005B  task 003F  flags 71
[07] CID 005D  task 0040  flags 71
[08] CID 00D7  task 00B4  flags A0
```

This validates the same-device, sequential `GetCount`/`GetControlInfo` path on
the physical MX Ergo. No device state changed during the session.

The follow-on reporting snapshot returned the same 9 CIDs with reporting flags
`0000` and mapped CID `0000` for every control. The app atomically saved schema
version 2 transaction `75465823-37D5-4685-A6C8-398A9B0D72F1`; every entry is in
the `baselineVerified` phase and is bound to serial `7865BCA9046ED9FF`.

The device registry also reported `MaxOutputReportSize = 20`. Its raw HID descriptor contains `85 11 75 08 95 13`, describing report ID `0x11` with nineteen 8-bit payload fields (20 wire bytes including the report ID).

### Live validation record — 2026-08-28

The signed recovery-rehearsal build loaded the saved nine-control baseline in a
fresh app session and completed all five phases for every control. The UI
reported `9 controls × 5 verified phases`, no HID output, and an unchanged
journal. The file's SHA-256 remained
`4ef802eb1185c56f24b7635324113ab414f2acca499a4addc4e4117cd3cdf3aa`
before and after the live rehearsal.

The expanded schema-v3 self-test subsequently passed all 16 apply/restore
transport scenarios, 6 durable commit boundaries, 14 exact recovery
classifications, 14 reconnect identity bindings, 15 immutable feature-v3 wire
bytes, and two interrupted restart recoveries. The same live baseline hash
remained unchanged.

The first live Device Information `0x0003` pass reported three entities: main
firmware `MPM 06.03.B0022`, bootloader `BOT 49.00.B0001`, and a type-`0x05`
Bluetooth SoftDevice whose version bytes end in opaque build value `0x005A`.
That last value is not valid packed BCD. The decoder therefore preserves and
fingerprints every raw version byte, while using friendly BCD formatting only
when all nibbles are valid. Transient active/PID fields remain excluded.

### Live validation record — 2026-08-30

The standalone signed `MXErgoRestoreTrialProbe` ran after the menu observer and
all competing Logitech software had exited. Its build graph contained one
target with no package dependency, and static symbol/string audits found no
reporting planner, trial adapter, or SET implementation.

The helper independently resolved `REPROG_CONTROLS_V4` to index `0x0A`, matched
the saved firmware identity, and sent exactly one Precision reporting-state GET
using helper software ID `0x0D`:

```text
11 00 0A 2D 00 ED 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

The exact correlated response was identical, confirming CID `00ED`, reporting
flags `0000`, and mapped CID `0000`. The helper then synchronously closed IOHID
and exited. The live journal SHA-256 was
`60ab614927d20871994ad0ebe7368158af9a26b2c1d60f7a2ab3c51635f77097`
before and after; the original-byte backup remained
`4ef802eb1185c56f24b7635324113ab414f2acca499a4addc4e4117cd3cdf3aa`.
The structured result is stored at
`~/Library/Application Support/com.phib.MXErgoController/restore-trial-probe-result.json`.
No SET request exists in the helper executable.

### Live validation record — 2026-09-04

The first successful live Precision temporary-diversion lifecycle. With
BetterTouchTool and Logi Options fully quit and the MX Ergo power-cycled, the
signed menu app resolved Root, matched the firmware identity, completed the
exact-baseline Precision preflight, reviewed lifecycle readiness as
`NOT AUTHORIZED`, bound the runtime owner, and admitted the Precision runtime.

`REPROG_CONTROLS_V4` again resolved to runtime feature index `0x0A`, version 3.
The runtime journal `precision-runtime-v3.json` was created for the first time,
bootstrapped from the clean schema-v2 baseline.

The apply attempt dispatched exactly one SET:

```text
11 00 0A 3E 00 ED 03 00 00 00 00 00 00 00 00 00 00 00 00 00
```

The device returned a correlated reply that was **not** an exact echo:

```text
11 00 0A 3E 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

That response was classified `correlatedNonEcho` and retained as diagnostic
evidence only. The independent verification GET established the applied state:

```text
00 ED 01 00 00 00 00 00 00 00 00 00 00 00 00 00
```

Flags `01` — Precision temporarily diverted.

The restore attempt dispatched exactly one SET:

```text
11 00 0A 3E 00 ED 02 00 00 00 00 00 00 00 00 00 00 00 00 00
```

The device again returned a correlated non-echo reply:

```text
11 00 0A 3E 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

The independent verification GET returned the exact baseline:

```text
00 ED 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

Both attempts recorded `outcome: verified`. The durable journal reached
revision 6 with CID `00ED` at `restoredVerified` and no other control dirty.
Quitting the app wrote nothing further and sent no inverse SET.

The schema-v2 baseline remained
`60ab614927d20871994ad0ebe7368158af9a26b2c1d60f7a2ab3c51635f77097`
throughout. The resulting runtime journal is
`6ba7516b32f4c34345a59ec521bd658a395b35be3c39faa2af79973834fff41c`.

This session validates the project's central design bet on real hardware. The
2026-08-30 trial helper demanded an exact full echo and consequently recorded
`outcomeUnknown` for a SET that had in fact behaved correctly. The MX Ergo does
not echo `SetCidReporting`; it replies with the function header and zeroed
parameters. Because the production lifecycle treats an acknowledgement as
evidence and an independent GET as proof, both attempts verified cleanly.

Two defects were found, both in presentation rather than in device handling:

- The one-use admission authorization is minted inside `bind()` with a
  ten-minute lifetime, so a pause between binding and admitting expires it. The
  abort was clean and fail-closed — no observer stop, no lease, no journal
  write, no HID frame — but the Admit control stayed enabled while it could
  never succeed, with no countdown and no prompt to re-bind.
- After a verified restore the status line continued to read
  `Precision diverted (active)`, because it was derived from whether the runtime
  was admitted rather than from the diversion status. The runtime is still
  admitted after a restore; the control is not diverted.

The live mapped-control GET preflight was also run in the same session and
matched the firmware-bound baseline for all five CIDs, with feature index `0x0A`
and epoch 0. It remains `notAuthorizedForExecution`: five live GETs only, no
SET, retry, or event synthesis.

### Live validation record — 2026-09-04, second session

Purpose: exercise Precision tap-to-mute and hold+scroll volume, which the first
session never reached. **The audio path did not work.** The diversion lifecycle
completed cleanly for a second time, but no control event produced any effect.

The spent runtime journal from the first session was archived by hand to
`precision-runtime-v3.completed-2026-09-04T1118.json` so a fresh one could
bootstrap; see the rotation gap below. The new journal `068E3DA7-6D9D-48B7-A8BE-AC3A866E2272`
bootstrapped clean from the unchanged schema-v2 baseline.

The second lifecycle repeated the first exactly: one apply SET verified by an
independent GET returning flags `01`, one restore SET verified by an exact
baseline GET, both attempts `verified`, both device replies `correlatedNonEcho`.
Final state `restoredVerified`, status `completed`, revision 6, no other control
dirty. The schema-v2 baseline remained
`60ab614927d20871994ad0ebe7368158af9a26b2c1d60f7a2ab3c51635f77097`.

While Precision was verified diverted (`flags 01`) with audio execution
explicitly enabled:

- Tapping Precision **did not** mute or unmute system audio.
- Holding Precision and scrolling **did not** change the volume, and the
  frontmost page **scrolled normally** — the HID-level scroll swallow never
  engaged.

Both failures are consistent with a single cause: no diverted control
notification reached the controller intent path. The scroll swallow is gated on
Precision being held, and the held flag is derived from that same notification
stream, so one missing input explains both symptoms.

The cause was **not** determined in this session, and two candidates remain open:

1. The unsolicited-notification filter and the notification decoder both require
   device index `0xFF` (`PrecisionCallbackInputChannel` and
   `LogitechControlEventDecoder.decodeNotification`). Every request and response
   frame observed from this MX Ergo over direct BLE uses device index `0x00`.
2. Against that, the calibration panel decodes through the same
   `decodeNotification` and has historically named Logitech controls while
   BetterTouchTool held them diverted, which suggests `0xFF` is correct for this
   device's notifications and the fault lies further down the delivery path.

These cannot be distinguished from source. `PrecisionCallbackInputChannel`
already maintains `unsolicitedCount` and `droppedCount`, but neither is surfaced
through composition, the owner facade, or the menu app, so the runtime cannot
report whether frames arrived and were rejected or never arrived at all. Closing
that diagnosability gap is the prerequisite for the next attempt; guessing at a
filter change without evidence would be a change to the input path of a device
writer, made blind.

Two further defects were confirmed:

- **No runtime-journal rotation exists.** A schema-v3 journal models exactly one
  apply/restore lifecycle. Once it reaches `completed`/`restoredVerified`,
  `validateAction` permits neither activate (`prepared`/`baselineVerified`) nor
  recover, so a second session is impossible without moving the file aside by
  hand. This was hit twice, and the second time surfaced only as
  `Bind failed: invalidIntent`, which says nothing about the cause. For an app
  intended to replace BetterTouchTool this is a hard blocker, not an
  inconvenience.
- **`Deactivate Precision…` stayed enabled after a verified restore**, the same
  admitted-versus-diverted conflation as the status label. Fixed.

The status-line fix from earlier in the day was confirmed on hardware: after the
verified restore the app reported `Precision restored to baseline; runtime still
admitted` rather than the previous incorrect `Precision diverted (active)`.
