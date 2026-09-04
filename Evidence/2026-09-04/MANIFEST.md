# Preserved hardware evidence — 2026-09-04

The first successful live Precision temporary-diversion lifecycle.

| File | SHA-256 |
|---|---|
| `precision-runtime-v3.json` | `6ba7516b32f4c34345a59ec521bd658a395b35be3c39faa2af79973834fff41c` |
| `device-state-journal.json` | `60ab614927d20871994ad0ebe7368158af9a26b2c1d60f7a2ab3c51635f77097` |

`precision-runtime-v3.json` is the schema-v3 runtime journal, created for the
first time during this session and bootstrapped from the clean schema-v2
baseline. It records revision 6, CID `00ED` at `restoredVerified`, with two
attempts both `verified`.

The schema-v2 baseline is byte-identical to the 2026-08-30 copy, as required —
it is the recovery ground truth and is never rewritten.

See [../VALIDATION-RECORDS.md](../VALIDATION-RECORDS.md) for the session record.
