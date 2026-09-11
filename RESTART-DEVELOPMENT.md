# Precision restart development — September 11, 2026

The user requested seamless mute and hold-scroll volume across app and Mac
restarts. That replaces the earlier product boundary requiring seven manual
preparation steps for every session. It does not authorize retries of uncertain
device writes or changes to the immutable recovery baseline.

## Implemented validation candidate

**Resume previous Precision session** is a single, user-initiated action in
Controls, offered for a validated saved `running/appliedVerified` transaction.
It waits for a connected device and permissions, then sequences existing bounded
Root and firmware discovery, offline preview and self-test, a reporting GET,
readiness review, and a freshly bound owner. It enables audio only after a
separate reporting GET from the acquired endpoint verifies the intended state.
Duplicate requests, cancellation, changed connection generation, and failed
checks stop the sequence. The button is not an unattended startup hook.

The new `.resume` operation is separate from `.recover`. Its coordinator has
no prepare/invoke branch and cannot send a SET. Exact active state preserves
the journal bytes and attempt history. Exact baseline records `restoredVerified`
with the existing reducer and durable CAS repository, without inventing a
restore attempt. Other bytes record conflict. Timeout, cancellation, disconnect,
identity mismatch, and uncertain phases cannot trigger activation or recovery.

The separate versioned, device/firmware/baseline-bound consent data and restart
decision table exist at package scope. They default off and are non-authorizing.
They are not persisted or consumed by the app in this candidate.

## Review of the safety gate

A read-only advisor reviewed the architecture before implementation. For this
candidate the eight questions are: (1) no new dependency edge or product;
(2) no additional device-output call site; (3) a GET remains the only proof;
(4) no retry, inverse command, or automatic recovery; (5) no automatic resolution
of durable ambiguity; (6) no rewrite of the pinned baseline or forensic records;
(7) no additional event-posting site or suppressing tap; (8) event failure remains
pass-through. Promotion is through a narrowly extended existing owner facade.
The stored consent data does not weaken one-use authorization or make executable
authorization serializable.

## Attended acceptance

The current saved session was inspected, not replayed: transaction
`30A1D902-8946-4C09-8FE6-1CFAD59F9687`, revision 3, `running/appliedVerified`,
with one verified apply. SHA-256:
`391338f46211934d5ea1c0aa6c0cc954dd3c6b105e7ee0634640d3b7410412b1`.
The old app reported disconnected/recovery required in memory. This is saved
state, not proof of the device's current setting. The five protected hashes
still matched. No live HID query or SET was invoked by the agent.

After installing the candidate and reconnecting the trackball, use **Resume
previous Precision session**. If active is confirmed, test a Precision tap
(mute/unmute), hold-and-scroll volume, release back to ordinary scrolling, and
volume feedback. Capture the result and runtime record. If the app says the
device returned to baseline, record that outcome; this action must not activate
it automatically. Do not deliberately interrupt a real SET to test crash cases;
those faults belong in the automated fake-transport tests.

## Remaining work for fully automatic restarts

1. Confirm that a newly acquired endpoint receives diverted Precision events.
2. Add a visible persistent opt-in, with revocation checked throughout admission.
   Mint a fresh one-use capability each launch; never pass an old confirmation
   Boolean as though it were a new user action.
3. Wire one startup attempt per launch/connection/journal snapshot. Valid active
   evidence selects GET-only resume. Verified clean baseline selects one fresh
   activation, with the existing write-ahead and independent GET verification.
4. For verified baseline after resume, shut down/release, CAS-archive the completed
   journal, repeat fresh evidence collection, and create one new transaction.
5. Preserve all uncertain, conflicted, unrelated-dirty, and recovery-required
   journals for review. Add revocation, duplication, and crash-boundary tests.
6. Test app restart, login, and Mac reboot on the resulting automatic candidate.

No claim of seamless unattended operation is made by this validation candidate.
