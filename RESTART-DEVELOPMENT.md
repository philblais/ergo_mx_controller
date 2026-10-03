# Automatic Precision restarts — September 11, 2026

The user authorized automatic Precision mute and hold-scroll volume across app
and Mac restarts. **Start Precision automatically** is a visible, persistent
opt-in in Controls. It defaults off. Enabling it on a fresh observer starts one
checked flow; enabling it after manual preparation remembers it for the next
app launch. Ordinary button remapping and Launch at login retain their existing
preferences.

## Implemented behavior

The preference is saved separately as `precision-automatic-restart-v1.json`.
It binds to device/firmware identity, immutable baseline transaction and SHA-256,
and a unique enrollment UUID. Turning it off revokes the current in-memory run
before changing the file. Re-enrollment cannot revive an older captured consent.
The JSON is input to review, never a serialized execution capability.

The app waits for a connected supported trackball, output capabilities, and both
permissions. One event-driven launch flow sequences bounded Root and firmware
queries, offline preview/self-test, reporting GET, readiness review, owner bind,
and automatic admission. Duplicate callbacks cannot start another flow.

* A saved verified-active transaction selects GET-only `.resume`. Fresh endpoint
  identity and full reporting state must match before mute/volume are enabled.
* Exact baseline after resume is recorded as restored with no new attempt. The
  owner must drain, close successfully, and release its observer fence. A matching
  completed journal is then CAS-archived. A new observer run collects all evidence
  again before one new activation. The newly bound observer run must differ.
* An already completed matching journal can be archived before initial fresh
  preparation. A clean baseline can authorize one activation through the existing
  write-ahead, SET, and independent verification GET path.
* Unknown, conflicted, recovery-required and unrelated-dirty states remain blocked.
  There is no automatic `.recover`, restore, write retry, or inverse command.

A launch-scoped, non-Codable permit creates a distinct fresh one-use automatic
admission authorization; no `explicitlyConfirmed: true` shortcut is used. It
checks the captured consent before and after preparation and admission handoffs.
The final mutation claim occurs at the existing blocking writer's queued-to-
entered boundary under a lock shared with opt-out. Revocation before entry
rejects without physical dispatch. After entry, the call may finish and its
journal outcome is classified; no second SET is allowed. The final consent check
still prevents audio activation after opt-out. Explicit later restoration does
not depend on keeping the automatic preference on.

The baseline fallback is bounded to one fresh activation in the same launch.
Physical disconnection of an already admitted active session still shuts it down
for review. An orderly Mac sleep is handled separately: `willSleep` disables
audio, drains and closes the active endpoint, preserves the active journal, and
releases the observer fence only after exact active classification, zero close,
unchanged bytes, and a clear synchronous disconnect witness. `didWake` starts a
different observer run and spends a one-use, sleep-cycle-bound capability on
GET-only `.resume`. That capability has no mutation claim. Baseline, disconnect,
changed evidence, opt-out, failed close, or a stale completion leaves audio off;
there is no activation or recovery fallback.

## Review and verification

The read-only advisor reviewed the architecture and implementation. Its findings
about failed fence release and baseline identity validation were fixed and tested.
Old-owner callbacks are bound to their owner identity so a late restored/released
callback cannot overwrite a fresh session's state.

The eight safety questions are all no: no new package dependency edge or product;
no extra physical output site; no ACK accepted as proof; no retry/inverse/automatic
recovery; no automated ambiguity resolution; no rewrite of pinned recovery files;
no extra event-posting site or suppressing tap; no fail-closed input path.
The existing owner facade is narrowly extended under the user's authorization.

Automated verification: 554 tests, no skips. New coverage includes persistent
opt-in/disable/re-enrollment, changed consent and baseline identity, completed
journal archival, one-launch sequencing and non-looping fallback, revocation
across preparation/handoff/acquisition, both sides of physical dispatch, automatic
GET-only resume, and restored/clean/close/fence-release requirements. Existing
CAS/crash durability, endpoint identity and ambiguity tests remain enabled.
Signed build and installation identities are recorded in RELEASE-CHECKLIST.md.
No live HID query or SET was invoked by the agent for these tests.

## Attended acceptance still required

Enable **Start Precision automatically** in the installed candidate, then test
Precision tap mute/unmute, hold-and-scroll volume, release back to normal scroll,
and the volume popup. Quit and reopen the app, then repeat. With Launch at login
on, repeat after log out/in and Mac reboot. Record exact observed outcomes against
this candidate; automated tests do not establish physical notification delivery.
With Precision active, also sleep the Mac once, wake it, wait for the reconnect
status to finish, then repeat tap mute/unmute and hold-scroll volume. Repeat once
with **Execute mute and volume** off and confirm it remains off after wake.
Turning automatic startup off stops future activation. The separate audio toggle
pauses current audio actions; Restore Precision button explicitly restores the
normal button setting.

The previous read-only candidate (source `5a1054e`, executable `dcf86671…852f5`)
observed exact baseline on September 11 and completed transaction
`30A1D902-8946-4C09-8FE6-1CFAD59F9687` without a new SET attempt. A subsequent user
report said all was good; the installed app was later observed active with audio
on. Those facts belong to that earlier build, not automatic-start acceptance.

## September 14 — native Precision can remain slow during startup

The user reports that automatic restart worked, but pressing Precision before
mute/volume became ready left tracking slow after audio started. The captured
runtime is transaction `843AD06D-E61E-47BA-A323-3F5A1D750BB5`, revision 3,
`running`, with CID `00ED` `appliedVerified`; automatic restart is enabled.
Those records attest button diversion, not native tracking mode. Restart
acceptance is qualified by this unresolved issue.

A user-triggered **Check tracking speed** diagnostic reads feature `0x2205` on
the admitted endpoint. It dynamically resolves Root, reads the 16-bit scaling,
and rechecks the exact feature descriptor, using distinct software IDs 4/5/6.
The same device, connection epoch, Root generation, canonical operation lease,
and competitor checks are required. One attempt is allowed per runtime; failure
shuts that runtime down. Exact request/response bytes are saved separately under
Application Support `tracking-diagnostics/`. No scaling SET or automatic reset
is implemented. A value of `0x0100` is not evidence of the user's normal speed.

Next gate: the user captures the reported value while the pointer is slow, uses
the existing verified **Restore Precision button…** action, and physically returns
the trackball to normal. A fresh session captures the normal value for comparison.
If both values match, this feature cannot distinguish the observed native modes.
If they differ, a separately enrolled normal value and a post-diversion GET gate
can be designed. Automatic correction would require its own reviewed durable
transaction and independent verification, not a guessed default or blind toggle.

No live HID query or SET was initiated by the agent for this diagnostic work.
