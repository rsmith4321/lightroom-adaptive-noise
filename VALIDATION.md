# Validation

## Automated checks

- 25 model/batch tests cover linear and logarithmic interpolation, exposure/shadow bonuses, caps, rerun behavior, excluded formats, unavailable inputs, metadata API routing, preview without writes, narrow patches, preservation of unrelated settings, snapshot failures, stale previews, a busy catalog, unconfirmed readback, and cancellation.
- All plugin/test files pass Lua 5.1 syntax checks. The 25 tests pass under Lua 5.1.5 and Lua 5.5.1.
- A strict SDK contract harness executes the real self-test script against in-memory doubles. It checks asynchronous/write-gate requirements, fixture-only mutations, camera metadata API routing, recovery snapshot identifiers, temporary collection cleanup, and restoration of the original source/selection/module. These remain mock checks, not Lightroom runtime evidence.
- Six additional workflow tests execute the real settings/preview/apply command with in-memory SDK doubles: no-selection protection, cancellation at either dialog, snapshot-before-patch ordering, readback, stale-input skips, per-camera edits, and preservation of unrelated adjustments. These also are mock checks.

## Lightroom checks

Pending: Lightroom Classic 15.6 on macOS. No Lightroom compatibility claim is made before the generated-fixture runtime test completes.

Catalog backups, customer paths, local runtime reports, and screenshots are private local evidence and are excluded from Git. Generated fixtures contain only a synthetic gradient and synthetic camera/ISO metadata.

## References

- [Adobe Lightroom Classic SDK](https://developer.adobe.com/lightroom-classic/).
- [Adobe Camera Raw XMP namespace](https://developer.adobe.com/xmp/docs/xmp-namespaces/crs/) documents the noise-reduction settings.
- Adobe-generated SDK HTML is available on a third-party mirror: [LrPhoto](https://lrc.mcor.dev/modules/LrPhoto.html), [LrCatalog](https://lrc.mcor.dev/modules/LrCatalog.html), and [LrTasks](https://lrc.mcor.dev/modules/LrTasks.html). The mirror's exact SDK revision has not been independently verified.

## Limits

Windows, older Lightroom versions, real-camera RAW/DNG processing, AI Denoise interactions, and subjective noise/detail quality have not been verified. The plugin deliberately sets manual NR only. No automatic HDR-DNG exclusion is implemented in this first version.
