# Version 0.2 review

Reviewed October 16, 2026. A full independent Astra review covered the calculation, Lightroom access, batch write path, dialogs, self-test, tests, and documentation. A second review covered the expanded controls and skip policies. This was a functional and reliability review, not a separate security audit.

## Fixed findings

| Finding | Resolution |
| --- | --- |
| Cancel could arrive while waiting for catalog write access, yet the pending photo would change. | Recheck cancellation inside the write gate, after reading current inputs, and before submission. |
| An SDK write could mutate settings and then throw, but be counted as failed rather than uncertain. | Mark the attempt before entering the SDK call; such exceptions count as unverified and retain the recovery snapshot. |
| A filename metadata exception aborted the entire selection scan. | Protect that read and use an explicit fallback label. |
| Invalid settings closed the dialog and discarded edits. | Reopen with all edits retained and the affected camera selected. |
| Malformed saved preferences could prevent opening settings. | Fall back to an editable defaults table. |
| Native numeric fields implicitly limited entries to 0–100. | Explicit ISO and signed-adjustment bounds, with native dialog verification and regression assertions. |
| Disabled controls were described as already matching. | Report an explicit all-controls-disabled skip reason. |
| Long result details were truncated silently. | Show the omitted-detail count. |

## Added controls and protections

Four optional controls use fresh ISO-based targets and narrow patches. Signed controls permit decreasing ISO curves and negative coefficients. All new controls default off, and v0.1 camera profiles migrate without changing saved NR settings.

Three independent opt-in skip rules protect previously processed snapshots, existing manual NR values, and detected/uncertain AI Denoise. Eligibility is checked in preview and again inside the write gate. Tests include changing eligibility during catalog access waits and partial/unconfirmed writes. The exact snapshot, manual-baseline, and AI limitations are documented in README and VALIDATION.

Actual Lightroom tests verified all four added targets, preservation, repeat-run behavior, recovery, modern AI Denoise ON/OFF, and the expanded dialog. See [VALIDATION.md](VALIDATION.md) for evidence scope. No release-blocking defect remained in the independent review.

## Remaining non-blocking improvements

- Preview labels use filenames; virtual copies or duplicate filenames can be hard to distinguish.
- The optional generated-fixture self-test could report cleanup/receipt-write failures more explicitly. Its empty-original-selection restoration needs additional application testing.
- A complete exportable per-photo result report would help with large partial failures.
- Full-gallery write performance, Windows, additional camera formats, and older enhanced-DNG detection remain unverified.
