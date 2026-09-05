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

**One discrepancy, unresolved.** The same preset labels a trigger "Desktop Left"
whose action is `Move Right a Space`. Whether the thumb buttons are the way
round the operator wants is therefore not established by the preset, and the
2026-09-04 record already noted that which thumb is `0x08` and which is `0x10`
was inferred from press order. Both thumbs switch Spaces; whether each switches
the intended way is for the operator to say.
