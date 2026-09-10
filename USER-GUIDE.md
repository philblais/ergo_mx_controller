# MX Ergo Controller — everyday use

This guide describes the personal development build with volume feedback
(`b0bdf27`). Everyday reliability testing is still in progress; see the
[release checklist](RELEASE-CHECKLIST.md) for the remaining checks.

## Open the app

Open **MX Ergo Controller** from Applications. Keep BetterTouchTool, Logitech
Options/Options+, and other software controlling the trackball fully quit.
Use the installed copy rather than opening another copy from Xcode.

In **Controls**, check that the MX Ergo is connected and **Input Monitoring**
and **Accessibility** are granted. Use the app's permission buttons if needed.
“Waiting for MX Ergo” means the app has not detected the trackball; confirm it
is switched on and connected to this Mac over Bluetooth.

Closing the controller window leaves the app running. Use its menu-bar item
and **Open MX Ergo Controller…** to return to Controls.

## Ordinary buttons

Turn **Button remapping** on to use these actions:

| Control | Action |
|---|---|
| Wheel click | Mission Control |
| Lower thumb button | Desktop right |
| Upper thumb button | Desktop left |
| Wheel tilt left | Back |
| Wheel tilt right | Forward |

Desktop switching needs adjacent desktops, and Back/Forward needs usable
navigation history. Matching buttons and wheel tilts on other mice may receive
the same mappings; this version does not restrict them to the MX Ergo.

The switch is remembered across normal app restarts. Turning it off stops the
ordinary button remapping. Precision audio has its own controls.

## Precision audio

Precision audio starts inactive each time the app launches. Ordinary remapping
can be active while Precision remains inactive.

1. If **Archive completed session…** is offered, review it and confirm
   **Archive completed record**. This keeps the finished record as a backup.
2. Expand **Prepare Precision audio**. Follow the seven displayed checks:
   **Check device support**, **Check device software**, **Check saved button
   settings**, **Run the safety self-test**, **Check the current button
   setting**, **Review readiness**, and **Prepare this session**.
3. Preparation is time-limited. When ready, review **Enable Precision audio…**
   and confirm **Enable Precision audio**. This changes the Precision button's
   device setting. Wait for the app to show **Active** before testing.
4. Tap Precision briefly to toggle mute. Hold it and scroll to change volume
   while the page stays still. Release it to resume ordinary scrolling.

The popup shows the reported volume level and percentage, or **Muted/Unmuted**.
It fades after adjustments stop. The level bar is a display, not a draggable
slider; use the wheel to adjust volume. It appears near the bottom of the
screen containing the pointer and does not take keyboard focus or mouse clicks.

Turning **Execute mute and volume** off pauses audio actions; it does not
restore the Precision button's original device setting.

## Finish a Precision session

Select **Restore Precision button…**, review, then confirm **Restore button
and stop audio**. This changes the device setting back and checks the result.
Wait for **Inactive · button restored**. The app may still own the connection;
quit normally and reopen before preparing another session.

**Quitting alone does not restore the Precision button.** For the current
acceptance tests, restore it successfully before quitting, logging out, or
restarting the Mac.

## If the app needs attention

| Message or symptom | Next action |
|---|---|
| Preparation expired, with no activation attempted | Use **Release expired preparation…** and confirm **Release session**, then follow fresh preparation. If unavailable, inspect Advanced before proceeding. |
| Competing software detected | Quit the named controller software, then repeat the readiness review when offered. |
| Current output cannot provide software volume or mute | Check the output device selected in macOS; some outputs cannot be controlled by this app. |
| Popup absent | Check that Precision is Active and Execute mute and volume is on. Record any audio error shown in Controls. |
| Recovery required, uncertain device change, or failed activation/restoration | Stop and preserve the displayed message. Do not retry the change or try to undo it with another command. Request a reviewed recovery procedure. |

Do not delete, replace, or manually edit the app's saved device records. The
older baseline-capture and standalone trial procedures are not routine setup
for this established installation.

## Launch at login

**Launch at login** controls whether macOS starts the app when you sign in.
Resolve any approval requested by macOS. Ordinary remapping follows its saved
On/Off setting; Precision still requires explicit preparation and activation.
The intended routine-login behavior is menu-bar-only when no attention is
needed. Login/reboot acceptance is still pending for this build.
