# Personal v1 release readiness

Updated September 10, 2026. **Release acceptance is incomplete.** This is a
development candidate, not a claim of completed everyday reliability testing.

## Candidate identity

| Item | Recorded value |
|---|---|
| Application source commit | `b0bdf273be7798447516249f7fdb905ca7ea622f` |
| Installed application | `/Applications/MX Ergo Controller.app` |
| Release executable SHA-256 | `44a84c4513c8f2480c613af43b92a40e9a063dce6393f32845ccc69acd2c8a70` |
| Build verification | 521 tests, no skips; four signed builds and audits passed; Release built with Swift warnings treated as errors |
| Retained candidate and logs | `build/volume-feedback-44a84c45/` |
| Previous installed app | `build/volume-feedback-44a84c45/Previous MX Ergo Controller.app` |

Later documentation commits do not change this binary's identity. Installation
and signature verification are recorded in
[the validation history](Evidence/VALIDATION-RECORDS.md).

## Acceptance gates

| Area | Evidence and remaining work |
|---|---|
| Input scope | Global matching-button mappings accepted by the user. Behavior with another mouse still needs observation. |
| Ordinary controls | Five actions and normal clicking/scrolling passed by user report on the earlier `d75919d` candidate. Repeat on the current candidate. |
| Window close/reopen | Passed by user report on the earlier candidate. Repeat as part of current daily use. |
| Remapping Off/On persistence | Both UI states survived normal quit/relaunch on `b0bdf27`. Trackball was disconnected during that check; physical behavior remains to check. |
| Precision activation and restoration | Completed, verified session and qualified successful physical report on `0ef8bd6`. A new session is active on the volume-feedback candidate; restoration and user popup results remain pending. |
| Volume/mute popup | Isolated rendering and presentation checks passed. Physical popup behavior awaits user confirmation. |
| Quiet login, remapping On and Off | Both login/reboot scenarios pending. Launch-at-login registration alone is not proof of startup behavior. |
| Coexistence and interruption | Trackpad/other-mouse use, browser/natural-scroll variations, and ordinary sleep/wake or reconnect checks pending. Begin interruption checks with Precision inactive. |
| Repeated sessions and working week | Completed records have been archived through the app; sustained repeated-session acceptance and five normal working days remain pending. |
| Operating instructions | [Everyday-use guide](USER-GUIDE.md) prepared and checked against current UI labels. |

Use [ACCEPTANCE.md](ACCEPTANCE.md) for the ordered attended tests. Record the
actual build, starting state, result, and evidence for each scenario. Do not
mark a test passed from a plan, a displayed switch, or a previous build's result.
Do not deliberately interrupt a device change to manufacture recovery evidence.

## Update and rollback procedure

Before replacing the app, finish any active Precision session with verified
restoration and quit normally. If the state is uncertain or quitting is
blocked, stop for review. Record the executable identity and saved-record hashes,
preserve the current app, and verify the replacement's signature before launch.

Rollback replaces the app bundle only after the saved session state has been
reviewed for compatibility. Never restore an older runtime journal or overwrite
the protected baseline to make an older app start. Keep the current records and
previous bundles until acceptance is complete.

## Release decision

Release follows recorded completion of the applicable gates, resolution of
remaining defects, and acceptance of the personal-v1 limits: this MX Ergo/Mac,
global matching-button mappings, and explicit Precision activation each session.
Public distribution, other devices, and unattended Precision activation are
outside this release. No source, personal evidence, or backup is published by
this checklist.
