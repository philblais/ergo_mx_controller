# Personal v1 acceptance checklist

This is the current path for the Controls/Advanced interface. It replaces the
older sequential instructions in RUNBOOK.md for routine validation. Historical
hardware records remain evidence for their named builds, not for this candidate.
An unchecked or unobserved scenario is **not run**, not passed.

## Session preparation

1. Record the source commit, Release executable SHA-256, signature result,
   installed path, macOS version, and test result in a session note. Preserve
   the previous installed app. Launch only the copy in `/Applications` for this
   session; an Xcode build with the same name is a different copy.
2. Agree on input scope before ordinary-control acceptance: this version remaps
   matching button and discrete wheel-tilt events globally. It does not prove
   that those events came from the MX Ergo. Other mice may receive the same
   mappings. Record acceptance of this scope or defer the affected tests while
   device-specific filtering is investigated.
3. The user quits the running controller normally, then confirms BetterTouchTool,
   Logi Options/Options+, and other MX Ergo tools are completely quit. If the
   controller refuses to quit or reports an uncertain device change, stop and
   record that status; do not force-quit to advance the checklist.
4. The user power-cycles the MX Ergo before the session and confirms it is ready.
   The project's hardware-session skill requires the user at the keyboard for
   physical operations; automated tests do not substitute for this step.
5. Capture the current hashes of the application's JSON records before opening
   the candidate. The protected `device-state-journal.json` must remain:
   `60ab614927d20871994ad0ebe7368158af9a26b2c1d60f7a2ab3c51635f77097`.
   A saved completed/restored record describes a past operation; it is not a
   new observation of the device.

Do not run baseline capture, firmware metadata migration, standalone restore
trials, or the historical mapped-control diversion workflow as setup for this
session. The existing baseline is already established and must stay unchanged.

## First stage: launch and ordinary controls

Keep Precision inactive throughout this stage. Do not select Enable Precision
audio or any restore/recovery action. Record what actually happens in each row.

| Scenario | Steps and required result | Result / evidence |
|---|---|---|
| Exact installed build | Open `/Applications/MX Ergo Controller.app`. Confirm one controller process and that its executable path is the installed copy. | Not run |
| Manual launch | Controls opens. Permission rows and connection state are readable. A missing permission offers the appropriate settings action. | Not run |
| Close, menu Open, app reopen | Close the window without quitting. The app stays in the menu bar. Menu Open raises it. Close it and open the installed app again; the window reappears. | Not run |
| Remembered Off | Set Button remapping Off, quit normally, and open the installed app. It remains Off and matching buttons keep their normal behavior. | Not run |
| Remembered On | With Accessibility granted and competitors quit, set Button remapping On. Quit normally and reopen; it resumes without needing to open a settings panel. | Not run |
| Five ordinary controls | Wheel click opens Mission Control; thumb buttons move between the adjacent Spaces shown in the mappings; left/right tilt navigate back/forward. Verify with usable browser history and adjacent Spaces. No duplicate actions or lost releases. | Not run |
| Coexistence | Primary/secondary clicks, ball movement, ordinary scrolling, and trackpad gestures remain usable. Matching buttons on other mice behave according to the agreed scope. | Not run |
| Login On | Enable Launch at login and resolve any macOS approval notice. Save work, close the window, then log out/in or restart when the user is ready. With remapping On, required permissions, prior window presentation, and no saved-state issues, the app appears only in the menu bar and ordinary mappings work. | Not run |
| Login Off | Repeat login with Button remapping Off. It remains Off; the preference is not overridden. A normal, fully configured login stays menu-only. | Not run |

After the two login checks, restore the user's chosen remapping preference.
First-ever presentation, missing permissions, failed remembered remapping,
login-registration issues, and saved-state review must surface the window.
Only exercise permission changes deliberately while Precision is inactive;
restore the user's settings afterward. Do not corrupt or edit a live journal
to manufacture a saved-state test. Those failure branches also have fake-based
automated coverage.

## Second stage: explicitly confirmed Precision session

Start only after the first-stage results are reviewed and the user is ready to
perform the two device-changing actions below. Keep all competing software quit.

1. If Controls offers **Archive completed session…**, review the exact
   completed record and confirm **Archive completed record**. This archives
   only an eligible spent runtime record. If the app instead shows saved-state
   review or recovery, stop and inspect Advanced; do not follow this activation
   sequence or move files by hand.
2. Expand **Prepare Precision audio**. Confirm each displayed step once:
   **Check device support**, **Check device software**, **Check saved button
   settings**, **Run the safety self-test**, **Check the current button
   setting**, **Review readiness**, and **Prepare this session**.
   These steps read/prepare; none enables Precision audio. Record each result.
   Readiness must remain review-only, not execution authorization.
3. Preparation is time-limited. If it expires or fails, use the supported
   release/review route and record the outcome. Do not press Enable repeatedly.
4. Review **Enable Precision audio…**, then explicitly confirm **Enable
   Precision audio**. This can send the apply SET below after fresh identity
   verification. Confirm the same session becomes active and audio enabled.
5. Tap Precision quickly: mute changes once. Hold Precision and scroll over a
   long page: volume changes while the page stays still. Release Precision:
   ordinary page scrolling resumes. Check the five ordinary controls too.
6. Select **Restore Precision button…**, review, and confirm **Restore button
   and stop audio**. This can send the restore SET below. Audio pauses first;
   require a verified baseline result. The runtime may remain admitted after
   restoration; that is expected and does not mean Precision is still diverted.
7. Quit normally. Record the final status and current journal hashes. Require
   the protected baseline to remain unchanged. Retain the runtime record and
   exact request/response evidence before beginning another session.

For this baseline, feature index `0A`, device index `00`, and software ID `0E`,
the reviewed 20-byte requests are:

```text
Enable (apply SET):
11 00 0A 3E 00 ED 03 00 00 00 00 00 00 00 00 00 00 00 00 00
Restore (restore SET):
11 00 0A 3E 00 ED 02 00 00 00 00 00 00 00 00 00 00 00 00 00
Separate state verification (GET):
11 00 0A 2E 00 ED 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

These are expectations to compare with the app's current readiness review, not
commands to send manually. A different projection requires review before any
device change. Capture actual request and response bytes for every HID step.
An acknowledgement alone never proves state; require the independent GET.

If a device change is ambiguous, stop. Do not retry, send an inverse command,
manually archive the record, or mark it clean based on how the button feels.
Preserve the evidence for a separately reviewed read-only diagnostic. Quit
alone never restores Precision.

## Later reliability acceptance

After a successful baseline session, schedule repeat-session archival,
sleep/wake, power cycles, ordinary quit/login, browser/natural-scrolling changes,
competitor detection, and a normal working-week trial. Record exact starting
state, actions, observed outcome, and build for each. Start interruption checks
with Precision inactive; do not deliberately interrupt a SET or manufacture
ambiguous hardware state to complete a checklist. Live recovery is a separate
attended procedure if a real interruption requires it.

Append actual hardware observations to Evidence/VALIDATION-RECORDS.md and retain
new records in a fresh evidence directory. Keep plans and expected outcomes
separate from observed results. Release remains pending until the applicable
scenarios are recorded and failures are resolved.
