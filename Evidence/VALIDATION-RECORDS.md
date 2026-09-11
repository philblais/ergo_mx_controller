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
2. The fault lies further down the delivery path — control-event decoding,
   intent resolution, or execution — and the filter is correct.

**Correction, same day.** This record originally cited the calibration panel as
evidence for the second candidate, on the grounds that it decodes through the
same `decodeNotification` and had "historically named Logitech controls". That
was not evidence and should not have been written here. Its only basis was a
hardware-validation *instruction* in the runbook and a capability bullet
describing what the code does — not an observation. No HID++ notification frame
has ever been captured by this project: every frame in this record is a request
or a response, all with device index `0x00`.

The first candidate therefore stands without a counterweight. It is still not
proven, and the filter must not be changed on that basis; the input diagnostics
added afterwards exist precisely to settle it with an observation.

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

### Read-only observation — 2026-09-04, ordinary HID button masks

Zero-risk observer-only session with BetterTouchTool and Logi Options quit. No
bind, no admission, no SET, no diversion. The calibration panel prints the raw
bytes of each report; controls were pressed one at a time with the buffer
cleared between presses.

| Control | Report | Result |
|---|---|---|
| Left click | `02 01 00 00 00 00 00 00` | ordinary, button mask `0x01` |
| Thumb button (first pressed) | `02 08 00 00 00 00 00 00` | ordinary, button mask `0x08` |
| Thumb button (second pressed) | `02 10 00 00 00 00 00 00` | ordinary, button mask `0x10` |
| Precision | *(no report at all)* | **no ordinary representation** |

Release in every case returned `02 00 00 00 00 00 00 00`. Vertical wheel motion
was observed separately through the existing wheel path.

**Not observed in this session:** right click, wheel click, wheel tilt left, and
wheel tilt right. The wheel tilt is the one that still matters architecturally.
Which thumb produced `0x08` and which produced `0x10` was inferred from press
order and is not independently confirmed; it decides which thumb receives which
action but changes nothing structural.

#### What this establishes

Both thumb buttons are ordinary HID buttons 4 and 5. macOS already delivers
them, and BetterTouchTool remaps them at the event layer rather than by
diverting anything — consistent with the 2026-08-27 baseline, which recorded all
nine reprogrammable controls at `flags 0000` while BetterTouchTool was in daily
use.

Precision produces no ordinary report. It is the one control on this device with
no representation outside HID++, which is why it required temporary diversion
and why that work was necessary.

The consequence for the mapped-control milestone is large. If wheel tilt also
proves ordinary, then **none** of the five mapped CIDs require HID++ diversion,
and the planned multi-CID SET path — a widened transport allowlist, per-CID
packet tables, multi-CID admission policy, a mapped lifecycle actor — would be
solving a problem this hardware does not have. Replacing BetterTouchTool for
those controls becomes an event-tap problem with no device write at all, which
is a categorically lower risk than anything attempted so far.

That conclusion is held open pending the wheel-tilt observation. Until then the
five mapped CIDs remain `notAuthorizedForExecution`, unchanged.

### Read-only observation — 2026-09-04, wheel tilt

Tilting the wheel left and right navigated a horizontal carousel in Safari in
the corresponding directions. macOS therefore receives signed horizontal scroll
deltas from this device with nothing diverted.

This agrees with the device's own control list: the enumeration found CIDs
`005B` and `005D`, which are Left Scroll and Right Scroll in Logitech's standard
numbering — a scroll axis, not buttons. It also fits `0053`/`0056` being Back and
Forward, the thumb buttons that reported masks `0x08` and `0x10`.

The observation rests on tilt-left and tilt-right producing opposite motion,
which a signed horizontal axis explains and a button press does not.

#### Complete picture for this device

| Control | CID | Ordinary representation |
|---|---|---|
| Left click | `0050` | button mask `0x01` (observed) |
| Right click | `0051` | button mask `0x02` (assumed, unobserved) |
| Wheel click | `0052` | button mask `0x04` (assumed, unobserved) |
| Thumb, back | `0053` | button mask `0x08` (observed) |
| Thumb, forward | `0056` | button mask `0x10` (observed) |
| Wheel tilt left | `005B` | horizontal scroll (observed) |
| Wheel tilt right | `005D` | horizontal scroll (observed) |
| **Precision** | **`00ED`** | **none — requires diversion** |

#### Consequence

**None of the five mapped CIDs require HID++ diversion.** Every one of them is
already delivered to macOS as an ordinary mouse button or scroll axis. The
planned multi-CID SET path — a widened transport allowlist, per-CID packet
tables, multi-CID admission policy, a mapped lifecycle actor — would have been
solving a problem this hardware does not have.

Precision remains the sole control with no ordinary representation, and the only
one that will ever need a SET. That runtime is built and proved.

Replacing BetterTouchTool for the other five is therefore an event-layer
problem: observe the ordinary reports, suppress the default behaviour, and post
replacements. It involves **no device write at all**, which is a categorically
lower risk than the path previously planned. It does need two things the project
does not yet have: an Accessibility (TCC) permission gate, and a horizontal
scroll path — the wheel observer currently decodes only vertical motion.

The existing mapped-control diversion plan, readiness audit, action plan, event
pump and GET-only preflight are superseded rather than wrong. They remain as
reviewed evidence and stay `notAuthorizedForExecution`.

### Live validation record — 2026-09-04, Precision audio works

The Precision audio path works on hardware. A quick tap mutes and unmutes;
holding Precision and scrolling changes the system volume; and the page
underneath does not scroll while Precision is held. This supersedes the finding
recorded earlier the same day that the audio path did not work.

Input evidence captured while diverted and active:

```text
observed 21 · notifications 18 · matched 3 · dropped 18
last frame  11 FF 0A 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
last press  11 FF 0A 00 00 ED 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

The press notification carries device index `0xFF`, feature index `0x0A`,
function `0x00` (`divertedButtonsEvent`) and control ID `00ED`. The release that
follows carries an all-zero payload. `Action preview` showed `Volume up ×2`, and
the audio panel reported a live system volume, so decoding, intent resolution
and execution all function.

Both permissions read granted: Input Monitoring and **Accessibility**.

#### Why the earlier session failed

Not established with certainty, and worth stating as such. The leading
explanation is the Accessibility grant. The scroll swallow uses a `CGEvent` tap
created with `.defaultTap`, which can suppress events, and a suppressing tap
requires Accessibility rather than Input Monitoring alone. If `tapCreate`
returned nil in the earlier session, the page would have scrolled while
Precision was held — exactly what was observed. The permission row that makes
this visible was added between the two sessions, so the grant plausibly happened
because the requirement finally became legible.

Two contributing factors are certain, because they were instruction errors
rather than defects. The tap threshold is 0.3 s, and the earlier session was run
under an instruction to press "slowly, with a clear pause" — a slow press is a
hold by design and emits no mute intent. In the session after that, the Audio
test was never enabled at all.

What is now certain is that the notification filter was never at fault. The
device does use device index `0xFF`, so the candidate raised earlier — that the
filter should have matched `0x00` — is disproven. The withdrawal of the
supposed counter-evidence for that candidate still stands: that reasoning was
unsound even though its conclusion happened to be right.

The diagnostics did their job. They converted an unfalsifiable argument between
two hypotheses into a frame of hex that settled it.

### Read-only observation — 2026-09-05, the wheel-tilt sign

**Question.** The event layer must decide which physical tilt a positive
`scrollWheelEventDeltaAxis2` means. It could not be reasoned out: the device
reports tilt as AC Pan on the Consumer page, macOS re-publishes it as a scroll
event, and that translation is affected by the "natural scrolling" preference.

**Conditions.** BetterTouchTool and Logi Options confirmed not running. Menu app
launched with Input Monitoring and Accessibility granted. The Precision runtime
was **not** bound; "Scroll axis diagnostics" reuses the same wheel observer in a
non-suppressing mode. No device was opened, no lease taken, no SET sent, nothing
suppressed, and no CGEvent posted. `com.apple.swipescrolldirection` read `0` at
the start of the session.

**Readings.**

| natural scrolling | tilt | AC Pan (IOHID) | CGEvent axis2 |
|---|---|---|---|
| off | left | `-1` | `+1` |
| off | right | `+1` | `-1` |
| on | left | `-1` | `-1` |
| on | right | `+1` | `+1` |

All four samples read `discrete`, distinguishing them from a trackpad's
continuous horizontal scroll.

**What this establishes.**

1. **The CGEvent sign is not a property of the trackball.** It inverts with the
   preference. A compiled-in constant would be correct under one setting and
   would silently reverse back and forward under the other. `HorizontalScrollConvention`
   is now derived from `com.apple.swipescrolldirection` rather than fixed, and
   `EventSynthesisTap.setConvention` exists so a change while the tap is running
   can be applied without restarting it.

2. **The AC Pan sign is invariant, and matches the HID specification.** Left is
   `-1` and right is `+1` under both settings. The `MXErgoObservation.horizontalScroll`
   comment claiming "positive to the right" was previously a spec claim; it is
   now an observation.

3. The value previously compiled in as `HorizontalScrollConvention.assumed`
   — positive means left — was right, but only for natural scrolling off, and
   only by luck. It was recorded as unverified, and that was the correct
   description of it.

**What this does not establish.** Nothing about device attribution. A second
mouse's tilt wheel would produce the same discrete horizontal scroll and would
be remapped identically. The AC Pan stream *is* attributed to this MX Ergo and
is preference-invariant, so correlating the two streams is the eventual answer
to that; it was not built here.

### Correction — 2026-09-05, an unsupported claim about the wheel click

`EventSynthesisPlan` carried the comment "HID button masks observed on this MX
Ergo on 2026-09-04: wheel click `0x04`, lower thumb `0x08`, upper thumb `0x10`".

The thumb masks were observed. **The wheel click was not.** The 2026-09-04
record lists "right click, wheel click, wheel tilt left, and wheel tilt right"
under *Not observed in this session*. The value `0x04` was inferred from
`StandardMouseButton.wheel` in `MXErgoCore`, which is a specification assumption
about how a three-button mouse reports, not a measurement of this trackball.

The claim is withdrawn. The constant stays at `2`, now labelled as inferred.

This is the second unsupported claim written into this project's audit trail by
the same author, after the calibration-panel claim withdrawn on 2026-09-04. Both
took the same shape: a plausible inference recorded in the voice of an
observation, with a date attached that made it look sourced.

It also has a concrete consequence, which is why it surfaced. Wheel click did
not open Mission Control on the first two live runs of the event layer, and a
binding keyed on a button number this device may never emit would produce
exactly that: the tap sees the event, finds no binding for it, and passes it
through untouched.

### Live validation record — 2026-09-05, why the event layer's chords did nothing

**Conditions.** BetterTouchTool and Logi Options quit. Event layer enabled. No
device write, no lease, no SET; the trackball is untouched throughout.

**Counters, after eleven wheel clicks:**
`observed 2498 · passed 2476 · suppressed 22 · posted 11 · own 0`

`suppressed` is exactly twice `posted` — one press, one release, one chord — so
the wheel click was seen, matched, suppressed, and a chord was posted every
time. `own 0` is correct rather than a fault: chords are keyboard events, and
keyboard events are not in the tap's mask, so it never sees its own.

**Calibration panel:** `#8,245 Wheel click down (mask 0x04)`. The constant
inferred on 2026-09-05 was right; it was still an inference when it was written
down as an observation.

**Confound found:** this machine has exactly one Space, so Control+Left and
Control+Right cannot switch desktops regardless of the code. Neither thumb
button was ever evidence of anything.

**The discriminating test.** A real Control+Up opens Mission Control. Two
buttons then posted the same chord from the main thread instead of from inside
the tap callback:

| | posted | result |
|---|---|---|
| A | Control+Up exactly as the tap builds it | **Mission Control opened** |
| B | the same plus the numeric-pad and secondary-function flags a real arrow key carries | **nothing** |

**What this establishes.** The chord was always correct. The window server drops
an event posted from *inside* an event-tap callback, and that alone is why five
remapped controls did nothing.

**What it also establishes, and matters more.** B disproves the fix that was
about to be shipped. Adding a real arrow key's flags does not help; it *breaks*
a chord that otherwise works. Two speculative fixes had already been committed
for this failure without a measurement — a modifier-transition change and,
before it, an inferred button mask. Building the measurement instead took one
session and settled it in one press.

The modifier-transition change stays: a chord that never presses its modifier is
wrong regardless, and A confirms the current form works. Whether it was ever
necessary is not established, and is recorded here as unknown rather than
claimed either way.

### Correction — 2026-09-05, the A/B chord result did not reproduce

The record above states that posting Control+Up "exactly as the tap builds it"
opened Mission Control while the variant carrying a real arrow key's keypad
flags did nothing. Repeating the same two buttons produced the **opposite**
result: A did nothing, B opened Mission Control.

The result is therefore not reproduced, and every conclusion drawn from it is
withdrawn:

* That the keypad-flag variant is broken. Not established.
* That B "disproves" the flag hypothesis. It does not; nothing here decides it
  either way.

The likely confounder is that **Mission Control is a toggle**. If both chords
work, the first press opens it and the second closes it, and "closed" reads as
"nothing happened" depending on what the screen showed beforehand. That single
explanation fits both runs with both chords working, which no other candidate
does.

The measurement was badly designed for this reason: its observable is a state
that the act of measuring flips. A trial whose outcome depends on an unrecorded
starting state should not have been reported as a finding after one run.

**What survives.** That a real Control+Up opens Mission Control on this machine
is unaffected. That the wheel click is observed, matched and suppressed, and a
chord posted, is unaffected — it rests on the counters, not on A/B.

**What does not.** The claim that posting from inside the tap callback is *the*
cause. Deferring delivery until after the callback returns remains correct on
its own grounds — posting into the tap point being serviced is a documented
hazard, and the fail-open behaviour is unchanged by it — but it is no longer
supported by this evidence, and it is not known whether it fixes the failure.
That is settled by one thing only: whether wheel click now opens Mission
Control.

### Resolution — 2026-09-05, the chord needs a real arrow key's flags

The two A/B runs above disagreed. Asked which stood, the operator confirmed the
**second**: chord A, Control+Up as the tap built it, does nothing; chord B, the
same chord carrying the numeric-pad and secondary-function flags, opens Mission
Control.

So the toggle explanation offered for the disagreement — that both chords work
and the observable simply flips — is **wrong**, and is withdrawn in turn. It was
a plausible reconciliation of two conflicting reports, not an observation, and
it should have been offered as a question rather than written into the record as
the likely cause.

**The finding.** A synthetic arrow key must carry the flags a real one does.
macOS reaches the arrows through Fn and reports them in the keypad group, so a
real Control+Up carries the numeric-pad and secondary-function flags alongside
Control. The window server's hotkey matcher evidently requires them; a chord
with Control alone is ignored.

This affected all three chords in the plan, since all three are arrows — wheel
click to Control+Up, and both thumbs to Control+Left and Control+Right. Neither
thumb could have worked either, and on this machine, with one Space, that would
have gone unnoticed.

`SyntheticKeyChordPlanner` now derives the flags from the key code rather than
taking them from the plan, because they are a property of the key and not
something a person presses. A test asserts all four arrows carry them and that
an ordinary key does not.

**Still unknown.** Whether deferring delivery until after the tap callback
returns was ever necessary. Chord A failed when posted from a button, entirely
outside any callback, so the flags alone explain the whole failure and the
deferral explains nothing that needs explaining. It stays because posting into
the tap point being serviced is a documented hazard and the split costs nothing,
but it is not a fix for this and is not recorded as one.

**Not yet established.** Whether wheel click now opens Mission Control through
the tap. Nothing above shows that; only pressing it does.

### Live validation record — 2026-09-05, the event layer works

**Conditions.** BetterTouchTool and Logi Options quit. Two Spaces created, so
the desktop shortcuts have somewhere to go. Event layer enabled from the menu.
No device write, no lease, no SET; the trackball is untouched.

| Control | Injected | Result |
|---|---|---|
| Wheel click | Control+Up | **Mission Control opens** |
| Lower thumb | Control+Right | **switches Space** |
| Upper thumb | Control+Left | **switches Space** |
| Wheel tilt left | mouse button 4 | **Back**, in Chrome and Brave |
| Wheel tilt right | mouse button 5 | **Forward**, in Chrome and Brave |
| Wheel tilt, either | — | **nothing in Safari** |

**What this establishes.** The layer works end to end. Physical tilt exercises
four things the diagnostic buttons deliberately skip — the observation, the
direction decoding, the latch, and the loop-prevention marker — and all four
work.

The marker is the one worth naming. The click injected for a tilt lands on
buttons 3 and 4, which are the thumb buttons' own triggers, so a marker failure
would not be quiet: a tilt would switch Spaces instead of navigating. It did
not. That code had never run before this session.

**Safari.** Not a defect in the layer; the cost of a substitution recorded when
it was made. The 2026-08-25 BetterTouchTool preset in this repository shows its
Back and Forward were `3F Swipe Left (Page Back)` and `3F Swipe Right (Page
Forward)` — the system gesture, which every application honours. macOS exposes
no public gesture synthesis, so the reviewed substitution was the pair of mouse
buttons the system already reads as back and forward. Chrome and Brave honour
them. Safari does not.

Safari does honour Command+Left and Command+Right, so the plan now carries a
keyboard alternative used only for applications that ignore the buttons. Arrow
keys rather than Command+bracket, because a bracket's key code moves with the
keyboard layout and an arrow's does not.

**Verified on hardware the same day: tilt navigates in Safari.** All five
controls now work across Chrome, Brave and Safari. The frontmost-application
switch is exercised in both directions — the same physical tilt produces a mouse
button in one browser and a chord in another — and nothing regressed where the
buttons already worked.

**The thumb discrepancy is closed.** The same preset labels a trigger "Desktop
Left" whose action is `Move Right a Space`, which left it unclear whether the
buttons were the way round the operator wanted — and the 2026-09-04 record had
already noted that which thumb reports `0x08` and which reports `0x10` was
inferred from press order rather than observed.

Confirmed on hardware 2026-09-05: **both thumbs switch the intended way.** The
press-order inference was correct, and the preset's label is simply
inconsistent with its own action. Nothing needs changing.

That also settles, retroactively, which thumb is which: the button reporting
`0x08` is the lower thumb and `0x10` the upper, since the bindings derived from
that assumption behave as intended.

### Live validation record — 2026-09-05, the daily-driver chain across a reboot

**Conditions.** Release build installed at `/Applications/MX Ergo Controller.app`,
signed, hardened runtime, designated requirement satisfied. Accessibility and
Input Monitoring granted to that copy. Launch at login registered. The machine
was then restarted.

**Observed after the restart**, with the operator having opened nothing:

| Check | Result |
|---|---|
| Uptime at time of check | 3 minutes — a real reboot |
| App process | running from `/Applications`, PID 876, started at login |
| Remembered preference | `com.phib.MXErgoController.eventLayerEnabled` = `1` |
| `EventSynthesis` thread | **present** |

**What this establishes.** The whole unattended chain: the login item launches
the app, the remembered preference survives a reboot, the Accessibility grant
survives a reboot for the `/Applications` copy, and the layer arms itself
without anyone opening the menu. The `EventSynthesis` thread exists only after
`CGEvent.tapCreate` has returned a tap, and that call fails without
Accessibility, so its presence is evidence of the grant as well as the arming.

**What it does not establish.** That events flow. A created tap is not a
delivered event, and nothing here presses a button. The operator reported the
app restarting with the machine; the arming was verified separately by sampling
the process, not by pressing anything.

**The low process id is incidental but consistent** with launching at login
rather than being started by hand afterwards.

### Read-only observation — 2026-09-06, Precision emits nothing over ordinary HID

**Question.** The 2026-08-25 BetterTouchTool preset triggers all three Precision
bindings as `BTTTriggerTypeNormalMouse`, described as **Button 12**. If macOS
delivers Precision as an ordinary mouse button it needs no HID++ diversion, the
event layer could hold it permanently, and it would survive a reboot.

**Conditions.** `/Applications` Release build, relaunched and verified by start
time against the binary's build time. Both loops confirmed running by sampling
threads: `InputLoop` for raw HID, `EventSynthesis` for the tap. Unfiltered
logging: **every** report written, not only those whose button mask changed.
No device write, no lease, no SET.

**Readings.**

| | |
|---|---|
| Log opened | 12:00:56 |
| Precision pressed 5–6 times, ball still | 12:00:56 → 12:01:40 |
| **First report the observer ever received** | **`#1` at 12:01:40** — the first ball movement |
| Ball moved | 12:01:40 → 12:02:21, reaching report `#651` |
| Byte 1 (buttons 1–8) values seen | `00`, `01` |
| **Byte 2 (buttons 9–16) values seen** | **`00` only** |
| Tap `buttons seen` | `3, 4, 5` — never grew |

**What this establishes.** Precision produces **no HID report at all**. The
observer's own counter began at `#1` during the ball movement, so nothing
arrived during the press window; and the movement that followed produced 651
reports, which proves the observer and the logger were working. That is the
control the previous two attempts lacked.

Buttons 9 to 16 live in byte 2, which is `00` in all 97 sampled reports. A
button 12 would have set it. The tap, whose mask admits `otherMouseDown` for
every button number, never saw a fourth button either.

**So the "Button 12" hypothesis is disproven**, and the 2026-09-04 finding
stands after all: Precision is the one control on this device with no
representation outside HID++. The diversion runtime was necessary, and remains
the only thing that has ever written to this trackball.

**Residual uncertainty, stated rather than hidden.** A BLE device can sleep, and
a wake latency could swallow a first press. That would not account for five or
six presses across a 44-second window, and it does not explain byte 2 never
being set — but it is why this is recorded as strong evidence rather than proof.

**What it does not explain.** How BetterTouchTool drove Precision without
diverting. The same preset carries an "MX Ergo device access" entry
(`BTTTriggerType` 1324), which suggests BTT opened the device directly rather
than relying on ordinary HID. The 2026-08-27 baseline recorded all nine controls
at `flags 0000` while BTT was in daily use, so either BTT diverts and restores
around each use, or it reads the vendor interface by some other means. Not
investigated, and not needed: this app already has a working path.

### Installed-app launch/status observation — 2026-09-09

At approximately 15:39 PDT, the Release built from `d75919d` was opened from
`/Applications/MX Ergo Controller.app` on macOS 26.6.2 (25G83). Its executable
SHA-256 is `f23c7f794e05208bc58892ed5bf79511dd4db95ac9edba4c5e5e3c3f29afd105`.
The signature had verified, and the same source passed all 517 tests in normal
parallel verification plus the signed builds and audits.

The user confirmed BetterTouchTool/Logitech software was uninstalled or not
running, had switched the trackball off and on, and accepted the same mappings
on other mice. The prelaunch process check found no controller or matching
competitor. The method of quitting the former Xcode copy was not observed.
After launch there was exactly one controller: PID 97686 at the installed path.

The native accessibility tree and window image showed Controls open, MX Ergo
connected, Input Monitoring granted, Accessibility granted, Button remapping
On/Active, Launch at login On, and Precision audio Inactive. Expanded actions
listed wheel click → Mission Control, lower thumb → Desktop right, upper thumb
→ Desktop left, left tilt → Back, right tilt → Forward. This establishes the
displayed status and mappings only; no physical action or login result is
claimed. Permission and remapping settings were not changed by the task.

The five protected record hashes and runtime journal matched before and after
launch. Baseline remains `60ab614927d20871994ad0ebe7368158af9a26b2c1d60f7a2ab3c51635f77097`;
runtime remains `fec5d33366c243242a845595cacae8100dc42e8ba94eb5f0846a6993604e06b3`.
No archive, Precision activation, restore, recovery, or explicit HID++ query was
invoked. The observer was running; no request/response transcript was captured.

Window-close/reopen is not marked passed: an automated close followed by a
status read showed a window again, but tool reactivation could account for it.
Manual close/reopen, five physical controls, coexistence, preference persistence,
login, Precision use/restoration, and working-week acceptance remain pending.

### User-reported ordinary-control acceptance — 2026-09-09

At approximately 15:42 PDT, the user reported “All the tests passed” in response
to the five-control checklist for the installed `d75919d` Release candidate
identified above. This records wheel click → Mission Control, lower thumb →
desktop right, upper thumb → desktop left, left tilt → browser Back, and right
tilt → browser Forward as passed by user report. The question also asked whether
each action occurred once per press and normal clicking and scrolling still
worked; those checks are included in the user's confirmation.

These are user-reported physical results, not synthetic input or independently
captured event traces. They do not establish login behavior, preference
persistence, manual close/reopen, trackpad gestures, behavior on another mouse,
or Precision audio. Global mapping scope was accepted earlier, but other-mouse
behavior itself was not separately reported. Precision was last observed
inactive and the instructions kept it inactive; no activation or restoration
was requested in this checklist.

### Window/relaunch acceptance and inactive Precision review — 2026-09-09

At approximately 15:49 PDT, the user reported “All good” for closing/reopening
via the menu-bar Open command, closing/reopening from Applications, and normal
Quit/relaunch with Button remapping still On and wheel click working. These
three scenarios pass by user report for the installed candidate above.
Remembered Off and login/restart behavior were not part of this checklist.

The user also reported Precision tap/hold-and-scroll not working. A fresh UI
inspection showed Precision audio Inactive and a completed session record
blocking new preparation. This is consistent with the requested inactive
test state; it is not an observed failure of activated Precision audio.

The archive review was opened but not confirmed. It displayed transaction
`2DF3478B-776F-4846-BD39-FF6825B27B77`, revision 6, status completed, Precision
restoredVerified, and stated that archiving preserves a backup without changing
device settings or the recovery baseline. This is a review of saved state,
not a fresh physical observation. No archive, preparation query, activation,
restore, or recovery was executed by the task in this step. Precision activation
and functional acceptance remain pending.

### Completed-session archive observed — 2026-09-09

At approximately 15:56 PDT, following the user's request to continue the
reviewed next step, the app's Archive completed record confirmation was used
for transaction `2DF3478B-776F-4846-BD39-FF6825B27B77`, revision 6. Before
confirmation, the active record and five protected files matched their saved
hashes. After confirmation, the UI reported the completed record archived and
advanced to Check device support, step 1 of 7; Precision audio remained inactive.

The active `precision-runtime-v3.json` path is now absent. Its exact bytes are
preserved in Application Support as
`precision-runtime-v3.completed-2DF3478B-776F-4846-BD39-FF6825B27B77.json`, SHA-256
`fec5d33366c243242a845595cacae8100dc42e8ba94eb5f0846a6993604e06b3`.
All five protected files are unchanged. The supported app operation was used;
no journal bytes were rewritten manually. The Check device support confirmation
was opened but not executed. No new preparation query, Precision SET, restore,
or recovery was issued in this step; physical Precision acceptance remains open.

### User preparation blocked by AppKit helper classification — 2026-09-09

After the user reported completing the preparation steps, Controls showed
readiness locked by `ThemeWidgetControlViewService (MX Ergo Controller)`.
Advanced showed no runtime owner, Precision inactive, a successful firmware
fingerprint read (three entities, feature v2), and a live Precision preflight
matching the saved baseline. Preparation did not reach a bound or activated
session. The installed executable was still the `d75919d` candidate.

The observed Root request/response displayed in Advanced were:

```text
REQUEST  11 00 00 0E 1B 04 00 00 00 00 00 00 00 00 00 00 00 00 00
RESPONSE 11 00 00 0E 0A 00 03 00 00 00 00 00 00 00 00 00 00 00 00
```

The displayed live Precision GET request/response were:

```text
REQUEST  11 00 0A 2E 00 ED 00 00 00 00 00 00 00 00 00 00 00 00 00
RESPONSE 11 00 0A 2E 00 ED 00 00 00 00 00 00 00 00 00 00 00 00 00
```

The UI reported flags 0000 and map 0000. These values were captured from the
app's displayed results of the user's preparation, not from a separately
issued query. Firmware discovery's individual wire frames were not captured,
so a complete preparation transcript is not claimed. Offline restore previews
and the isolated self-test shown in Advanced are not evidence of a live SET.

Read-only process inspection identified PID 98322 as bundle
`com.apple.appkit.xpc.ThemeWidgetControlViewService`, executable
`/System/Library/Frameworks/AppKit.framework/Versions/C/XPCServices/ThemeWidgetControlViewService.xpc/Contents/MacOS/ThemeWidgetControlViewService`.
Its signature verified with macOS Software Signing and Apple Root CA. The
classifier currently matches the host app name embedded in the helper's
localized title, producing a false competitor. The real controller was PID
98168 at the installed Applications path. No process was terminated to bypass
the gate. The five protected files and completed runtime backup remain
unchanged; no active runtime journal exists. No Precision SET was invoked in
this investigation. The classifier fix and renewed preparation are pending.

### Corrected helper classification candidate installed — 2026-09-09

At approximately 22:19 PDT, the corrected Release was installed and launched
after the previous controller quit normally. Immediately before replacement,
the old UI showed Precision inactive and no runtime owner; earlier preparation
had also been invalidated by a disconnect. No prepared or admitted session was
carried into the new app. The new executable SHA-256 is
`119f6dd069c6b8ee9eeb6b9fddf8d27daabed586c29d37d6e8e5b18358916036`, code-directory
hash `3b574e4201ebd7770b56c6033324aa9905a8276f`. Its signature verifies, all 521
tests and the signed-build/audit workflow passed, and Release passed with Swift
warnings treated as errors.

Exactly one installed controller was running, PID 20188 at
`/Applications/MX Ergo Controller.app/Contents/MacOS/MX Ergo Controller`.
Controls displayed the MX Ergo connected, both permissions granted, ordinary
remapping On/Active, Precision audio Inactive, and Check device support (step
1 of 7). No new preparation query or activation was invoked after launch.

A read-only probe executing the exact canonical classifier against native
process snapshots matched the actual reported AppKit helper when executable
identity was omitted, excluded it with the verified system identity, and found
no remaining competitors after restart. This verifies the classification
change, not a completed readiness or activation session in the new app.

All installed bundle files match `build/validation-119f6dd0/MX Ergo Controller.app`.
The previous installed app remains preserved in
`build/verification-deterministic-timing-f23c7f79/`. All five protected records
and the completed runtime backup match their previous hashes, and the active
runtime journal is absent. Earlier ordinary-control acceptance belongs to its
named previous build; fresh Precision preparation/use/restoration remain
pending. No live Precision SET was run.

### Live validation record — 2026-09-09, Precision acceptance at 23:04 PDT

Following the seven-step preparation and explicit activation/restoration handoff,
the user reported: “The tests seem to have worked,” with the exception that no
volume slider/dialog appeared. This is a qualified user report for the requested
tap-mute, hold-scroll volume, release-to-scroll, and ordinary-control checks;
individual event traces or separately confirmed per-action results were not
captured. The supplied `Screenshot 2026-09-09 at 23.04.26.png` shows **Precision
audio: Inactive · button restored** and says the session still owns the connection.
Normal quit after restoration has not yet been observed.

The live runtime record is transaction `EDE55625-533B-4DF1-B8E0-73A0E3ACF51A`,
revision 6, status `completed`, with Precision phase `restoredVerified`.
It records exactly one apply and one restore attempt, both `verified`, with
IO return 0 and correlated non-echo responses. Actual retained SET evidence:

```text
APPLY REQUEST    11 00 0A 3E 00 ED 03 00 00 00 00 00 00 00 00 00 00 00 00 00
APPLY RESPONSE   11 00 0A 3E 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
RESTORE REQUEST  11 00 0A 3E 00 ED 02 00 00 00 00 00 00 00 00 00 00 00 00 00
RESTORE RESPONSE 11 00 0A 3E 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

The separately retained applied observation parameters are
`00 ED 01 00 00 00 00 00 00 00 00 00 00 00 00 00`; restored observation
parameters are `00 ED 00 00 00 00 00 00 00 00 00 00 00 00 00 00`, matching the
baseline. Full GET wire frames were not retained in this record and are not
reconstructed here. SET acknowledgements alone are not treated as proof.

A byte-for-byte copy is preserved in
`Evidence/2026-09-09-precision-acceptance-EDE55625/precision-runtime-v3.json`,
SHA-256 `48bfd6be5cfa287a928e5c5be970ba914afc52e4c5188755768931ad8cbd2cbb`.
The live record was not moved or rewritten. All five protected records and the
previous `2DF3478B-776F-4846-BD39-FF6825B27B77` completed backup retain their
previous hashes, including baseline `60ab6149…f77097`. No device operation was
invoked by the agent while recording these results.

Source inspection confirms the missing popup is an unimplemented presentation
feature: `SmoothSystemAudioController` changes Core Audio properties and emits
status updates; the current view displays those as text in Advanced. There is
no volume overlay. The next UI improvement is transient volume/mute feedback
with the reported percentage and a level indicator. Hardware acceptance is
still partial; this session does not establish login, repeated-session, or
working-week reliability.

### Volume feedback candidate installed — 2026-09-09

The app now has transient volume/mute feedback using the existing audio status
updates. Final candidate executable SHA-256:
`44a84c4513c8f2480c613af43b92a40e9a063dce6393f32845ccc69acd2c8a70`.
All 521 package tests, four signed builds, and audits passed; Release passed
with Swift warnings treated as errors. Isolated presentation checks and
rendered light/dark samples passed inspection. This is simulated UI evidence;
live Precision popup acceptance on this candidate remains pending.

Before replacement, native UI showed Precision inactive and the button
restored. The app quit normally. Its previous bundle was preserved under
`build/volume-feedback-44a84c45/Previous MX Ergo Controller.app`. Installed
files match the retained final candidate and its signature verifies. Relaunch
was observed at PID 25166 from `/Applications/MX Ergo Controller.app`, with
the MX Ergo connected, both permissions granted, ordinary remapping active,
Precision inactive, and **Archive completed session…** available. No reservation
or activation was requested after relaunch.

All twelve JSON files match the pre-update snapshot retained in
`build/volume-feedback-44a84c45/mx-ergo-volume-before-install.json`, including
the five protected records, earlier archives, and the active-path completed
`EDE55625-533B-4DF1-B8E0-73A0E3ACF51A` record with hash `48bfd6be…cbd2cbb`.
No journal was archived or rewritten during the update. No explicit live HID
query or SET was invoked by the agent. Physical checks still require a fresh
user-led archive/preparation/activation sequence and verified restoration.

### Live validation record — 2026-09-10, preference persistence at 05:40 PDT

The installed executable still matches the volume-feedback candidate
`44a84c4513c8f2480c613af43b92a40e9a063dce6393f32845ccc69acd2c8a70`
(source `b0bdf27`). Initial native UI showed remapping On/Active, Precision
Inactive, both permissions granted, Launch at login On, and **Waiting for
MX Ergo**. The completed `EDE55625-533B-4DF1-B8E0-73A0E3ACF51A` record
remained revision 6, completed/restoredVerified.

Using the app's ordinary controls, remapping was switched Off and the app quit
normally. A read-only process check confirmed the installed process exited.
Reopening the installed app showed remapping Off. Remapping was then switched
On, the app quit normally again, and process absence was verified before
reopening. The final UI showed On/Active without further intervention.
The original On preference is restored; Launch at login was not changed.

This establishes both saved-preference UI outcomes across normal quit/relaunch.
The trackball was not connected, so native physical-button behavior while Off,
ordinary controls while On, and the new popup's physical behavior remain
unverified on this candidate. It does not establish logout/login or reboot
behavior. The user's popup-test result has been requested and is not yet known.

All twelve JSON files retain their pre-check hashes, including the five
protected records and the completed runtime record. No archive, preparation,
activation, restoration, permission change, live HID query, or SET was invoked.
No code changed; the existing 521-test verification remains the build evidence.

### Live validation record — 2026-09-10, active popup-test session at 07:53 PDT

Native UI now shows MX Ergo connected, both permissions granted, ordinary
remapping On/Active, Precision audio Active, Execute mute and volume On, and
audio status Volume 47%. The agent did not prepare or activate this session.
The user's visual popup result has been requested but not yet received;
displayed audio status alone does not establish that either popup appeared.

The previous completed `EDE55625-533B-4DF1-B8E0-73A0E3ACF51A` record is now
archived with its original hash `48bfd6be…cbd2cbb`. All five protected records
still match their recorded hashes. The new runtime transaction is
`1CF6DBCD-2BAD-4576-A67E-CF25443A0ABC`, revision 3, running, Precision
`appliedVerified`. It retains one verified apply, IO return 0, with:

```text
APPLY REQUEST   11 00 0A 3E 00 ED 03 00 00 00 00 00 00 00 00 00 00 00 00 00
APPLY RESPONSE  11 00 0A 3E 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

Retained applied observation parameters are
`00 ED 01 00 00 00 00 00 00 00 00 00 00 00 00 00`. Full verification GET
frames are not retained in this record and are not reconstructed. No restore
attempt is present at this observation. The runtime snapshot is preserved at
`Evidence/2026-09-10-precision-popup-1CF6DBCD/precision-runtime-v3.revision-3.json`,
SHA-256 `e89a22b1d18ace7db480be2b0430813c3fd4db1d118db340f3b48d601ee5be59`.
This snapshot is evidence of a running session, not a backup to restore into
the live location. The live file and app state were left unchanged.

User-led popup confirmation and verified restoration are still pending. Do not
quit, replace the app, or begin login/reboot acceptance from this active state.
No HID query, SET, app shutdown, or preference change was invoked by the agent
during this observation and documentation work.

### Live validation record — 2026-09-10, popup acceptance at 08:48 PDT

The user answered “It's all working” after the volume/mute popup check and
restoration instructions. Record both popups as passed by user report on the
installed `b0bdf27` candidate (`44a84c45…d2c8a70`, executable hash rechecked).
Native UI shows MX Ergo connected, remapping On/Active, both permissions
granted, Launch at login On, and **Precision audio: Inactive · button restored**.
The completed session still owns the connection; the agent did not quit it.

The previously observed `1CF6DBCD-2BAD-4576-A67E-CF25443A0ABC` session is now
archived at revision 6, completed/restoredVerified. A subsequent session,
`DAB53017-16F6-40FC-BA5B-B2536FF8110D`, occupies the live runtime path, also
revision 6, completed/restoredVerified. Each records exactly one verified apply
and one verified restore. Both retain these request/response pairs:

```text
APPLY REQUEST    11 00 0A 3E 00 ED 03 00 00 00 00 00 00 00 00 00 00 00 00 00
APPLY RESPONSE   11 00 0A 3E 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
RESTORE REQUEST  11 00 0A 3E 00 ED 02 00 00 00 00 00 00 00 00 00 00 00 00 00
RESTORE RESPONSE 11 00 0A 3E 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

The current record's restored observation is
`00 ED 00 00 00 00 00 00 00 00 00 00 00 00 00 00`, matching the baseline.
Full GET wire frames are not reconstructed from the stored parameters.
Copies of both completed records are preserved under
`Evidence/2026-09-10-precision-popup-completed/`:

- `precision-runtime-v3.completed-1CF6DBCD-2BAD-4576-A67E-CF25443A0ABC.json`:
  `b0cd604517bdcfd870723e745ce4cd9c1e4dad1dc1a6ae7db544a4eab564f1c5`.
- `precision-runtime-v3.json` (DAB53017):
  `e88605d773bf6c7bb38337c52d5e83e8feaf1c70ae479e3a174ed02118b5981c`.

All five protected records are unchanged. The agent only inspected and copied
evidence; no live record was moved or rewritten, and no HID query or SET was
invoked. These results support popup acceptance and repeated completed-session
evidence, not login/reboot, every coexistence scenario, or a completed working
week. Those gates remain pending.

### Live validation record — 2026-09-10, reboot with remapping On

The user reported rebooting the Mac and asked to continue testing. Before any
native UI selection that could open the controller, a read-only process check
found PID 898 at `/Applications/MX Ergo Controller.app/Contents/MacOS/MX Ergo Controller`,
started 16:37:06 PDT. System boot time was 16:35:06 PDT. Thus the installed app
was already running after reboot before the agent opened its window. The
process timestamp alone does not distinguish login-item launch from macOS app
restoration or a prior user launch. The installed executable remains
`44a84c4513c8f2480c613af43b92a40e9a063dce6393f32845ccc69acd2c8a70`.

Subsequent native UI inspection showed MX Ergo connected, Input Monitoring and
Accessibility granted, Button remapping On/Active, Launch at login On, and
Precision audio Inactive. The completed session remains available to archive;
no new preparation or activation was requested. The inspection may open the
controller window and cannot establish whether the window appeared at sign-in.
The user has been asked about the initial window and the five physical actions;
those results are pending.

At 16:39 PDT, all five protected records match the pinned evidence fixtures,
and the completed DAB53017 runtime still hashes to
`e88605d773bf6c7bb38337c52d5e83e8feaf1c70ae479e3a174ed02118b5981c`.
No app restart, preference change, archive, HID query, or SET was invoked by the
agent. This establishes the observed post-reboot process and settings state,
not full quiet-login/physical-action acceptance. The login test with remapping
Off remains unrun. No code changed; build verification remains 521 passing tests.

### User confirmation — reboot availability and ordinary controls

The user reports: “The app was available at restart and all the buttons (with
the exception of precision were working)”. On the current `b0bdf27` candidate,
record post-reboot app availability and the five ordinary mapped actions as
passed by user report. The prior UI inspection independently showed remapping
On and Precision Inactive. Precision requires explicit per-session activation;
its reported lack of response here is expected for that inactive state, not
evidence of a failed activated Precision session.

The user did not explicitly confirm that the controller window stayed closed
at sign-in, so quiet menu-only presentation remains unconfirmed. Login with
remapping Off, remaining coexistence scenarios, and sustained-use acceptance
remain pending. No application, preference, or device-record change was made
while recording this report, and no live HID operation was invoked.

### User confirmation — login with remapping Off

After the initial logout/login availability report, the user clarified that
remapping had been left On. That report was not counted as an Off-setting test.
The user was then instructed to turn Button remapping Off, leave Launch at
login On, log out and back in, and check the saved setting before restoring On.

The user reports: “Remapping button is still OFF, I just reenabled it to be ON”.
Record Off-setting persistence through logout/login as passed by user report,
and the final On preference as restored by the user. Together with the preceding
On-setting reboot results, both saved-setting login outcomes are now covered.
This report confirms the switch state, not independent physical native-button
behavior while Off or quiet menu-only presentation at sign-in.

The accepted candidate remains the documented `b0bdf27` build; no new binary was
installed in this exchange. Sleep/wake, remaining coexistence scenarios, quiet
presentation, and sustained-use acceptance remain pending. No code or live
device record was changed by the agent, and no HID operation was invoked while
recording the user's report. Device hashes were not remeasured in this exchange.

### User confirmation — ordinary sleep/wake

Following the instruction to leave Precision inactive, sleep and wake the Mac,
and check reconnection plus the five ordinary mapped controls, the user replied
“All good”. Record that bounded sleep/wake sequence as passed by user report
on the current documented candidate. Sleep duration, individual event traces,
and live device-record hashes were not captured in this exchange.

This does not establish sleep/wake while Precision is active, a separate device
power cycle, every trackpad/other-mouse or browser variation, quiet login-window
behavior, or a completed working week. Those remaining scenarios retain their
status. No code, installed app, preference, or live device record was changed
by the agent, and no HID operation was invoked while recording this result.

### Resource baseline — 2026-09-10, 18:29–18:30 PDT

The installed `b0bdf27` candidate was sampled without opening its window,
restarting it, changing settings, or generating input. Four process snapshots
20 seconds apart covered 60.126 seconds at PID 5765. The executable hash
remains `44a84c4513c8f2480c613af43b92a40e9a063dce6393f32845ccc69acd2c8a70`.

| Measure | Observed result |
|---|---|
| CPU time consumed | 0.03 seconds over 60.126 seconds |
| Average CPU, one core = 100% | Approximately 0.05% |
| Resident memory | 120,240 KiB (117.42 MiB) at all four snapshots |
| Diagnostic file size | 95,988 bytes at all four snapshots |
| Process restart | None during the sample |

This was a quiet/idle interval, not an imposed workload. No memory or file-size
growth was observed during it. This does not establish absence of memory leaks,
active-input or active-Precision performance, log rotation under load, or
multi-day stability. Before this interval a single process snapshot reported
5.7% CPU; it was not a sustained-load measurement and is not combined with the
sample average.

Source review confirms the existing diagnostic file cap of 512 KiB and pending
payload/entry limits of 512 KiB and 1,024 entries. Overflow handling and file
wrapping already have automated coverage in the verified 521-test candidate.
The live sample did not reach those limits. Ordinary non-vendor reports without
button transitions are throttled to 0.1-second UI emissions; button transitions
and vendor replies retain their existing separate handling.

Raw counters are retained in
`Evidence/2026-09-10-resource-sample/mx-ergo-resource-sample.json`.
No code or installed bundle changed, no live device record was written, and no
HID query or SET was invoked. No additional test suite run was needed for this
read-only measurement. Active-use and working-week acceptance remain open.
