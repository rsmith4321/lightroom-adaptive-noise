# Validation

## Automated checks

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

Windows, older Lightroom versions, cameras/formats beyond the tested Sony DNG and generated JPEGs, AI Denoise interactions, and subjective noise/detail quality have not been verified. A full 1,481-photo write/performance test was not run on customer photos. The plugin deliberately sets manual NR only. No automatic HDR-DNG exclusion is implemented in this first version.
