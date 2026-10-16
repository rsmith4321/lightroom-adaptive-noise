# Validation

## Version 1.1.2 tab layout checks — October 16, 2026

- Lightroom Classic 15.6 on macOS rendered all three native tabs with the shared camera and ISO controls above them. Noise Reduction showed its controls side by side; Detail & Tone showed all four controls in a two-column grid; Skip Options showed all three skip choices. No settings scrolling was needed.
- A temporary Texture value of **-4** remained visible after switching to Skip Options and back. Cancelling discarded the edit and did not process any photo.
- **41 model/batch checks**, **25 skip/integration checks**, **17 workflow checks**, and the SDK contract harness pass under Lua 5.1 and Lua 5.5. The new workflow check verifies that tab changes retain edits, camera switching keeps independent profiles, global skips remain shared, and the tab selection is not saved as a camera adjustment. Processing from Skip Options applies enabled NR and Texture settings from the other tabs.


## Version 1.1.1 presentation checks — October 16, 2026

- Added the existing ShootCal logo, project-name header, and an explicit Developed by ShootCal button linking to `https://shootcal.com/`. The same logo and attribution appear in the GitHub README.
- Lightroom Classic 15.6 on macOS rendered padded settings sections and the inset scroll area, including the bottom skip options. Turning Texture on activated its numeric fields; cancelling discarded that change.
- A temporary luminance target produced a read-only preview with the branded header and report padding. It was cancelled without processing, then the original camera target was restored; the subsequent preview reported **0 to change; 1 already match; 0 skipped**.
- **41 model/batch checks**, **25 skip/integration checks**, **15 workflow checks**, and the SDK contract harness pass under Lua 5.1 and Lua 5.5. The added workflow check verifies that the attribution opens the correct URL without catalog writes. These remain automated doubles, not Windows runtime evidence.


## Version 1.1 workflow checks — October 16, 2026

- Process is the primary settings action and bypasses the preview dialog. Preview remains a separate button and requires Process before writing. Both use the existing validation and protected batch implementation.
- **41 model/batch checks**, **25 skip/integration checks**, **14 Main workflow checks**, and the strict SDK contract harness pass under Lua 5.1 and Lua 5.5. New workflow coverage checks direct processing with snapshots/readback, validation before writes, and no-change processing. Existing tests cover preview cancellation and stale-input protection.
- Lightroom Classic 15.6 on macOS loaded version **1.1.0.1**, enabled with no diagnostic messages. The File menu contained the normal plugin command and no isolated self-test command. The settings dialog visibly displayed Preview, Cancel, and Process.
- Clicking Preview and, in a separate run, Process on the already-matching selection each reported **0 to change; 1 already match; 0 skipped**. These native checks made no photo adjustments. Direct Process writes are covered by automated workflow tests; the shared write implementation retains the earlier live evidence below.


## Version 0.2 review and runtime checks — October 16, 2026

An independent Astra review inspected the full implementation and tests. The reliability findings, fixes, and non-blocking follow-ups are recorded in [REVIEW.md](REVIEW.md).

- **41 model/batch checks**, **25 skip/integration checks**, **11 Main workflow checks**, and the strict SDK self-test harness pass under Lua 5.1 and Lua 5.5. The harnesses are automated doubles, not application proof.
- A private Sony a7 IV DNG already imported for development was used in Lightroom Classic **15.6 on macOS**. Its original state was snapshotted before this review test, and restored afterward.
- Actual Lightroom write/readback confirmed sharpening masking **35**, contrast **−12**, clarity **−8**, and texture **−6**, alongside the existing NR calculation. Every other returned develop setting matched its pre-apply value. A second calculation produced no changes.
- The snapshot-based processed-photo option skipped that test photo. A separate actual snapshot-restore check changed all four new controls on that private copy, restored the snapshot, and confirmed all six controls exactly matched their pre-test values.
- On that same private DNG, the public Lightroom controller enabled AI Denoise at **20** for testing. Lightroom reported Denoise active, and `getDevelopSettings()` returned an Enhance record in `FilterList.Filters` with `FilterID=1` and the title `$$$/CRaw/Filter/Title/Denoise=Denoise`. The plugin classified it as applied and skipped the photo in preview.
- Disabling Denoise cleared `FilterList`. The remembered amount remained 20, but the plugin correctly classified the photo as no active Denoise. The plugin's normal operation never enables AI Denoise; that action was limited to the private test helper.
- The original user's photo's entire returned settings table was unchanged, and the original sources, selection, and module were restored. Temporary test collections were removed. Private dumps and the DNG are excluded from Git and release assets.
- The expanded native dialog opened successfully. All added controls and all three skip checkboxes were visibly off. Scrolling reached every option. Direct numeric entry of Texture **−4** appeared correctly in preview; cancelling applied no adjustment. The temporary test profile was restored, and a subsequent preview reported zero changes. Direct ISO entry **6400** worked after explicit native input bounds were added.

### AI skip scope

Modern, non-destructive Denoise detection has direct runtime evidence on Lightroom Classic 15.6 with the tested Sony DNG. Explicit nested Denoise flags and unknown/malformed enhancement cases are additionally covered by automated tests. Uncertain enhancement records are skipped when the AI option is enabled, which can conservatively skip other Enhance operations too. Raw Details/Super Resolution without Denoise have not been tested live. Legacy baked enhanced DNGs are recognized only if Lightroom exposes `EnhanceDenoiseAlreadyApplied`; that older workflow is not runtime-verified and may expose no marker. Do not rely on this option as a universal detector for old enhanced DNGs.

The manual-NR option detects slider differences from documented baseline values, including presets/import defaults. It cannot establish that a person made a manual edit. The processed-photo option uses recovery-snapshot presence, including old/undone/interrupted runs; it does not claim a confirmed processing-history database.

## Original v0.1 automated checks

- 25 model/batch tests cover linear and logarithmic interpolation, exposure/shadow bonuses, caps, rerun behavior, excluded formats, unavailable inputs, metadata API routing, preview without writes, narrow patches, preservation of unrelated settings, snapshot failures, stale previews, a busy catalog, unconfirmed readback, and cancellation.
- All plugin/test files pass Lua 5.1 syntax checks. The 25 tests pass under Lua 5.1.5 and Lua 5.5.1.
- A strict SDK contract harness executes the real self-test script against in-memory doubles. It checks asynchronous/write-gate requirements, fixture-only mutations, camera metadata API routing, recovery snapshot identifiers, temporary collection cleanup, and restoration of the original source/selection/module. These remain mock checks, not Lightroom runtime evidence.
- Six additional workflow tests execute the real settings/preview/apply command with in-memory SDK doubles: no-selection protection, cancellation at either dialog, snapshot-before-patch ordering, readback, stale-input skips, per-camera edits, and preservation of unrelated adjustments. These also are mock checks.

## Lightroom checks

Completed October 15, 2026 in Lightroom Classic **15.6 on macOS**. The original catalog was closed normally before backup. The catalog and its supporting data were copied and verified with matching SHA-256 hashes; the copied catalog also passed SQLite `quick_check`. Lightroom was reopened only after verification.

### Generated JPEG fixtures

- The real plugin imported its three generated JPEGs (ISO 100, 3250, and 6400).
- With Exposure +2 and Shadows +30, Lightroom readback confirmed luminance targets **13, 38, 63** and color targets **25, 33, 40**.
- Exposure, Shadows, tone, sharpening, white balance, crop, and process version checks passed.
- Running the calculation again produced zero changes.
- A recovery snapshot was restored successfully, recovering the pre-adjustment NR values.

### Private Sony DNG copy

- A separate file copy of a Sony **ILCE-7M4 / a7 IV DNG**, ISO 100, was imported solely for testing. The source file was not written by the test.
- With Exposure +2 and Shadows +30, actual readback confirmed luminance **13** and color **25**.
- Every other returned develop-setting key matched the pre-apply value.
- The repeat-run and snapshot-recovery checks passed.
- The original selected source photo's complete returned develop-settings table matched its pre-test state.
- The private RAW copy and private test helpers are excluded from the repository and distribution.

### Native dialog workflow

- The actual settings, preview, and apply dialogs opened successfully.
- Typing an Exposure coefficient of **7**, then clicking Preview directly, produced luminance target **17**. Cancelling that preview left the copied DNG at its prior NR value of 0.
- Restoring the coefficient to **5** and applying through the actual dialog produced **13**, confirmed by Lightroom.
- Reopening and previewing again explicitly reported **0 to change; 1 already match; 0 skipped**.
- The original source, selection, and Library module were restored; temporary test collections were removed. Four imported test-photo catalog entries and their local files were retained as test evidence. No adjustments were applied to the original customer photos.
- Commands are registered under both File and Library → Plug-in Extras.

Catalog backups, customer paths, local runtime reports, and screenshots are private local evidence and are excluded from Git. Generated fixtures contain only a synthetic gradient and synthetic camera/ISO metadata.

## References

- [Adobe Lightroom Classic SDK](https://developer.adobe.com/lightroom-classic/).
- [Adobe Camera Raw XMP namespace](https://developer.adobe.com/xmp/docs/xmp-namespaces/crs/) documents the noise-reduction settings.
- Adobe-generated SDK HTML is available on a third-party mirror: [LrPhoto](https://lrc.mcor.dev/modules/LrPhoto.html), [LrCatalog](https://lrc.mcor.dev/modules/LrCatalog.html), and [LrTasks](https://lrc.mcor.dev/modules/LrTasks.html). The mirror's exact SDK revision has not been independently verified.

## Limits

Windows, older Lightroom versions, cameras/formats beyond the tested Sony DNG and generated JPEGs, legacy baked AI-Denoise DNG detection, and subjective noise/detail quality have not been verified. A full 1,481-photo write/performance test was not run on customer photos. The plugin changes only the enabled manual NR, sharpening mask, contrast, clarity, and texture controls. It does not run AI processing in normal operation. No automatic HDR-DNG exclusion is implemented in this first version.
