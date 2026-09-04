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
