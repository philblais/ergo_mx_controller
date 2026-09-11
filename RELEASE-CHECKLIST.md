# Personal v1 release readiness

## September 11 restart-validation candidate

The new read-only Resume action is built and verified: 534 tests, no skips,
four signed builds/audits, and Release with warnings treated as errors. Release
executable SHA-256:
`dcf8667100fcd169fe82da7e380a3fddf93788569b8f0584766fe5ce8fe852f5`.
Retained build and logs: `build/precision-resume-dcf86671/`.
Hardware acceptance of notification delivery after reconnect is pending.
Fully automatic Precision startup remains unimplemented; see
[restart development](RESTART-DEVELOPMENT.md).

## Previous volume-feedback candidate and acceptance

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

Local packaging is complete. The archive is
`/Users/phib/Documents/ChatGPT/Logitech Trackball/Releases/MX Ergo Controller Candidate 44a84c45.zip`
(4,890,511 bytes), SHA-256
`6a96fbd02f9ae3d068534e76df58ce73722bd27e0a6a0c6eb770dc64a07e14ff`.
It contains the unchanged signed app, an everyday-use guide, installation and
rollback notes, a standalone test-status snapshot, build identity, and per-file
checksums. All ten manifested files match after extraction and the extracted
app's signature verifies. The package excludes live device records and remains
a personal release candidate. The existing installation was not replaced.

| Area | Evidence and remaining work |
|---|---|
| Input scope | Global matching-button mappings accepted by the user. Behavior with another mouse still needs observation. |
| Ordinary controls | Five mapped actions passed by user report after the September 10 reboot on the current candidate. Earlier normal clicking/scrolling evidence belongs to `d75919d`; broader current-build coexistence remains pending. |
| Window close/reopen | Passed by user report on the earlier candidate. Repeat as part of current daily use. |
| Remapping Off/On persistence | Both UI states survived normal quit/relaunch on `b0bdf27`. Trackball was disconnected during that check; physical behavior remains to check. |
| Precision activation and restoration | Two completed revision-6 sessions on the volume-feedback candidate retain verified apply/restore evidence; latest UI confirms button restored. Earlier `0ef8bd6` evidence remains separately recorded. |
| Volume/mute popup | Passed by user report September 10 (“It's all working”), with final restoration independently confirmed by UI and durable record. Isolated rendering and presentation checks also passed. |
| Quiet login, remapping On and Off | Reboot availability and five mapped actions passed by user report with On. A subsequent logout/login retained Off by user report; the user then restored On. Both saved-setting login outcomes pass. Initial menu-only window behavior remains unconfirmed. |
| Coexistence and interruption | Mac sleep/wake and a separate trackball off/on test with Precision inactive both passed by user report, including reconnection and five ordinary controls without restarting the app. Trackpad/other-mouse and browser/natural-scroll variations remain pending. Active-Precision interruption behavior is not established by these results. |
| Repeated sessions and working week | Two completed sessions plus intervening archived record observed on the current candidate. Longer repeated-use acceptance and five normal working days remain pending. |
| Operating instructions | [Everyday-use guide](USER-GUIDE.md) prepared and checked against current UI labels. |
| Resource use | One-minute idle sample: approximately 0.05% of one CPU core, 117.42 MiB resident memory unchanged, diagnostic file unchanged at 95,988 bytes. Existing log file/backlog limits reviewed. Active-load and multi-day resource behavior remain unverified. |

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
