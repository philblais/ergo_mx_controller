# Preserved hardware evidence — 2026-08-30

Byte-identical copies of the durable state under
`~/Library/Application Support/com.phib.MXErgoController/`, taken 2026-09-04.

These files are **not reproducible**. They record the only physical HID++ write
this project has ever performed, and their SHA-256 values are pinned in
`PrecisionForensicEvidenceAudit.swift` (profile `preservedAugust2026`).
Never edit them; add a new dated directory instead.

| File | SHA-256 |
|---|---|
| `device-state-journal.json` | `60ab614927d20871994ad0ebe7368158af9a26b2c1d60f7a2ab3c51635f77097` |
| `device-state-journal.pre-firmware-identity.json` | `4ef802eb1185c56f24b7635324113ab414f2acca499a4addc4e4117cd3cdf3aa` |
| `restore-trial-probe-result.json` | `7887950ec9602a21ff1d030310b0cb52b78a02e9a495f58bd7396922436c5460` |
| `restore-only-precision-trial.json` | `1efee23b585baac98ad2a6a888bbf741d88674fb71479640a332cf2c4cba66ac` |
| `restore-only-precision-reconciliation-result.json` | `f208abe8cf1e2b5ac31c67c0eaf6649f8f1369f1238f2cab40631896647c6593` |
| `restore-only-precision-trial-result.json` | `3b418d74ab36eef02571f29de4054c812cd8d403fe22429edf696d409ae22395` |

The last file is not pinned by the audit; it is kept because it records the
`acknowledgementMismatch` that put the trial into `outcomeUnknown`.

## What this evidence says

The 2026-08-30 trial dispatched exactly one Precision CID `00ED` restore SET
(`11 00 0A 3E 00 ED 02 00 …`) and never retried it. The device response failed
the deliberately strict full-echo acknowledgement rule, so the trial durably
entered `outcomeUnknown` revision 2. After BetterTouchTool was stopped and the
trackball power-cycled, one GET-only probe returned the exact clean baseline
`00 ED 00 00 …`. The offline reconciler then committed `baselineVerified`
revision 3 without any HID API in its executable.

Verify these copies against the live files with:

```sh
shasum -a 256 Evidence/2026-08-30/*.json
```
