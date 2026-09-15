# Native Precision startup report — September 14, 2026

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

Protocol reference: https://lekensteyn.nl/files/logitech/x2205_pointermotionscaling.html

Files in this directory were copied from Application Support before changing the candidate.
The physical slow state is user-reported; no scaling measurement has been collected yet.
