# Changelog

The development record for MX Ergo Controller, kept as an append-only audit
trail. Each entry states what a milestone added, what it deliberately did *not*
add, the resulting package test count, and whether any live HID operation was
performed.

The cadence matters more than the prose: every capability is built first as a
productless SwiftPM target that cannot link into a shipping binary, proved with
tests, and only then promoted behind an explicit review. See [SAFETY.md](SAFETY.md)
for the invariants this history is enforcing, and
[Evidence/VALIDATION-RECORDS.md](Evidence/VALIDATION-RECORDS.md) for what the
physical trackball actually did.

---

## Current milestone: live mapped-control GET-only preflight

This implementation remains observer-first. It can:

- match the exact MX Ergo hardware identity (`046D:B01D`)
- verify that the connection is Bluetooth/BLE
- detect connection and removal
- count and preview incoming HID reports
- capture and name recent Logitech `0x11` control reports in a bounded calibration panel
- isolate ordinary mouse-button transitions, including the wheel click, from pointer noise
- preview the configured action resolved from each calibrated control without executing it
- observe decoded vertical wheel notches and preview Precision + wheel volume actions
- optionally execute mute and smoothly accumulated volume changes through CoreAudio
- show Input Monitoring permission status
- encode and validate HID++ 2.0 long messages
- describe ROOT and `REPROG_CONTROLS_V4` discovery queries
- correlate replies and HID++ protocol errors by device, feature, function, and software ID
- decode control capabilities and preserve both reporting-state flag bytes
- atomically persist a versioned original-state journal with explicit recovery transitions
- verify report `0x11` against macOS's descriptor-derived maximum output size
- report whether macOS exposes a stable serial/location discriminator for recovery
- send exactly one fixed, read-only Root `GetFeature(0x1B04)` query per app run
- correlate the reply to the same physical IOHID device and connection epoch before UI throttling
- after a successful Root reply, read the `REPROG_CONTROLS_V4` control count once
- enumerate every reported control's metadata sequentially with a strict 64-control ceiling
- read the current reporting state of every enumerated control with sequential `GetReporting` requests
- validate the complete same-connection snapshot and atomically save it as the recovery baseline
- reject decoded journals whose identity, feature, count, indexes, IDs, or raw payloads violate recovery invariants
- build an exact restore plan only for the physical MX Ergo identity recorded in the journal
- rehearse every write-ahead, read-back, restore, and restored-verification phase on an in-memory copy
- verify that the on-disk journal remains byte-for-byte unchanged by the rehearsal
- derive a separate schema-v3 simulation transaction without migrating or rewriting the live schema-v2 baseline
- treat the exact raw reporting payload as the canonical transaction state and reject impossible decoded phase evidence
- serialize transaction effects through an actor and bind every operation to one device identity, feature version, and connection epoch
- authorize an abstract mutation only after a revisioned compare-and-swap commit returns a matching durable receipt
- fully flush temporary schema-v3 journals with `F_FULLFSYNC`, atomically replace them, and flush the containing directory
- simulate clean apply/restore cycles for every control plus restart recovery before and after an authorized abstract mutation
- leave already-clean controls untouched during recovery and never invoke the same persisted attempt UUID twice
- abort the discovery session on timeout, disconnect, malformed data, protocol error, or identity mismatch
- resolve HID++ Device Information (`0x0003`) through Root and read its static device record plus every bounded firmware entity
- derive a canonical recovery fingerprint that excludes transient active/transport fields and remains in memory until real-hardware stability is confirmed
- construct a fail-closed, in-memory journal migration proposal that changes only `device.firmwareIdentity`
- prove the live schema-v2 journal remains byte-for-byte unchanged during migration planning
- bind a reviewed proposal only through a separate explicit commit using exact-byte CAS and a stable sidecar lock
- durably publish an original-byte backup before full-syncing and atomically replacing the live journal
- reconcile retries only when the live bytes are exactly the reviewed source or target; lock every other state
- construct feature-v3 restore-only `SetCidReporting` packets from the firmware-bound baseline entirely in memory
- restore only temporary diversion with the narrow feature-v3 validity flag (`0x02`) while leaving persistent diversion, raw-XY, and mapping untouched
- omit non-divertable and virtual controls, reject unknown flag/version/capability combinations, and pair every SET preview with a separate `GetCidReporting` verification request
- validate a prospective SET acknowledgement only as an exact echo, never as proof of restored state
- model the first Precision-only experiment in a dedicated journal rather than forcing a no-op restore through the general apply/restore reducer
- protect the trial journal with a stable sidecar lock, last-moment exact-byte CAS, full-sync replacement, and exact durable read-back
- bind the armed revision to a one-use in-memory authorization covering the attempt, CID, SET bytes, baseline hash, firmware identity, and connection epoch
- run that complete path against an isolated scripted transport that permits one SET and requires separate preflight and verification reads
- compile a purpose-built Precision-only IOHID adapter in a separate package target with no library product and no dependency edge from the app
- reject every request except the exact reviewed feature-v3 Precision SET and its independent GET verification, and classify every IOHID return after entry as potentially dispatched
- gate a live Precision preflight on the same physical device, current Root epoch, firmware identity, clean journal, and exact saved CID `00ED` baseline
- send exactly one live `GetCidReporting` for Precision, require a byte-for-byte baseline match, and provide no retry or SET path from the app
- run the physical Precision preflight from a separate, short-lived helper app with bundle identifier `com.phib.MXErgoRestoreTrialProbe`
- acquire the same canonical device-operation lease used by journal writers before opening the exact BLE MX Ergo
- resolve Root, firmware identity, and Precision reporting state independently with software ID `0x0D`
- synchronously close IOHID before proving that the journal and its original-byte backup remain byte-for-byte unchanged
- build the helper without an `MXErgoKit` dependency or any reporting-SET/planner symbol in its target graph or executable
- build a second, separately signed helper with bundle identifier `com.phib.MXErgoPrecisionRestoreTrial` that is absent from the menu app and read-only helper graphs
- require the exact `--confirmed-one-control-precision-restore` argument before the second helper opens IOHID or prepares a trial
- refuse the trial while BetterTouchTool, Logi Options, or the menu controller is running
- hold the canonical live-device lease continuously across Root/firmware discovery, durable arming, the one-use SET boundary, independent GET verification, and synchronous IOHID shutdown
- keep the existing read-only helper GET-only; its rebuilt executable still contains no trial adapter, reporting planner, or `MXErgoHIDPP` symbol
- construct the exact Precision temporary-diversion lifecycle without HID I/O: apply SET flags `03`, authoritative active GET flags `01`, restore SET flags `02`, and exact baseline GET
- bind each new schema-v3 transaction to the runtime-resolved feature index as well as feature ID, version, physical identity, firmware identity, and connection epoch
- perform an exact baseline GET before arming the durable apply write-ahead record; drift is persisted as a conflict and invokes no mutation
- retain bounded per-attempt request/response/IO-return evidence, including correlated non-echo responses, without allowing that evidence to verify device state
- derive inactive, active, recovery-required, restored, and conflicted Precision states solely from the existing durable transaction envelope
- require every Precision activate, deactivate, and explicit-recovery operation to pass an injected competing-process check before and after taking the canonical device-operation lease
- hold that lease for the complete lifecycle operation; a competitor appearing after dispatch fails the operation without an automatic inverse SET, retry, or durable-state rewrite
- run restart recovery through the same guard and inspect or restore only Precision CID `00ED`
- classify BetterTouchTool, Logi Options/Options+, and other MX Ergo controller/helper processes from value-only AppKit snapshots while excluding only this app's PID
- review Precision lifecycle readiness from two competitor scans, exact unchanged journal bytes, current Root/firmware generations, matching physical identity and feature index, and the exact-baseline live preflight
- expose the readiness result as immutable `notAuthorizedForExecution` evidence; the menu app constructs no coordinator, schema-v3 repository, effect transport, or lifecycle object
- invalidate readiness when a competitor launches or when the journal, connection, Root, firmware, feature, or preflight evidence changes
- exercise a production-shaped Precision transport only inside a SwiftPM test target, with no product, IOKit import, or app/build-graph edge
- prepare and bind a one-use transport invocation before the durable write-ahead commit, then reload and authenticate the exact committed journal before crossing the fake writer boundary
- require an ordinary restore to observe the exact intended state first; an already-clean baseline completes without SET, while any third state persists a conflict and sends no SET
- require every transaction transport to implement preparation explicitly; there is no default conformance that can bypass pre-WAL validation
- explicitly discard a prepared reservation only when failure is proven before write-ahead, while invalid preparation or uncertain WAL visibility terminally invalidates it
- bound fake writer/reader waits, ignore unrelated valid HID++ frames until correlation succeeds, and wake blocked reads on disconnect without retrying a SET
- cap both queued frames and the total number of distinct candidates accepted during one request, so continuously drained unrelated traffic still fails closed at a fixed bound
- preserve token-specific cancellation that arrives before a callback request window is opened rather than allowing `beginRequest` to erase it
- compile a concrete input-only IOHID callback owner in a separate productless target with no app/helper dependency or output-report API
- register input, removal, and cancellation callbacks before one-shot dispatch activation, copy callback-owned memory synchronously, verify the exact sender and report metadata, and retain the callback lifetime until cancellation proves quiescence
- compile a separate productless, IOKit-free blocking-write lifecycle with no app/helper dependency and no default system dispatcher
- accept only the exact reviewed Precision GET, temporary-diversion APPLY, and temporary-diversion RESTORE packets bound to one device, connection epoch, and Root generation
- linearize each write as queued, entered, or draining so pre-entry cancellation proves zero calls while post-entry cancellation resolves logically without claiming physical quiescence
- retain the writer, owned request bytes, injected call, and captured resources until an entered blocking call returns, and make shutdown wait for that true drain without retrying or dispatching an inverse command
- isolate the sole new `IOHIDDeviceSetReport` source location in a separate productless output target whose real-device constructor is fileprivate and reachable across modules only through one narrow package factory
- require an exact physical identity, the unique output report-ID set `{0x11}`, and a descriptor-derived 20-byte maximum before constructing the reviewed writer
- keep the output bridge free of discovery, open/close, activation/cancellation, callbacks, retries, inverse commands, environment switches, products, executables, and app/helper dependency edges
- bind injected input and output endpoints to the same runtime ownership-token instance before either endpoint can start
- open request admission only after input startup succeeds, and permanently close it before any shutdown work begins
- drain output, quiesce input callbacks, and invoke the retained resource owner's synchronous release exactly once in that order, including startup rollback and concurrent shutdown
- keep the ownership coordinator productless, IOKit-free, fake-tested, and unable to claim or construct a shared raw IOHID handle
- quarantine an explicit quiescent-release anchor and the exact input/output endpoint bundle if its coordinator is abandoned, preventing close or ARC release from bypassing output drain or input quiescence
- keep failed input activation in cancellation until the registered cancel handler proves callback quiescence
- terminally resume an already-queued write if cancellation tombstones overflow, preventing a suspended continuation from being stranded
- compile a productless source assembly that passes one already-open, exclusively transferred IOHID device reference to both narrow endpoint factories and atomically binds the resulting endpoint bundle plus its release anchor to the ownership quarantine before the coordinator escapes
- compile a separate productless acquisition owner that validates the immutable plan and binding before creating an independent-device IOHID manager
- enumerate the exact BLE MX Ergo identity and required report capabilities, require one unique match, open only that device directly without seizing it, and close the manager before assembly can escape
- close a directly opened device exactly once after endpoint quiescence, or synchronously on manager-close or assembly-construction rollback, while preserving every cleanup return code
- bootstrap the schema-v3 Precision runtime journal from one exact clean schema-v2 recovery baseline while holding the canonical sidecar lease
- create the runtime journal only when absent, otherwise validate and reuse its exact bytes without resetting active, ambiguous, conflicted, or recovery-required evidence
- expose the durable repository and atomic envelope-plus-SHA-256 loader through one canonical package-only source so runtime composition cannot receive split journal authorities
- validate one atomic durable envelope-plus-SHA256 snapshot before acquisition and reject a mismatched session, feature, baseline, or hash before any hardware owner is created
- compose acquisition, transport, the durable transaction coordinator, and the Precision lifecycle behind one package-only actor without exposing any component separately
- publish that owner only after input activation succeeds; every post-acquisition construction, cancellation, or startup failure disconnects, drains, quiesces, and closes
- stop operation admission before shutdown, disconnect the transport, wait for any in-flight coordinator operation to settle persistence, classify the final journal state, and only then close the device
- report active, ambiguous, or conflicted teardown as recovery-required, keep shutdown idempotent for concurrent callers, and leave the entire composition target absent from all runnable graphs
- compile a productless admission supervisor that is absent from the app, helper, project, and package-product graphs
- bind explicit consent to one launch, operation, immutable readiness snapshot, physical device and firmware identity, feature/session generation, exact source/runtime journal evidence, packet bytes, and monotonic expiry
- consume that non-Codable authorization exactly once and recheck expiry after awaited handoff, bootstrap, composition, and immediately before the operation
- acquire one canonical operation lease before host handoff and retain that exact lease through bootstrap, acquisition, every admitted operation, ordered output/input shutdown, direct device close, and abandonment quarantine
- require an awaited host receipt proving the old observer has no pending requests, is unscheduled, and has closed the exact device before runtime bootstrap or acquisition can continue
- compare the bootstrap result and post-composition journal to the exact authorized revision, digest, bytes, and create-or-reuse disposition before allowing an operation
- admit activation only from a fully prepared journal and recovery only for Precision-local active or ambiguous evidence; reject aborted-clean, completed, conflicted, and unrelated-dirty states without SET
- reserve each command before its first suspension, make shutdown win every reentrancy race, settle durable state before ordered close, and never auto-retry or dispatch an inverse operation
- assign every observer run a unique identity and register every accepted read-only request as queued or active before its run-loop block can execute
- stop request admission before teardown, clear all pending request/correlator state, unschedule and close the exact IOHID manager, then deliver intentional-shutdown completions exactly once in acceptance order
- publish a package-only asynchronous receipt containing the run identity, pending-at-stop count, final zero-pending proof, callback-quiescence proof, and exact never-acquired/closed/release-uncertain ownership result
- allow multiple handoff waiters without letting waiter timeout or task cancellation abort physical teardown, and prohibit restart while stopping or after an uncertain manager close
- capture a non-forgeable capability for one exact observer run before admission and reject a foreign or replaced run without stopping it
- compile a productless, IOKit-free host-handoff adapter that retains only the reviewed launch, session, Root generation, and captured observer-run binding
- reject mismatched admission arguments before observer teardown, coalesce identical concurrent callers into one uncancelled physical stop, and replay one sticky terminal outcome
- accept only an exact-run receipt with final zero-pending state, callback quiescence, and definite manager closure, then reread and match fresh session and Root evidence before producing the admission receipt
- keep the adapter absent from every runnable graph until the observer run is bound into admission authorization and an executable owner holds a restart fence through runtime shutdown
- bind the captured observer run identity into reviewed admission authorization and one-use confirmation
- install a non-forgeable observer restart fence before host handoff and retain it through admission, runtime ownership, ordered shutdown, quit, and session rollover
- compile a productless executable-shaped lifecycle owner that is absent from the app, helper, project, and package-product graphs
- expose one public `MXErgoPrecisionRuntimeOwner` product that can bind that owner, keep the restart fence through quit, and release it only for an explicit session rollover
- confirm admission from that owner: stop the captured observer through host handoff and open the Precision runtime after a second explicit confirmation
- confirm deactivation as a subsequent authorized restore SET; quit still does not send an inverse SET
- keep control-event delivery unwired; diverted Precision events are not yet mapped to actions
- deliver diverted Precision HID++ notifications through the admitted runtime into controller intents
- execute Precision tap mute through the existing audio opt-in; ignore undiverted CIDs; Precision+wheel volume still needs a wheel source
- observe MX Ergo wheel notches on a fence-free, input-value-only path while the Precision runtime owns the vendor interface
- swallow HID-level OS scroll only while Precision is held, and convert those notches into volume intents
- observe a physical MX Ergo disconnect while Precision is diverted, stop control-event delivery, and shut the runtime down without an inverse SET or retry
- classify that disconnect as recovery-required, allow explicit session rollover after shutdown, and refuse to re-admit or re-SET on reconnect
- show production status for diverted-active versus recovery-required in the menu app
- bind a recover operation from a recovery-eligible runtime journal on a new connection epoch
- confirm an explicit reconnect recover that can send one restore SET without retry or automatic re-admit
- keep recover fail-closed after an outcomeUnknown restore SET: no second restore SET, no recover re-admission, and a locked Recover control
- construct a software-only temporary-diversion plan for the five mapped CIDs (wheel click, both thumbs, both tilts) with apply flags `03` and restore flags `02`, excluding Precision, and without authorizing SET or event synthesis
- review mapped-control diversion readiness from two competitor scans, exact unchanged journal bytes, current Root/firmware generations, matching physical identity and feature index, and expose it as immutable `notAuthorizedForExecution` evidence
- invalidate mapped-control diversion readiness when a competitor launches or when the journal, connection, Root, firmware, or feature evidence changes
- construct a software-only BTT-replacement action plan for those five CIDs (desktop left/right, back/forward, Mission Control) as `notAuthorizedForExecution` evidence with no CGEvent posting or HID I/O
- compile a mapped-control event pump that resolves HID++ notifications only for an explicitly admitted subset of those five CIDs, keep the menu review at zero admitted CIDs, and leave that pump unwired from posting or the Precision runtime
- construct a GET-only mapped-control preflight for those five CIDs: independent `GetCidReporting` packets, exact-baseline match, at most five packets, as `notAuthorizedForExecution` evidence with no HID send
- send that GET-only mapped-control preflight live as five sequential `GetCidReporting` requests, fail closed on the first mismatch, and still authorize no SET

Audio execution is disabled after every launch and must be explicitly enabled. The menu app still cannot divert buttons, synthesize clicks, alter pointer or scroll behavior, send REPROG SET commands, or change the precision LED. Its HID output remains limited to separately confirmed, bounded read-only Root, Device Information, `GetCount`, `GetControlInfo`, and `GetReporting` requests. Intentional observer shutdown now terminates every accepted read-only request distinctly from a physical device disconnect. The read-only probe also remains GET-only. The separate `MXErgoPrecisionRestoreTrial` Release helper contains only the completed one-control restore experiment; it is not a production sender and remains permanently ineligible for retry. The Precision lifecycle's output side remains fake-only in executed tests. The input, write-lifecycle, output-bridge, ownership, source-assembly, acquisition, runtime-journal, runtime-composition, runtime-admission, runtime-host-handoff, and runtime-lifecycle targets are productless. The menu app now depends on the public `MXErgoPrecisionRuntimeOwner` façade for bind, confirmed admission, confirmed deactivation, Precision tap and hold+scroll volume, quit, and session rollover. The runtime-journal bootstrap creates schema v3 only from the exact clean schema-v2 baseline, or validates and reuses the existing journal byte-for-byte without erasing recovery evidence. Its canonical source provides both the repository and the atomic envelope-plus-SHA-256 snapshot used by composition. The admission supervisor consumes one exact explicit authorization, owns the canonical lease, requires asynchronous observer handoff evidence, authenticates bootstrap and post-composition evidence, and exposes only authorized operations plus sticky ordered shutdown. The observer now produces local run-scoped drain and ownership evidence, and the productless adapter maps one captured run into an admission receipt only after definite closure and a fresh exact session/Root reread. `PrecisionRuntimeAdmissionIntent` now includes the captured observer run identity, and a productless lifecycle owner installs a restart fence before host handoff. The observer cannot start another run until that owner explicitly releases the fence after ordered shutdown or an unused bound session. The menu app can bind a public owner façade for that fence, keep it through quit, and release it only for an explicit session rollover. After a second explicit confirmation, the owner can admit the Precision runtime (stopping the observer and potentially sending a SET) and later deactivate it. Control-event delivery remains unwired. The composition owner validates the immutable plan/binding and unchanged canonical snapshot before acquisition, starts one uniquely acquired endpoint before publication, and owns the transport, coordinator, and Precision lifecycle as one non-escaping graph. Shutdown closes admission, disconnects and settles any in-flight operation, classifies durable recovery state, then drains output, quiesces input, closes the device, and releases the lease. All admission, bootstrap, composition, acquisition, and observer-handoff tests use injected files, fakes, or no-hardware construction; no runnable target can reach the dormant Precision runtime boundary.

---

## HID++ safety gates

The discovery and baseline gates have passed: exact BLE identity, one matching interface, stable serial identity, descriptor-derived 20-byte output size, software ID `0x0E`, same-device/same-epoch correlation, a verified Root response, all 9 control metadata records, and all 9 original reporting states durably stored. A timeout still poisons the connection and never retries automatically.

The current milestone adds a separate restore-only trial record, reducer,
stable-lock repository, exact-byte CAS, one-use authorization, actor runner,
operation-lifetime interprocess lease, exact live-baseline revalidation, and
read-only reconciliation for every ambiguous durable phase. Wrong acknowledgements,
verification failure, cancellation after authorization, and indeterminate commits
are durably classified without authorizing a retry. The runner's public surface
exists only so the isolated helper can supply its narrowly typed transport; the
production HID module and menu app do not conform to or depend on that transport.
The package's `MXErgoRestoreTrialIOHID` target remains unexported, while its single
reviewed adapter source is compiled directly only into the separate trial helper.
Its injected boundary tests prove
the exact request allowlist, exact acknowledgement, independent verification,
same-device/epoch correlation, one-attempt rule, timeout poisoning, and ambiguous
IOHID-return classification. The menu app and GET-only probe binaries contain no
adapter module or symbol. The live schema-v2 baseline is never
rewritten by either simulation.

The expanded safety suite now covers all six durable file-commit boundaries,
all 16 apply/restore transport outcomes, exact recovery classification for every
persisted phase, mixed nine-control recovery ordering, cancellation, exact
location/firmware reconnect binding, every immutable feature-v3 wire byte, and
a real subprocess `SIGKILL`/restart using the durable file repository. The
current build adds a bounded read-only `0x0003` fingerprint preview, an
exact-byte migration planner, and a dedicated schema-v2 metadata committer. The
committer uses a stable sidecar lock, original-byte backup, `F_FULLFSYNC`, atomic
replacement, directory sync, exact read-back, and strict source/target restart
classification. The confirmed journal binding, unlinked IOHID boundary, and
app-level live read-only Precision preflight are complete in code. The preflight
sends one exact feature-v3 `GetCidReporting` request only after revalidating the
physical device, current Root and firmware evidence, clean journal bytes, and
saved Precision baseline.

The first explicitly authorized physical trial ran on 2026-08-30. It dispatched
exactly one Precision CID `00ED` SET (`11 00 0A 3E 00 ED 02 00 00 …`) and never
retried it. The device response did not satisfy the deliberately strict full-echo
acknowledgement rule, so the durable trial correctly entered `outcomeUnknown`
revision 2. A subsequent signed GET-only probe captured flags `01`, map `0000`;
because BetterTouchTool had automatically restarted between observations, that
temporary state was not attributed to the trial. With BetterTouchTool stopped, a
physical power-cycle followed by one final GET returned the exact clean baseline
`00 ED 00 00 00 …`. The new HID-free offline reconciler pinned that signed probe
result and the exact outcome-unknown journal, then used the existing read-only
restart reducer to commit `baselineVerified` revision 3. The protected live
journal remained
`60ab614927d20871994ad0ebe7368158af9a26b2c1d60f7a2ab3c51635f77097`
and its original-byte backup remained
`4ef802eb1185c56f24b7635324113ab414f2acca499a4addc4e4117cd3cdf3aa`
throughout. No automatic recovery SET or retry is permitted.

The follow-on software-only milestone now models the full Precision lifecycle
on top of the general schema-v3 coordinator rather than the completed trial
helper. A preflight GET must match the complete baseline before apply can be
armed. The apply command is projected as flags `03`, but only a separate GET
returning flags `01` can establish `appliedVerified`; restore is projected as
flags `02`, and only an exact full-baseline GET can establish
`restoredVerified`. Correlated non-echo SET responses are retained as bounded
durable diagnostic evidence instead of being discarded, but never drive a
phase transition. Existing schema-v3 journals without a feature-index binding
still decode for inspection and recovery analysis, while failing closed before
any future transport invocation. The lifecycle now also requires a clean
competitor snapshot on both sides of acquiring the canonical device-operation
lease and keeps that lease alive through activate, deactivate, or explicit
restart recovery. A late competitor never triggers an automatic inverse command
or retry; the durable recovery-required state remains authoritative. Scripted
restart coverage proves that the guarded recovery path inspects and restores only
Precision CID `00ED`. The menu app can now perform a value-only readiness review:
it takes two deterministic running-application snapshots, requires exact
unchanged baseline bytes plus current Root, firmware, feature-index, physical
identity, and Precision-preflight evidence, and returns only immutable
`notAuthorizedForExecution` evidence. It does not construct the lifecycle,
coordinator, transaction repository, or effect transport, and it invalidates the
review when a competitor launches or evidence changes. No production IOHID writer
was added and no physical command was sent in this milestone.

The next test-only transport milestone exercises the coordinator against a
production-shaped, structured fake writer/reader boundary. It permits only the
reviewed Precision feature-v3 apply (`03`), restore (`02`), and independent GET
packets; binds each one-use attempt to the same device, connection epoch, Root
generation, session, durable revision, and journal SHA-256; and reloads the
durable write-ahead record before allowing a SET to cross the writer seam.
Preparation rejection leaves the journal's exact bytes and hash unchanged.
Once a SET could have crossed that seam, timeout, cancellation, disconnect, or
late competition poisons the epoch and cannot trigger a retry or inverse SET.
Acknowledgements and non-echo responses remain diagnostic evidence only: a
separate GET is authoritative. Ordinary restore now reads intended state first,
returns cleanly without SET when the baseline is already present, and records a
conflict without SET for third-party drift. This adapter is internal to the
unexported `MXErgoPrecisionTransport` target; it has no package product, app or
helper dependency, concrete report writer, or IOKit access, so this milestone
cannot mutate physical hardware.

The transport hardening milestone keeps that boundary reachable only by its
dedicated SwiftPM test target. Preparation is
now a mandatory protocol requirement, and the coordinator explicitly abandons a
reservation with one of three durable-visibility dispositions. Only a failure
proved to precede write-ahead returns the adapter to idle; invalid preparation or
any commit whose visibility is uncertain poisons the reservation and requires
journal reload/recovery. The adapter retains an awaiting-verification state after
SET evidence, owns bounded writer and reader deadlines, revalidates its pending
request after every suspension, filters unrelated valid HID++ traffic, and wakes
a blocked reader when disconnect is reported. Adversarial tests cover forged
authorization fields, active-attempt mismatch, duplicate invocation, writer
throw/nonzero returns, SET and GET protocol errors, already-baseline restore,
concurrent disconnect, timeout cancellation, and the distinction between clean
pre-WAL disposal and terminal ambiguous-WAL invalidation. It remains absent from
all products, application targets, and IOKit code.

The follow-on callback-lifetime hardening remains fake-only. A non-mutating
forensic verifier rechecks the preserved live journal, original-byte backup,
post-power-cycle probe, reconciled trial, and reconciliation result as regular
non-symlink files. It pins their exact hashes, transaction and attempt IDs,
revision transition, timestamps, device/firmware binding, immutable SET/GET
bytes, protected before/after hashes, and the common clean Precision observation.
Repinned negative fixtures prove that changes to the function nibble, CID,
feature index, epoch, hash, timestamp, phase, revision, device binding, or SET
bytes still fail closed. The no-IOKit callback inbox now lives beside the
adapter in the dormant target. It copies ephemeral bytes before return, arms a
token-scoped window before writer entry, keeps a bounded FIFO open across
unrelated valid frames, suppresses byte-identical duplicates, fails closed on
queue or total-candidate overflow, and makes finish/cancel token-specific and
idempotent. Cancellation is
sticky even when it arrives before a reader or writer waiter is installed.
Adapter state now records preparation and window-opening tokens, revalidates
them after suspension, rejects current-session access after poison, and cannot
resurrect prepared state after disconnect. Fake integration tests deliver
callbacks synchronously inside `write()`, consume unrelated-then-matching
traffic, reuse the channel for later requests, and gate cancellation on both
sides of waiter installation. Concrete writers and hardware bridges remain
test-only or absent. No package product, IOKit/IOHID implementation, app/helper
edge, or live request was added.

The next input-only IOHID milestone preserves the pure transport target and
places all IOKit linkage in a new `MXErgoPrecisionIOHIDInput` sibling target.
That target has no package product and is consumed only by its dedicated test
target. Its concrete owner accepts an already-open, exclusively transferred
device; it does not discover or open devices and does nothing during
initialization. Explicit start registers the input report, removal, and cancel
callbacks before dispatch activation. It validates the physical identity and
exact callback sender, accepts only input report `0x11` with 20 bytes, copies
ephemeral callback memory synchronously, reports removal exactly once, and
keeps the callback buffer, context, and device alive until the IOHID cancel
handler confirms quiescence. Fake-runtime tests cover registration order,
synchronous and malformed callbacks, foreign senders, removal, late input,
bounded candidates, delayed cancellation, and an end-to-end callback through
the existing transport adapter. The target contains no output-report constant,
`IOHIDDeviceSetReport`, manager, open, executable, app, or helper edge. No live
HID request was made. At that point, a concrete writer remained blocked until
its synchronous IOHID call could be reconciled with bounded cancellation and
explicit in-flight drain/lifetime guarantees.

The follow-on output-lifecycle milestone remains entirely fake-only. A new
`MXErgoPrecisionWriteLifecycle` sibling target has no package product, IOKit
linkage, app/helper dependency, discovery/open path, or default output
implementation. It accepts only the exact reviewed GET, APPLY, and RESTORE
20-byte frames for one immutable transport binding. Its lock-linearized
`queued -> entered` transition is the may-have-dispatched boundary: cancellation
before entry removes the request with zero injected calls, while cancellation
after entry promptly completes the adapter-facing write as outcome-unknown and
retains all resources until the blocking call returns. Sticky, idempotent
shutdown rejects new work and waits for actual drain. Direct race tests cover
pre-entry, queued, entered, reentrant, duplicate, capacity, retention, and
shutdown behavior. An adapter integration test proves that a timed-out APPLY
produces one durable `applyMayHaveOccurred` attempt, poisons the transport,
dispatches no RESTORE, and still blocks teardown until physical drain. The
signed menu-app dependency graph excludes this target. No IOHID output symbol
or live HID request had been added at that stage.

The current bridge milestone adds the concrete call shape without making it
reachable. `MXErgoPrecisionIOHIDOutput` is a productless IOKit-linked sibling
consumed only by its tests. Its internal fake-runtime initializer validates the
complete physical identity, unique output report-ID set `{0x11}`, and exact
20-byte maximum before privately constructing the existing reviewed lifecycle.
The real-device initializer and system runtime were private at that stage. The
runtime retains an already-open device, copies the owned 20-byte record, and contains
the single new `IOHIDDeviceSetReport` source call; it cannot discover, open,
close, activate, cancel, or register callbacks. The facade exposes only write,
token-specific cancellation, and true drain, with no second state machine or
raw dispatcher. Fake tests prove zero calls at construction or for invalid
identity/capability/frame data, one exact call for each reviewed GET/APPLY/
RESTORE packet, exact nonzero return propagation, pre-entry cancellation,
single-flight and duplicate suppression, prompt post-entry logical completion,
sticky shutdown, and device/byte retention through physical return. All 210
package tests pass, while a fresh signed menu-app build contains no output-
bridge artifact or symbol. No live HID request was made.

The ownership milestone adds a runtime-shaped composition contract without
widening either real IOHID constructor. `MXErgoPrecisionIOHIDOwnership` is a
productless, IOKit-free sibling consumed only by its tests. Construction
requires the injected input and output endpoints to expose the same ownership-
token object. Startup opens request admission only after the input endpoint
starts successfully. Sticky shutdown closes admission first, drains every
entered output call, waits for input callback quiescence, and only then releases
the token's retained anchor exactly once. Startup rollback uses the same order,
and concurrent shutdown callers share one teardown. Eight focused tests cover
token mismatch, inactive admission, forwarding, independently gated teardown,
startup failure, concurrent shutdown, retained-anchor lifetime, and static
build-graph isolation. All 218 package tests pass. A fresh menu-app build
contains no ownership artifact or symbol. Its embedded signature verifies as
valid on disk and satisfies its designated requirement with Team ID
`XW848M73T3` and Hardened Runtime. No live HID request was made. A source-level
physical assembly binding the ownership token to one raw IOHID device remained
a separate, review-required milestone.

The test-only assembly milestone hardens the prerequisites before widening any
source-module boundary. Failed input activation now remains in cancellation
until its registered cancel handler proves callback quiescence. Cancellation-
tombstone overflow terminally resumes an already-queued write instead of
leaving its continuation suspended. Ownership anchors enter a fail-closed
quarantine at token creation and leave only after ordered output drain and input
quiescence; abandoning a coordinator therefore cannot release the modeled
device through ordinary ARC.

`MXErgoPrecisionIOHIDAssemblyTests` is a SwiftPM test target, not a source target
or product. Its private, uninvoked compile-only function accepts one
`IOHIDDevice` reference and passes that same lexical reference to the concrete
input and output constructors before creating their shared ownership token.
Only the output constructor changed, from private to module-internal, so the
`@testable` proof can type-check it; no package, public, or SPI factory was
added. Dynamic fake assembly tests independently gate output drain and input
cancellation, clear each concrete endpoint only after its own barrier, preserve
the anchor through both, exercise startup rollback, and prove caller
cancellation cannot cancel teardown. All 224 package tests pass. A fresh signed
menu-app build verifies on disk, satisfies its designated requirement, and
contains no assembly artifact or symbol. No live HID request was made. At that
stage, a real productless source assembly remained blocked pending review of
the narrow package-only factory surface Swift module isolation requires.

The productless source-assembly milestone completes that reviewed boundary
without wiring it into an executable. `MXErgoPrecisionIOHIDAssembly` accepts one
already-open `IOHIDDevice` and passes the same lexical reference to the input
and output factories and creates a private retaining release anchor. Its
package-visible surface consists only of the input lifetime, quiescent-release
anchor, assembled endpoint, ownership factory, and one input and output factory;
the concrete runtimes, endpoint wrappers, coordinator, token, and real-device
initializers remain internal or fileprivate. After both endpoints are
constructed, the ownership factory atomically attaches their exact wrappers and
the anchor to the quarantine before the coordinator can escape. Failed output
construction synchronously shuts down the initialized input endpoint, while
startup rollback and ordinary shutdown continue to drain output, quiesce input,
and release the bundle in that order. Abandoning an active coordinator retains
the complete bundle fail-closed.

Six assembly tests cover same-reference construction, zero construction-time
effects, ordered teardown under caller cancellation, startup failure, input and
output construction failure, and active abandonment. All 228 package tests pass.
A fresh signed menu-app build verifies on disk and satisfies its designated
requirement; artifact and binary scans contain no assembly or factory module or
symbol. No live HID request was made. Swift cannot prove that no external Core
Foundation reference remains, so exclusive handle transfer is still a caller
precondition before any future executable integration review.

The follow-on release-contract milestone removes the last ARC-only teardown
assumption before direct device acquisition can be designed. The ownership
capsule now retains an explicit `PrecisionIOHIDQuiescentReleaseAnchor` beside the
exact input/output wrappers. Once output drain and input callback quiescence have
both completed, it removes the complete bundle from quarantine, clears the
endpoint references, and invokes the anchor once outside the capsule lock. The
default source-assembly anchor releases its retained handle; a future private
direct-open owner can use the same capability to call `IOHIDDeviceClose` without
widening the coordinator or exposing the raw handle. Startup rollback follows
the same order, repeated or concurrent shutdown cannot invoke release twice, and
active abandonment invokes no release at all.

The focused assembly and ownership suites pass, as do all 228 package tests. A
fresh signed menu-app build verifies on disk and satisfies its designated
requirement; artifact and binary scans contain no assembly, ownership-factory,
release-anchor, or endpoint-factory symbol. No manager, direct open/close, app
dependency, or live HID operation was added in this milestone. At that stage,
the next review gate was a productless independent-manager acquisition owner
that directly opened one validated device and supplied a close-owning anchor.

The independent-manager acquisition milestone completes that dormant owner in
`MXErgoPrecisionIOHIDAcquisition`. It rejects an invalid plan/session/feature
binding before any system call. The real path creates a manager with
`IOHIDManagerOptions.independentDevices`, installs only the exact MX Ergo
vendor/product match, opens the manager for enumeration, and copies its device
set. Candidate filtering requires the complete journal identity, stable
discriminator, firmware binding, bounded input-report size, the unique output
report-ID set `{0x11}`, and a 20-byte maximum output report. Zero or multiple
matches fail closed without opening a device.

For one exact match, the owner directly opens the device with the non-seizing
option and closes the manager before source assembly. A manager-close failure
immediately attempts direct device close and constructs no assembly. Otherwise,
the close-owning anchor enters the existing full-bundle quarantine. Assembly
failure reports the original error plus the direct-close return; normal teardown
records the close return after output drain and input callback quiescence.
Manager-open, enumeration, uniqueness, device-open, manager-close, assembly,
and repeated-shutdown paths all have injected-call coverage.

Eight acquisition tests raised the package total to 236, all passing. At that
milestone the target had no product or package API, seize option, callback registration, SetReport,
environment switch, app/helper dependency, or executable edge. A fresh signed
menu-app build verifies on disk and satisfies its designated requirement;
artifact and binary scans contain no acquisition, assembly-factory, or
close-anchor symbol. No real acquisition path or live HID operation was run.

The runtime-composition milestone adds
`MXErgoPrecisionRuntimeComposition` as the sole dormant owner of the complete
Precision graph. Its narrow package factories expose only opaque acquisition
and transport lifecycle capabilities. Before acquisition, the factory validates
the exact plan/session binding and one atomically loaded, validated envelope and
lowercase SHA-256 pair. It then acquires the endpoint, constructs the transport,
coordinator, and temporary-diversion lifecycle, and activates input before the
facade can escape. Transport-construction and startup failures preserve the
primary error and direct-close return while mandating disconnect and ordered
drain/quiescence/close rollback.

The actor admits only one lifecycle operation at a time. Shutdown permanently
closes admission, disconnects the adapter to cancel pending report I/O, waits
for the coordinator operation to finish its durable work, classifies the final
journal state, and only then drains and closes. Inactive or restored state is
clean; active, ambiguous, or conflicted state is explicitly recovery-required;
an unavailable journal state is reported rather than guessed. Concurrent and
repeated shutdown callers share one sticky report.

Seven composition tests raise the package total to 243, all passing. They cover
pre-acquisition snapshot rejection and single-load behavior, exact construction
order, transport and startup rollback, concurrent operation/shutdown settling,
active-diversion recovery reporting, idempotent close, and static graph
isolation. The target has no product, direct IOKit import, app/helper dependency,
or executable edge. A fresh signed menu-app build verifies on disk and satisfies
its designated requirement; its dependency graph, artifacts, executable, and
debug dylib contain no runtime-composition or acquisition module/factory symbol.
No real acquisition path or live HID operation was run. Executable integration
remains a separate review-and-authorization milestone.

The canonical runtime-journal milestone adds
`MXErgoPrecisionRuntimeJournal` as the only source from which runtime composition
can receive both transaction persistence and an atomic validated snapshot. The
bootstrap validates the exact physical identity, runtime feature index and
version, firmware-bound Precision baseline, connection epoch, source transaction
identity, source hash, and canonical sibling paths before it can mutate a file.
It holds the existing device-operation lease while reading the schema-v2 source,
publishing a new schema-v3 journal if absent, or validating an existing journal.

First creation uses the durable repository's revision-zero commit and reloads the
exact published bytes and SHA-256 before returning. Reuse never rewrites the
journal: clean, active, ambiguous, conflicted, and recovery-required evidence is
preserved byte-for-byte. A changed source baseline, stale returned context,
identity, feature, session, transaction, or per-control baseline mismatch fails
closed before acquisition. Atomic reads reject symlinks, non-regular files,
replacement races, and oversized data.

Nine bootstrap tests raise the package total to 252, all passing. They cover
first creation, exact reuse, pre-mutation validation, every identity/feature/
baseline mismatch, dirty and conflicted evidence preservation, concurrent first
bootstrap, every durable creation crash boundary and retry, symlink rejection,
and static graph isolation. The target has no product, IOKit import, output call,
app/helper dependency, or executable edge. No real acquisition path or live HID
operation was run. Executable authorization and integration remain a separate
review gate.

The productless runtime-admission milestone adds
`MXErgoPrecisionRuntimeAdmission` as the only façade permitted to assemble and
operate the dormant Precision graph. A read-only review freezes the exact source
baseline and existing runtime bytes, revision, and SHA-256. Explicit confirmation
then issues a non-Codable, actor-isolated, one-use authorization bound to that
evidence, one launch, one requested operation, the immutable plan packets, exact
device/firmware/feature/session generations, canonical journal paths, and a
monotonic deadline. Production callers cannot supply the admission clock.

Admission consumes the authorization before effects, authenticates the journal,
rejects competing software, and acquires the canonical sidecar lease. It verifies
the same evidence again under that lease, awaits proof that the observer has no
pending requests and has unscheduled and closed the exact device, rescans for
competitors, and only then bootstraps and composes the runtime. The returned
bootstrap disposition and snapshot must match the authorized absent-or-exact
state, and the journal is compared again after composition before the first
operation. The same lease remains alive until ordered output drain, input
quiescence, direct device close, and quarantine release complete, including the
manager-close rollback path.

The supervisor reserves commands before their first suspension. A concurrent
shutdown therefore wins permanently: a resumed operation or review cannot
publish state after `stopped`. Every later operation needs a freshly reviewed and
explicitly confirmed authorization. Activation is restricted to a fully
`prepared` Precision baseline; deactivate requires the exact running/active
state; recovery accepts only Precision-local active or ambiguous evidence.
Aborted-clean, completed, conflicted, or unrelated-dirty journals cannot reach a
SET. Operation failures settle durable state and share one sticky ordered
shutdown report without automatic retry or inverse mutation.

Thirteen admission tests plus new canonical-lease rollback, journal, and
composition checks raise the package total to 269, all passing. They cover exact
effect ordering, expiry across awaited work, one-use and cross-launch binding,
changed evidence, competitor and lease rejection, invalid handoff, exact
bootstrap disposition, terminal-state policy, command/shutdown reentrancy,
durable failure settlement, and build-graph isolation. A fresh signed menu-app
build verifies on disk and satisfies its designated requirement; binary scans
contain no runtime-admission, runtime-composition, acquisition, or runtime-journal
symbol. No app or helper dependency edge and no live HID operation were added.
At that stage, executable integration remained prohibited until the concrete
observer supplied its own structured drain proof.

The observer-handoff drain milestone hardens the existing `MXErgoHID` target
without adding a target, product, executable, or dependency edge to runtime
admission. Each observer start now creates a unique run ID. Every accepted
read-only request receives an exactly-once ticket before its run-loop block is
queued and is explicitly tracked as queued or active. Once stop begins, queued
work cannot enter HID. Teardown on the owning run loop clears all five pending
request slots and their correlation state, unschedules the exact manager,
captures the exact manager-close return, delivers intentional `observerStopped`
results for the remaining accepted requests in acceptance order, emits the final
stopped status, and only then publishes its receipt.

The package-only receipt proves the run ID, count pending when stop began, final
zero-pending state, callback-delivery quiescence, and one of `neverAcquired`,
`managerClosed`, or `releaseUncertain(closeReturn:)`. An uncertain close is
terminal and prevents another observer run. Multiple async callers can await the
same receipt; a caller timeout or task cancellation releases only that waiter
and cannot stop physical cleanup. The original nonblocking `stop()` remains the
menu app's behavior, while `stopAndWait()` now returns false when manager release
is uncertain.

Nine focused tests raise the package total to 278, all passing. They cover
queued/active cancellation ordering, normal-completion races, stop before
run-loop acquisition, restart exclusion, close failure, concurrent waiters,
waiter timeout and cancellation, no-hardware construction, and graph isolation.
A fresh signed menu-app build verifies on disk and satisfies its designated
requirement. Its debug dylib contains the expected observer-handoff symbols but
no runtime-admission, runtime-composition, acquisition, runtime-host-handoff, or
preacquired-safety-gate symbol. No live HID operation was run.

This completes the observer's local proof, not executable admission. Its receipt
deliberately contains no runtime session, Root generation, journal, launch, or
authorization identity. A separately reviewed adapter must bind the exact
observer run to that admission evidence. Steady-state control-event delivery,
asynchronous application-quit teardown, and repeated-session rollover policies
also remain prohibited from executable integration until their own review and
authorization.

The productless observer-to-admission handoff milestone adds
`MXErgoPrecisionRuntimeHostHandoff` as a one-shot bridge without adding a
library product or executable dependency. `MXErgoObserver` now exposes a
package-only, non-forgeable capability for one exact run. The exact-run stop
validates that capability while observer start and did-finish cleanup are
excluded by the same lock, so stale admission work cannot stop a replacement
run. A completed matching run may replay its terminal receipt; a foreign or
different run fails with both expected and available run identities.

The adapter copies only launch ID, transaction session, Root generation, and
captured observer run from the reviewed admission intent. Mismatched call
arguments fail before the stop boundary. Identical concurrent callers share one
uncancelled task and one sticky outcome, so caller cancellation cannot abandon
physical drain. Success requires the exact captured run, final zero-pending
state, quiesced callback delivery, and `managerClosed`; `neverAcquired` and the
exact uncertain close return fail separately. Only after those checks does the
adapter invoke its mandatory evidence provider and require a fresh exact
session and Root-generation match. It never constructs proof by echoing caller
arguments alone.

One new observer capability test and nine adapter tests raise the package total
to 288, all passing. They cover foreign-run rejection, binding mismatches with
zero effects, exact receipt validation, pending/callback/ownership failures,
run-specific timeout and cancellation evidence, post-stop evidence drift,
coalesced cancellation-resistant teardown, sticky terminal replay, and static
graph isolation. A fresh signed menu-app build has only seven targets in its
dependency graph and still excludes admission, host handoff, composition, and
acquisition. Its signature is valid on disk, satisfies its designated
requirement with Team ID `XW848M73T3` and Hardened Runtime, and its debug dylib
contains the expected observer receipt/run symbols but no host-handoff adapter
or dormant-runtime symbol. No live HID operation was run.

The observer-run admission-binding milestone adds the captured run identity to
`PrecisionRuntimeAdmissionIntent` and its one-use authorization. Host handoff
must name that same run before it can stop the observer, and the admission
receipt is rejected when the run identity drifts. `MXErgoObserver` now accepts a
non-forgeable restart fence for one captured run. A clean stop no longer makes
the observer startable while that fence is held; abandoning the holder does not
lift it. Only an explicit rollover release after ordered shutdown, or an unused
bound session, can allow another observer run.

`MXErgoPrecisionRuntimeLifecycle` is the productless executable-shaped owner of
that fence. It captures the exact running observer, requires the reviewed intent
to name that run, installs the fence before constructing the host-handoff
adapter, retains the fence through admission and runtime ownership, and refuses
to release it while the runtime still exists. Quit and process abandonment keep
the observer blocked. The target has no product, IOKit import, app/helper
dependency, or executable edge.

Coordinator, admission, host-handoff, and lifecycle tests raise the package
total to 298, all passing. They cover foreign fences, duplicate installation,
post-stop blocking, authorization/run mismatch, invalid handoff receipts, failed
admission that still holds the fence, shutdown without release, and explicit
rollover. A fresh signed menu-app build verifies on disk and satisfies its
designated requirement; its debug dylib contains the observer restart-fence
and handoff-run symbols from `MXErgoHID`, but no lifecycle-owner, host-handoff
adapter, or admission module. No live HID operation was run.

The executable-owner milestone adds public product `MXErgoPrecisionRuntimeOwner`
and wires it into the menu app. After a successful software-only Precision
readiness review, **Bind dormant runtime owner…** captures the current observer
run, requires `notAuthorizedForExecution`, installs the restart fence, and
constructs the host-handoff adapter. It does not admit the runtime, send HID,
or change the MX Ergo. Stop still works; Start observer stays blocked while the
fence is held. **Release for session rollover…** is the only path that lifts the
fence so a new observer run may begin. Quit awaits `prepareForQuit()`, which
shuts down an admitted runtime if one ever exists and never releases the fence.

The inner lifecycle, admission, host-handoff, composition, and acquisition
targets remain without their own library products. `App/` still contains no
`admit` or `IOHIDDeviceSetReport` call, and the owner façade does not expose
admit. Because the owner product depends on the lifecycle target, the linked
debug dylib now imports `IOHIDDeviceSetReport`; no menu-app path invokes it.
Control-event delivery is still unwired.

Owner, lifecycle, admission, and app-source isolation tests raise the package
total to 302, all passing. They cover bind-without-observer failure, quit that
keeps the fence, rollover rejection while a runtime still owns the device, and
the absence of admit/SET from the owner façade and `App/` sources. No live HID
operation was run.

The confirmed-admission milestone lets the menu app call `confirmAdmission`
on the public owner after bind. That issues a one-use authorization for the
bind-time activate intent, requires a second explicit confirmation, rescans
for BetterTouchTool and Logi Options, stops the captured observer through the
existing host-handoff adapter, and opens the Precision runtime. A matching
`confirmDeactivation` issues a subsequent restore authorization. Session
rollover remains blocked while the runtime owns the device. Quit still shuts
the runtime down without an inverse SET, so deactivate first if the button
must return to its baseline.

`App/` still contains no `PrecisionRuntimeAdmissionFactory` or
`IOHIDDeviceSetReport` call. Diverted Precision HID++ notifications are now
copied from the runtime input path, resolved only for CID `00ED`, and delivered
as controller intents. A short Precision tap can mute when the Audio test is
on. While admitted, a fence-free wheel observer reads generic-desktop wheel
notches and feeds them to the owner; OS scroll is swallowed only while
Precision is held. Other buttons remain with the OS/BetterTouchTool.

Wheel-volume tests raise the package total to 311. They cover Precision-held
volume conversion, the held flag, and a fence-free wheel observer that does not
register vendor reports or SetReport. No live HID write was run in automated
tests.

The reconnect-while-diverted milestone surfaces a physical disconnect through
the existing input removal callback into composition, admission, and the public
owner. Disconnect stops control-event delivery, wakes in-flight transport, and
runs the existing ordered shutdown without an inverse SET, retry, or automatic
re-admit. If the durable lifecycle was still active, shutdown classifies
recovery-required. Session rollover remains blocked while the runtime owns the
device and becomes available after that shutdown, including when Precision may
still be diverted on the hardware. Reconnect is a new observer session; the old
connection epoch is not reused. The menu app shows active versus
recovery-required status. Explicit recover from `App/` is the following milestone.

Disconnect and rollover tests raise the package total to 313. They cover
fail-closed operations after disconnect, recovery-required shutdown without SET,
event delivery stopping, and rollover after a diverted shutdown. No live HID
write was run in automated tests.

The explicit reconnect-recovery milestone lets bind infer `.recover` from a
recovery-eligible schema-v3 runtime journal, including `.running` plus
`.appliedVerified` after a diverted disconnect. Readiness for that path accepts
a live Precision GET at the reviewed baseline or active state and still requires
a clean schema-v2 baseline, matching physical identity, and unchanged runtime
journal bytes. **Recover Precision…** is a separate confirmation from admit; it
can send one restore SET and never auto-retries. `App/` still contains no
`recoverExplicitly()` call.

Reconnect-recovery tests raise the package total to 319. They cover recover
readiness on a new epoch, operation inference, recover-bound owners rejecting
admit, activate-bound owners rejecting recover, and an admitted recover that
calls recover rather than activate. No live HID write was run in automated
tests.

The recover fail-closed milestone refuses a second restore SET after an
`outcomeUnknown` restore attempt. Observing that the button is still diverted
does not rewrite the journal as a clean appliedVerified state. Admission,
reconnect-recovery readiness, and the owner Recover control all lock. A GET-only
probe remains the next physical step; there is no automatic retry or inverse SET.

Ambiguous-restore tests raise the package total to 321. No live HID write was
run in automated tests.

The mapped-control diversion milestone reviews the five BTT-mapped CIDs
(`0052`, `0053`, `0056`, `005B`, `005D`) as a fail-closed, in-memory apply/restore
plan. It requires the same physical MX Ergo identity and a clean firmware-bound
baseline. Precision CID `00ED` stays on its existing runtime. The plan is not an
authorization: the menu app still sends no mapped-control SET and synthesizes no
desktop, back/forward, or Mission Control events.

Mapped-control diversion tests raise the package total to 325. No live HID
write was run in automated tests.

The mapped-control readiness milestone wraps that plan in a Precision-style
review: two competitor scans, exact unchanged baseline bytes, current Root and
firmware generations, and matching physical identity plus feature index. The
result is immutable `notAuthorizedForExecution` evidence. The menu app still
constructs no mapped-control coordinator, SET path, or event synthesis, and it
invalidates the review when a competitor launches or evidence changes.

Mapped-control readiness tests raise the package total to 330. No live HID
write was run in automated tests.

The mapped-control action-plan milestone binds those five reviewed CIDs to the
2026-08-25 BTT replacements: upper/lower thumb → desktop left/right
(Control+Arrow), wheel tilt → back/forward (3-finger swipe), and wheel click →
Mission Control (Control+Up). The result is immutable
`notAuthorizedForExecution` evidence. The menu app still posts no CGEvent,
sends no mapped-control SET, and does not admit extra CIDs.

Mapped-control action-plan tests raise the package total to 333. No live HID
write was run in automated tests.

The mapped-control event-delivery milestone compiles a pump that resolves
diverted HID++ notifications only for an explicitly admitted subset of those
five CIDs, one at a time. The menu review constructs that pump with an empty
admitted set as `notAuthorizedForExecution` evidence. Precision stays on its
existing pump. The menu app still posts no CGEvent, sends no mapped-control
SET, and does not admit extra CIDs.

Mapped-control event-delivery tests raise the package total to 337. No live HID
write was run in automated tests.

The mapped-control GET-only preflight milestone reviews five independent
`GetCidReporting` packets for those CIDs, requires an exact baseline match, and
caps the future live path at five packets. The menu app still sends no mapped
GET or SET, posts no CGEvent, and does not admit extra CIDs.

Mapped-control GET-only preflight tests raise the package total to 340. No live
HID write was run in automated tests.

The live mapped-control GET preflight milestone sends those five packets
sequentially through the observer, fails closed on the first mismatch, and
never retries. Completing the five exact-baseline GETs is still
`notAuthorizedForExecution`: no SET, no extra CID admission, and no event
synthesis.

Live mapped-control GET sequencer tests raise the package total to 343. No SET
was run in automated tests.

The next review must keep those five CIDs unauthorized until the Precision
recover lock has been used on hardware, then can admit them one at a time.

The first live Precision admission milestone moves the runtime from dormant to
proved. With BetterTouchTool and Logi Options fully quit and the trackball
power-cycled, the signed menu app resolved Root to feature index `0x0A`,
matched the firmware identity, passed the exact-baseline preflight, reviewed
readiness as `NOT AUTHORIZED`, bound the owner, and admitted the runtime. The
schema-v3 runtime journal was created for the first time from the clean
schema-v2 baseline.

One apply SET (`11 00 0A 3E 00 ED 03 …`) and one restore SET
(`11 00 0A 3E 00 ED 02 …`) were dispatched, each exactly once. The device
answered both with a correlated reply carrying zeroed parameters rather than an
exact echo. Both were classified `correlatedNonEcho` and retained as evidence
only; the independent verification GETs returned flags `01` and then the exact
baseline, so both attempts recorded `verified`. The journal reached revision 6
at `restoredVerified` with no other control dirty, and quitting wrote nothing
further. The schema-v2 baseline hash was unchanged throughout.

This is the direct hardware refutation of the 2026-08-30 failure mode. That
trial helper demanded a full echo and recorded `outcomeUnknown` for a SET that
had behaved correctly. The production rule — acknowledgement is evidence, a
separate GET is proof — is now validated against the physical device.

Two presentation defects were found and fixed. The one-use admission
authorization is minted inside `bind()` with a ten-minute lifetime, so pausing
between binding and admitting expires it; the abort was correctly fail-closed
with no observer stop, lease, journal write, or HID frame, but the Admit control
stayed enabled while it could never succeed. It is now disabled on expiry with
an explicit instruction to roll over and re-bind. Separately, the status line
read `Precision diverted (active)` after a verified restore because it was
derived from whether the runtime was admitted rather than from the diversion
status; a restored control now reports as restored. Neither defect affected
device handling.

Precision tap-to-mute and hold+scroll volume remain unexercised on hardware: the
control was restored before the audio path was tried. The five mapped CIDs
remain `notAuthorizedForExecution`; their live GET preflight was run again in
the same session and matched the firmware-bound baseline for all five.

The package total stays at 344, all passing with none skipped; the status-label
regression is guarded by an extension to the existing App-source isolation test
rather than a new test function. This was a live HID session: two SETs were
dispatched, each exactly once, and both verified by independent GET.

The second live session set out to exercise Precision tap-to-mute and hold+scroll
volume. The diversion lifecycle completed cleanly a second time — apply verified,
restore verified, both replies `correlatedNonEcho`, final `restoredVerified` with
the schema-v2 baseline unchanged — but **the audio path did not work**. With
Precision verified diverted at `flags 01` and audio execution enabled, tapping
did not mute and hold+scroll did not change volume; the frontmost page scrolled
normally, so the scroll swallow never engaged. One missing input explains both
symptoms, because the swallow is gated on the held flag that the same
notification stream feeds.

The cause was not determined and is deliberately not guessed at. The unsolicited
filter and the notification decoder both require device index `0xFF` while every
observed request and response from this device uses `0x00`; the alternative is
that the filter is correct and the fault lies further down the delivery path.

A claim originally made here — that the calibration panel had historically named
Logitech controls and so demonstrated `0xFF` was correct — has been withdrawn.
It rested on a runbook instruction and a capability bullet, not an observation.
No HID++ notification frame has ever been captured by this project. `PrecisionCallbackInputChannel`
already counts unsolicited and dropped frames, but neither count is surfaced
through composition, the owner facade, or the app, so the runtime cannot say
whether frames arrived and were rejected or never arrived at all. Surfacing that
evidence is the prerequisite for any change to the input path.

The session also confirmed that no runtime-journal rotation exists. A schema-v3
journal models exactly one apply/restore lifecycle, and once `completed` it
permits neither activate nor recover, so a second session required moving the
file aside by hand. The second occurrence surfaced only as
`Bind failed: invalidIntent`. This blocks daily use.

`Deactivate Precision…` stayed enabled after a verified restore — the same
admitted-versus-diverted conflation as the status label — and is now gated on the
diversion status. The status-line fix was confirmed on hardware.

The package total stays at 344, all passing with none skipped.

The input-diagnostics and journal-rotation milestone closes the two blockers the
2026-09-04 sessions exposed. Neither adds a HID operation, a SET path, or an
event-synthesis path.

`PrecisionInputDiagnostics` makes the input path observable. The callback
channel already counted accepted, dropped and unsolicited frames, but nothing
could read them, so the runtime could not say whether a diverted-control
notification had arrived and been refused or had never arrived. A new
`observedCount` counts frames that passed report type, report ID, length,
device identity, connection epoch and Root generation checks — recorded before
the notification test — together with the last such frame's bytes. The gap
between `observedCount` and `unsolicitedCount` is the discriminator, and the
last frame's second byte is the exact datum the notification filter tests
against.

The counters are forwarded, never re-derived: the input session is the only
place that observes, and ownership, assembly, acquisition, composition,
admission and lifecycle each add a pull-through accessor with a nil default so
existing fakes and endpoints stay valid. The public owner projects them with an
interpretation, so a hardware session ends with a conclusion rather than a table.
Diagnostics gate nothing and are readable while an operation is in flight; they
take no reservation and hold no lock.

`PrecisionRuntimeJournalRotation` retires a spent runtime journal. A schema-v3
journal models exactly one apply/restore lifecycle, and once `completed` the
admission policy permits neither activate nor recover, so a second session was
impossible and the failure surfaced only as `invalidIntent`. Rotation is
deliberately not part of bootstrap: bootstrap runs inside an already-authorized
admission, and retiring durable evidence there would let one confirmation both
discard a journal and open the device. It is a separate, separately confirmed,
HID-free operation that renames rather than deletes, holds the canonical
device-operation lease, re-derives the review under that lease before moving,
refuses an existing archive, and proves the move afterwards by hash. Every
non-terminal state — active, ambiguous, conflicted, recovery-required, or any
dirty control — is refused, because those are exactly the journals a later
recover reads.

Three package edges were added deliberately and their pinned manifest counts
updated by hand: the owner now reaches the journal module for rotation, and
admission, lifecycle and owner reach the transport module for the diagnostics
type. Four pinned `package` API lists in the ownership, assembly and acquisition
isolation tests were updated to name the new accessors. That friction is the
mechanism working: no dependency edge or cross-module symbol can appear here
without a person editing a number.

Ten rotation and diagnostics tests raise the package total to 354, all passing
with none skipped. They cover archive-and-prove, every refused state, foreign
lease, change-after-review, existing archive, symlinked journal, absent journal,
a frame that arrived but was not routed, a routed notification, and a frame from
a foreign epoch that must not be counted as observed. A fresh signed menu-app
build verifies on disk and satisfies its designated requirement. No live HID
operation was run.

A zero-risk read-only observation on 2026-09-04 substantially changed the
mapped-control plan. With BetterTouchTool quit and no diversion in play, both
thumb buttons were observed arriving as ordinary HID buttons `0x08` and `0x10`
in report `0x02`, while the Precision button produced no ordinary report at all.

This is consistent with the 2026-08-27 baseline, which recorded all nine
reprogrammable controls at `flags 0000` while BetterTouchTool was in daily use:
BetterTouchTool never diverted anything, and remaps at the event layer instead.

Precision is therefore the only control on this device with no representation
outside HID++, which is why it required temporary diversion and why that runtime
was worth building. Conversely, if wheel tilt — still unobserved — also proves
ordinary, then none of the five mapped CIDs require diversion, and the planned
multi-CID SET path would be solving a problem this hardware does not have.
Replacing BetterTouchTool for those controls becomes an event-tap problem with
no device write, which is categorically lower risk than anything attempted so
far.

No code changed and the five mapped CIDs remain `notAuthorizedForExecution`. The
conclusion is held open pending the wheel-tilt observation.

The wheel-tilt observation completes the picture and retires the mapped-control
SET path before it was built. Tilting left and right navigated a horizontal
carousel in the corresponding directions, so macOS receives signed horizontal
scroll deltas with nothing diverted. That agrees with the device's own control
list, where `005B` and `005D` are Left Scroll and Right Scroll in Logitech's
standard numbering.

Every one of the five mapped CIDs is therefore already delivered to macOS as an
ordinary mouse button or scroll axis. The planned multi-CID SET path — widened
transport allowlist, per-CID packet tables, multi-CID admission policy, mapped
lifecycle actor — would have been solving a problem this hardware does not have.
It is cancelled.

Precision remains the sole control with no ordinary representation and the only
one that will ever need a SET. Its runtime is built and proved on hardware.

Replacing BetterTouchTool for the other five becomes an event-layer problem with
no device write: observe the ordinary reports, suppress the default behaviour,
post replacements. Two things the project lacks are now on the critical path
instead — an Accessibility permission gate, and a horizontal scroll path, since
the wheel observer decodes only vertical motion today.

The existing mapped-control diversion plan, readiness audit, action plan, event
pump and GET-only preflight are superseded rather than wrong. They remain as
reviewed evidence and stay `notAuthorizedForExecution`. No code changed.

The Accessibility gate and horizontal scroll milestone adds the two things the
cancelled SET path left on the critical path. Both are observation and
permission only: nothing posts an event, and no HID output was added.

Wheel tilt now has a decoder. `HIDElementValueDecoder.horizontalScrollNotches`
matches AC Pan on the Consumer page, which is how this device reports tilt —
confirmed on hardware and consistent with its exposing CIDs `005B`/`005D`, Left
Scroll and Right Scroll. The observer previously installed a single input-value
matching dictionary for the generic-desktop wheel, which silently missed the
other axis; it now installs both through
`IOHIDManagerSetInputValueMatchingMultiple`. A new `horizontalScroll` observation
carries it to the app, where it is counted and displayed beside the vertical
wheel. It resolves no intent and suppresses nothing: macOS already delivers tilt,
and the app has no business interfering with it yet.

The Accessibility gate mirrors the existing Input Monitoring one:
`AXIsProcessTrusted()` on launch and on every foreground refresh, a status row,
and a button that opens the Accessibility pane. It deliberately does not call
`AXIsProcessTrustedWithOptions` with the prompt option — an unrequested
permission dialog is the wrong shape for this app, and the grant matters only
once event posting exists. The row states plainly that nothing in this build
posts events and that the MX Ergo is unaffected either way.

Three decoder tests raise the package total to 357, all passing with none
skipped. They cover AC Pan decoding in both directions, stationary and unrelated
consumer usages, and — most importantly — that the two scroll axes never decode
each other, since keeping them distinguishable is what makes tilt usable without
diversion. A fresh signed menu-app build verifies on disk and satisfies its
designated requirement. No live HID operation was run and no CGEvent was posted.

The Precision audio path works on hardware. A quick tap mutes and unmutes,
holding Precision and scrolling changes system volume, and the page underneath
stays still. This supersedes the earlier finding on the same day that it did not
work.

The input diagnostics settled it. Captured while diverted and active:
`observed 21 · notifications 18 · matched 3 · dropped 18`, with a press frame of
`11 FF 0A 00 00 ED …` — device index `0xFF`, feature index `0x0A`, function
`0x00`, control ID `00ED` — and an all-zero release following it. The
notification filter was therefore never at fault, and the candidate raised
earlier, that it should have matched device index `0x00`, is disproven.

Why the earlier session failed is not established with certainty. The leading
explanation is the Accessibility grant: the scroll swallow uses a `CGEvent` tap
created with `.defaultTap`, which can suppress events, and a suppressing tap
requires Accessibility rather than Input Monitoring alone. A failed `tapCreate`
would produce exactly the observed symptom of the page scrolling while Precision
was held. The permission row that makes the requirement visible was added
between the two sessions.

Two contributing factors are certain, and both were instruction errors rather
than defects: the tap threshold is 0.3 s and the earlier session was run under an
instruction to press slowly, which is a hold by design; and in the session after
that the Audio test was never enabled.

The app therefore has a hard dependency on Accessibility that was previously
undocumented and, before the diagnostics existed, undiagnosable.

The event layer exists. `MXErgoEventSynthesis` decides and `MXErgoEventTap`
acts, and neither can reach a signed binary: both are productless, absent from
`project.yml`, the generated project, and `App/`, and neither declares a single
`public` symbol. A suppressing global event tap is a new capability class, so
promotion is a separate review rather than a consequence of building it.

Nothing about this touches the device. The five controls it replaces —
wheel click, both thumbs, both wheel tilts — are believed to be delivered to
macOS as ordinary mouse buttons and scroll axes. The thumbs and the tilts were
observed on 2026-09-04; the wheel click was not, and saying otherwise here was
an error corrected on 2026-09-05. Precision remains
the sole control needing HID++, because it emits no ordinary report at all.

The split is between a half that decides and a half that can act. The policy
half imports no CoreGraphics whatsoever — an isolation test strips comments and
asserts the token is absent from its code — so it is a pure value machine that
structurally cannot cause an event to exist. Every question worth asking is
answered there, by ordinary tests, rather than by installing a tap on a live
session and finding out.

The tap half holds the project's only `CGEvent.post` call site, for the same
reason `MXErgoPrecisionIOHIDOutput` holds the only `IOHIDDeviceSetReport`:
"what can this app inject into my session" should be answerable by reading one
function. The isolation test asserts one such site across the whole `Sources`
tree and exactly two suppressing `CGEvent.tapCreate` sites — the Precision
scroll swallow and this one. Both halves of that were proved by breaking them:
wiring `MXErgoEventTap` into `project.yml` fails the test, and adding a second
post call fails it twice.

Suppressing input is a different hazard from writing to the device. It is fully
reversible, but while it is wrong the pointing device feels broken and the user
may not be able to click their way out of it. So the layer fails open
everywhere. The tap's mask admits exactly `otherMouseDown`, `otherMouseUp` and
`scrollWheel`, and the primary and secondary buttons have no case in the
observed-event type at all, so no reachable state can swallow an ordinary click.
An undecodable event passes through. A failed injection passes the original
through rather than swallowing it. Continuous horizontal scroll — a trackpad
gesture — is never suppressed, and a mixed-axis scroll event is passed through
so that catching the horizontal half cannot silently eat the vertical half that
belongs to the Precision volume path.

Two details are worth stating because they are the ones that bite. A release is
suppressed only if this policy suppressed its press, never because the plan
happens to bind that button; consulting the plan would hand the frontmost app a
mouse-up it never saw a mouse-down for. And the tilt latch exists because one
physical flick produces several AC Pan notches: firing per notch would send a
browser several pages back from one gesture, so a fired direction is held off
for 0.35 s, while a deliberate reversal fires immediately, since correcting an
overshoot is the one case where the delay would be felt.

`MappedControlActionPlan` binds wheel tilt to a three-finger swipe, and macOS
exposes no public gesture-synthesis API. Rather than drop back and forward, the
reviewed substitution is the pair of mouse buttons the system already reads as
back and forward — which is exactly what this trackball's thumb buttons natively
emit, and exactly what those thumbs are being rebound away from. The swap is
deliberate. The plan is derived from `MappedControlActionPlan` rather than
restated, so the two descriptions of what the buttons should do cannot drift.

One thing is unverified and is marked as such in code. Which sign of
`scrollWheelEventDeltaAxis2` corresponds to a *left* tilt has never been
observed on this device; the 2026-09-04 session confirmed only that tilt moves a
carousel, not in which direction the delta ran. Back and forward may therefore
be reversed. `HorizontalScrollConvention` is the single place that decides, both
values are tested, and one hardware session settles it.

Re-enabling a tap that macOS disabled by timeout is not the retry the safety
rules forbid. That rule is about re-sending a command the device may already
have acted on; nothing here reaches the device, and re-arming is the documented
contract of an event tap. The comment at that call site says so, because it is
the kind of line a later reader would otherwise delete on principle.

Twenty-five tests raise the package total to 383, all passing with none skipped.
All four signed targets build and the menu app verifies on disk. No live HID
operation was run, and no CGEvent has ever been posted: the one call site that
could is unreachable from every runnable target.

While counting the productless targets for this entry, three figures in
`SAFETY.md`, `CLAUDE.md` and the `safety-gate` skill turned out to be wrong.
They read "fourteen of twenty package targets" and "thirteen build-graph
isolation tests"; the real figures before this milestone were thirteen of
eighteen and fourteen. They are now fifteen of twenty and fifteen, counted from
the manifest rather than from memory. In a project that treats counts as
evidence, a wrong count is a defect, so it is recorded here rather than quietly
fixed.

One further finding, pre-existing and not from this milestone. Two tests fail
intermittently under parallel load: `adapterDeadlineAfterApplyEntryIsPromptOutcomeUnknownAndStillDrains`
and `concurrentDisconnectWakesABlockedReplyReadAndPoisonsTheAttempt`, both with
`.timedOut` from the suites' one-second wall-clock `waitUntil` helper. Verified
by running the suite six times with this milestone stashed: it reproduces at
`HEAD` at a similar rate, so it is not a consequence of adding two test targets.
It matters because `scripts/verify.sh` is the gate the whole hardware workflow
rests on, and a gate that goes red at random teaches people to re-run it until
it is green. Left as-is here rather than fixed inside an unrelated change.

The wheel-tilt sign is settled, and the answer is that there was no sign to
compile in. Four readings on 2026-09-05, tilting left and right under each
setting of "natural scrolling", show the device's own AC Pan value invariant at
`-1` left and `+1` right, while the scroll event macOS publishes from it inverts
with the preference: axis2 `+1` for a left tilt with natural scrolling off,
`-1` for the same tilt with it on.

So `HorizontalScrollConvention` was the wrong shape, not merely the wrong value.
It is now derived from `com.apple.swipescrolldirection` instead of fixed, and
`EventSynthesisTap.setConvention` exists because that preference can change at
any moment from System Settings — without it, flipping natural scrolling would
silently swap back and forward until the tap was restarted. A promotion of this
layer has to call it from the same refresh path that already re-reads the
permission statuses.

The constant that was there — positive means left — turns out to have been
correct, but only for natural scrolling off and only by luck. It was recorded as
unverified, which was the right description of it; had it shipped, half the
machines it ran on would have navigated backwards.

Two smaller things follow. The `MXErgoObservation.horizontalScroll` comment
claiming "positive to the right" was a specification claim repeated from the HID
usage tables; it is now an observation, and so is the same claim in the tilt row
of the menu. And the invariance is itself useful: the AC Pan stream is both
attributed to this MX Ergo and unaffected by the preference, which makes
correlating it with the CGEvent stream the eventual answer to device
attribution — a second mouse's tilt wheel is currently indistinguishable and
would be remapped identically. That was not built here.

The diagnostics that produced the readings reuse the existing wheel tap in a
non-suppressing mode rather than adding a second one, and are off after every
launch. Two tests raise the package total to 389, all passing with none
skipped, including one that runs all four recorded hardware readings back
through the decoder and asserts a left tilt decodes as a left tilt under both
settings. No live HID operation was run: no device was opened, no lease taken,
no SET sent, nothing suppressed, and no CGEvent posted.

The event layer is promoted. This is the review rule 1 requires, and it takes
the shape a promotion should: `MXErgoEventSynthesis` and `MXErgoEventTap` keep
no product and no `public` symbol, and a new `MXErgoEventLayer` facade becomes
the only thing the app may name. The facade exposes start, stop, the reviewed
bindings, and read-only counters — no tap, no poster, no policy, and no way for
a caller to supply different bindings, since the plan is derived from
`MappedControlActionPlan`. A test pins its public declaration list, so widening
the surface of the one type that can take over the pointing device means
editing that list on purpose.

The build-graph diff is what makes the change checkable: `project.pbxproj` gains
exactly one product dependency and nothing else. That is the whole reason the
generated file is tracked.

It ships **off after every launch**. Turning it on requires Accessibility and
takes over wheel click, both thumbs and both wheel tilts globally, which the
status line says in those words along with the instruction to quit
BetterTouchTool first. The escape hatch is structural rather than promised: the
tap's mask excludes the primary and secondary buttons, so an ordinary click
cannot be swallowed and the menu stays reachable to switch it off. Quitting
stops the layer, and unlike a diverted control that needs no inverse of any
kind — the remapping exists only while the tap does.

Two interactions had to be settled rather than reasoned about. The scroll-axis
diagnostics and the layer both claim the scroll stream, and which one saw an
event first would depend on tap insertion order, so they are mutually exclusive
toggles. And the natural-scrolling preference is now pushed into the running tap
from the same refresh that re-reads the permission statuses; without that,
flipping it in System Settings would silently swap back and forward until the
next launch.

`EventLayerReview` deliberately carries no `notAuthorizedForExecution` marker,
and `EventSynthesisReviewSnapshot`, which did, is deleted. That marker means "a
review happened and nothing more", and repeating it about a layer that can now
execute would have been false. The HID++ diversion plans still carry it, because
for them it is still true.

Promotion also exposed a defect in the mechanism the promotion relies on. The
isolation tests extract the manifest's products half by splitting on
`"targets: ["`, which first matches inside the *first product's own* targets
list — so twelve of those checks were scanning two lines of `Package.swift` and
asserting absence from almost nothing. The pinned occurrence counts were doing
the real work, alone. The split is now line-anchored, and the fix was proved by
adding a product for `MXErgoPrecisionWriteLifecycle` at the end of the list,
where the truncation used to hide it, and watching the products assertion fail
at the exact line that could not fail before.

The same look found that `MXErgoPrecisionTransport` had no build-graph isolation
test at all — the only productless target with none, and an omission rather than
a deliberate exception like `MXErgoRestoreTrialIOHID`. It has one now: no
product, absent from `project.yml`, the generated project and `App/`, and a
pinned count of nineteen manifest occurrences.

`scripts/verify.sh` now also refuses `.post(tap:` and `CGEvent.tapCreate` in
`App/`. The app goes through the facade; the injection door stays in one place.

Sixteen tests raise the package total to 394, all passing with none skipped, and
all four signed targets build. No live HID operation was run. Synthetic events
can now be posted for the first time in this project's history, but only while
the toggle is on, and none was posted by the test suite.

The first live run of the event layer found that a key chord was not being
emitted faithfully. Wheel click did not open Mission Control. The system side
was ruled out first: the Spaces shortcuts are explicitly enabled in
`com.apple.symbolichotkeys` and Mission Control sits at its enabled default, so
the shortcut existed and something in the injection was wrong.

The defect is that a modifier flag was set on the arrow key event and nowhere
else. That satisfies an ordinary application, which reads the flags off the
event it receives, but it never makes Control *be* down — and Mission Control
and the Spaces shortcuts are symbolic hotkeys, matched by the window server
against the modifier state it believes is current. A flag appearing out of
nowhere on one key event does not change that state.

`SyntheticKeyChordPlanner` now expands a chord into the transitions a real
keyboard emits: each modifier pressed in a fixed order, the key pressed and
released with all of them down, then each modifier released in reverse. It
lives in the policy half and produces plain values, so the sequence is pinned by
tests rather than only observed in behaviour — including that every chord ends
with all modifiers released, since one left down would make the whole machine
behave as though a key were stuck, which is worse than the remap not working.

The own-event counter is now shown in the layer's summary. The layer both
swallows mouse buttons 3 and 4 and injects them, so it must recognise its own
events by their marker; that marker had never run, and a failure would have
shown up only as tilt switching desktops rather than navigating.

Three tests raise the package total to 397, all passing with none skipped. No
live HID operation was run. Whether the chord now reaches Mission Control is
not yet established — that needs the next physical session, and this entry is
written before it.

An unsupported claim is withdrawn, and it is the likely cause of the live
failure. `EventSynthesisPlan` stated that the wheel click's HID button mask
`0x04` had been "observed on this MX Ergo on 2026-09-04". The thumb masks were
observed that day. The wheel click was not — that session's own record lists it
under *Not observed in this session*, alongside right click and both wheel
tilts. The value came from `StandardMouseButton.wheel` in `MXErgoCore`, which is
a specification assumption about how a three-button mouse reports rather than a
measurement of this trackball.

This is the second time the same author has written a plausible inference into
this project's audit trail in the voice of an observation, after the
calibration-panel claim withdrawn on 2026-09-04. Both carried a date that made
them look sourced.

It matters here because it has a consequence. Wheel click did not open Mission
Control on either live run of the event layer, while the question of whether
this device even emits button 2 had never been asked. A binding keyed on a
button number the device never sends produces exactly the observed behaviour:
the tap receives the event, finds no binding, and passes it through untouched.
The constant stays at `2` and is now labelled inferred; one press with the
calibration panel open settles it.

Two rounds of speculative fixes preceded this, and neither was preceded by a
measurement. The symbolic-hotkey work in the previous entry stands on its own —
a chord that never presses its modifier is wrong regardless — but it was
committed as a fix for a failure whose cause had not been established, which is
the mistake this project's own runbook exists to prevent.

A real Control+Up opens Mission Control on this machine; the tap's synthetic one
does not. The counters settle everything upstream of that: `observed 2498 ·
passed 2476 · suppressed 22 · posted 11 · own 0`, where `suppressed` is exactly
twice `posted` — one down, one up, one chord per press. The wheel click is seen,
matched, suppressed, and a chord is posted. The failure is entirely downstream.

The calibration panel also settled the withdrawn claim: `Wheel click down (mask
0x04)`. The inferred constant was right. It was still an inference when it was
written down as an observation.

A confound turned up while looking for a second chord to compare against. This
machine has exactly one Space, so Control+Left and Control+Right cannot switch
desktops whatever the code does, and the thumb buttons are not evidence of
anything. All three chords were unverifiable, each for a different reason.

That leaves two candidates and no way to choose between them by reading code:
the chord is not something the system will act on, or a chord posted from
*inside an event-tap callback* is dropped. They have different fixes and look
identical from outside. So this milestone adds the measurement rather than a
third speculative fix: two buttons post the wheel click's chord from the main
thread, one byte-for-byte as the tap posts it and one carrying the numeric-pad
and secondary-function flags that macOS sets on a real arrow key.

If A works and the tap does not, posting from within a callback is the problem.
If A fails and B works, the flags are. If both fail, neither candidate survives.

`SynthesizedModifiers` grows those two flags, and the planner keeps them off the
modifier transitions, because nobody presses Fn to type an arrow — they are a
property of the key. A test pins that.

One test raises the package total to 398, all passing with none skipped. No live
HID operation was run. The chord's fate is not yet established, and this entry
is written before the session that settles it.

**Superseded below: the A/B result did not reproduce and this entry's central
claim is withdrawn.** It is left in place because retracting a milestone by
overwriting it would hide exactly the kind of mistake this ledger exists to
record.

Settled: the window server drops an event posted from inside an event-tap
callback. That alone is why every remapped control did nothing.

A real Control+Up opens Mission Control. Posting the identical chord from a
button opened it too. Posting the same chord plus the numeric-pad and
secondary-function flags a real arrow key carries did nothing at all. So the
chord was always right, the position it was posted from was always wrong, and
the fix that was about to be shipped would have broken a working chord.

Delivery is now deferred until the callback has returned. Construction stays
inside it, because construction is the only failure this layer can detect —
`CGEvent.post` reports nothing — so the fail-open guarantee is unchanged: a
replacement that cannot be built means the original passes through. What changed
is that `apply` now hands back a prepared delivery instead of posting, and the
callback runs it from a block on the tap's own run loop. Same thread, so events
still reach the system in the order they arrived.

A test pins the property that broke: applying a decision must build the
replacement and **not** deliver it. Without that, a regression here stops the
remap silently while every counter still reads as success, which is exactly how
this failure presented.

`SAFETY.md` rule 11 is amended rather than quietly widened. The fail-open clause
now says *built* rather than *injected*, and the deferral is stated with the
evidence for it.

Two speculative fixes were committed for this failure before any measurement
existed: a modifier-transition change, and before that an inferred button mask
written into the audit trail as an observation. Both were plausible; neither was
evidence. The measurement that settled it took one session and one press. The
modifier-transition change stays, because a chord that never presses its
modifier is wrong regardless and the working variant includes it — but whether
it was ever necessary is unknown, and is recorded as unknown.

Package total stays 398, all passing with none skipped. No live HID operation
was run.

The A/B chord result did not reproduce. Pressing the same two diagnostic buttons
again gave the opposite answer: A did nothing, B opened Mission Control. The
previous entry's conclusion — that the keypad-flag variant is broken and that
posting from inside the callback is *the* cause — is withdrawn.

The measurement was badly designed, and in a way worth naming. Its observable is
Mission Control, which is a **toggle**: the act of measuring flips the state the
next measurement reads. If both chords work, the first press opens it and the
second closes it, and whether that looks like success depends entirely on an
unrecorded starting state. One explanation, both chords working, fits both runs.
No other candidate does.

Reporting a finding after a single run of a self-perturbing measurement is the
same error as the two speculative fixes before it, wearing better clothes. The
lesson is not "measure first" — that was already the lesson — but that a
measurement needs an observable the measurement does not disturb, and needs to
be repeated before it is written down.

What survives is what rests on the counters rather than on A/B: the wheel click
is observed, matched, suppressed, and a chord is posted, eleven times out of
eleven. And a real Control+Up opens Mission Control on this machine.

The deferred delivery stays. Posting into the tap point currently being serviced
is a documented hazard, the fail-open guarantee is unchanged by the split, and
the test pinning "build but do not deliver" is worth having regardless. But it
is no longer claimed as the fix, because nothing now shows it is. One question
settles that, and it was never the diagnostic buttons: whether wheel click
itself opens Mission Control.

Package total stays 398. No live HID operation was run.

Resolved, and the toggle explanation was wrong too. Asked which of the two
conflicting A/B runs stood, the operator confirmed the second: Control+Up as the
tap built it does nothing, and the same chord carrying the numeric-pad and
secondary-function flags opens Mission Control.

So the reconciliation offered in the previous entry — that both chords work and
a toggle merely flips the observable — is withdrawn as well. It fitted both
reports, which made it attractive, but it was an inference from a contradiction
rather than anything seen, and it went into the ledger as the likely cause when
it should have gone to the operator as a question. Three entries in a row now
have the same shape: a plausible story written down at the confidence of an
observation.

The finding itself is small and specific. macOS reaches the arrow keys through
Fn and reports them in the keypad group, so a real Control+Up carries the
numeric-pad and secondary-function flags alongside Control, and the window
server's hotkey matcher requires them. A synthetic arrow carrying Control alone
is ignored. `SyntheticKeyChordPlanner` derives those flags from the key code
now, because they belong to the key rather than to anyone's fingers, and a test
asserts all four arrows carry them while an ordinary key does not.

It affected all three chords in the plan, all of which are arrows. Neither thumb
button could have worked either — and with one Space on this machine, that would
never have shown.

The deferred delivery is now explaining nothing: chord A failed posted from a
button, outside any callback at all, so the flags account for the entire
failure. It stays, because posting into the tap point currently being serviced
is a documented hazard and the build/deliver split costs nothing and is pinned
by a test, but it is no longer described as a fix for anything observed.

One test raises the package total to 399, all passing with none skipped. No live
HID operation was run. Whether wheel click now opens Mission Control through the
tap is not established by any of this, and only pressing it will say.

All three chords work on hardware. Wheel click opens Mission Control, and both
thumbs switch desktops once a second Space existed to switch to. The keypad
flags were the whole of that failure.

Wheel tilt does not. It is the only binding that injects a **mouse click**
rather than a chord, so it is the one path nothing else has ever exercised.
Reported symptom: tilt left does nothing, tilt right sometimes acts as a click,
apparently at random and sometimes repeating.

"At random" is the informative part. The click is constructed as `.center` —
`CGMouseButton` in Swift spells only left, right and center — with the real
button number written into the field afterwards. If that override does not take,
both tilts post a **middle click**, which does nothing over blank page area and
opens a new tab over a link. Cursor-dependent behaviour is exactly what that
looks like. Unverified.

Two changes. The click now carries a click state of 1, because a real press
does and leaving it at zero says no click happened — the same unfaithfulness
that stopped a synthetic arrow from matching a hotkey, and correct on those
grounds whether or not it is this failure. And the diagnostic buttons now post
the tilt clicks as well as the wheel click's chord, returning the description of
what was actually sent, so a report of what happened can be matched against what
was injected.

Those buttons separate the two candidates that reading the code cannot: the
injected click is not what the system acts on, or the tilt was never observed
and nothing was injected at all. The A/B pair they replace is gone — the
keypad-flag variant won and is now simply what the planner builds.

Package total stays 399, all passing with none skipped. No live HID operation
was run.

The injected click is correct. Posted from a button, tilt left goes back and
tilt right goes forward, which also disposes of the middle-click theory offered
for the "random" behaviour: a middle click opens tabs, and back and forward are
what actually happen. So the button numbers were right all along, and whether
the click state was ever the problem is unknown — it was added on faithfulness
grounds and stays on them.

The counters moved to a timer. Every diagnosis this session has turned on that
one line, and it was hidden behind a button in a menu that also contains a
differently-named log, which is where it was looked for. It now updates once a
second while the layer runs and shows "none yet" rather than vanishing when
empty. `refreshEventLayerDiagnostics` assigns only on change, so a menu that is
open and idle is not redrawn every second for nothing.

What remains unestablished is the thing the buttons deliberately factor out:
whether *physically tilting the wheel* navigates. The button path skips the
observation, the direction decoding, the latch, and the loop-prevention marker —
and that marker matters here more than anywhere else, because the click the
layer injects for tilt lands on buttons 3 and 4, which are the thumb buttons'
own triggers. If the marker fails, a tilt does not fail quietly: it switches
desktops.

Package total stays 399, all passing with none skipped. No live HID operation
was run.
