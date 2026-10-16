# Lightroom Adaptive Noise

## [Download latest version — ready-to-install ZIP](https://github.com/rsmith4321/lightroom-adaptive-noise/releases/latest/download/AdaptiveNoise.zip)

[Release notes](https://github.com/rsmith4321/lightroom-adaptive-noise/releases/latest) · [Installation](#install) · [Validation](VALIDATION.md)

An open-source **Lightroom Classic** plugin for ISO-aware noise reduction, sharpening masking, contrast, clarity, and texture. It calculates fresh targets from ISO and your existing Exposure/Shadows adjustments, then previews the changes before applying them.

Select photos, choose your camera's settings, preview the proposed values, then apply. Every changed photo gets a before snapshot. The result reports confirmed changes, photos that already match, skipped photos, errors, and any writes Lightroom did not confirm.

**Status: preview software for Lightroom Classic.** The original noise-reduction workflow was tested in Lightroom Classic 15.6 on macOS using generated JPEGs and a separate Sony a7 IV DNG. Version 0.2 adds optional controls and skip rules; the exact validation scope is recorded separately. See [VALIDATION.md](VALIDATION.md) for the checks and remaining limitations. Back up your catalog before trying an early version.

## Install

1. **[Download AdaptiveNoise.zip](https://github.com/rsmith4321/lightroom-adaptive-noise/releases/latest/download/AdaptiveNoise.zip)** and extract it. This link always points to the current latest release.
2. Keep the entire `AdaptiveNoise.lrplugin` folder together in a permanent location.
3. In Lightroom Classic, open **File → Plug-in Manager → Add**, and choose that folder.
4. Select photos in the Library module, then choose **File → Plug-in Extras → Adaptive Noise Reduction…**.

To update, replace the existing plugin folder with the extracted `AdaptiveNoise.lrplugin` folder, then click **Reload Plug-in** in Plug-in Manager. Keep the same plugin identity to retain saved camera settings. All four added controls and all three skip options start **off**; existing NR settings are retained.

This is for Lightroom **Classic**, not the cloud-based Lightroom application. It runs locally without a login, registration, subscription, network calls, or an external noise-reduction service. It uses Lightroom's manual develop controls; it does not run AI Denoise.

## What is new in 0.2

The familiar bulk-develop workflow now covers **six controls**: luminance NR, color NR, sharpening masking, contrast, clarity, and texture. Each added control has an independent enable checkbox, low/high ISO target values, Exposure/Shadows coefficients, and a cap. All share the camera's ISO range. Contrast, clarity, and texture support negative values, descending curves, and negative coefficients; their cap limits the magnitude in either direction. Added controls default off.

Three independent, remembered skip options also default **off**. They skip the whole photo, including any enabled contrast/clarity/texture controls:

| Option | Behavior |
| --- | --- |
| Previously processed by this plugin | Skip a photo with a `Before Adaptive Noise …` recovery snapshot, including snapshots made by v0.1. This is conservative: restoring a snapshot, undoing, or an interrupted attempt can leave the snapshot present, so the photo remains protected. Uncheck this option to process it again. This does not inspect arbitrary Lightroom edit history. |
| Existing manual noise reduction | Skip NR sliders that differ from usual defaults: luminance 0, color 25 for RAW/DNG or 0 otherwise, luminance/color detail 50, luminance contrast 0, color smoothness 50. Presets and custom import defaults count too; the SDK cannot prove who changed a slider. This option also protects prior plugin NR values if they differ from those defaults. |
| AI Denoise | Skip detected AI Denoise and uncertain enhancement records. It reads photo settings, not filenames, and does not run AI processing. See [validation and AI limitations](VALIDATION.md) for supported evidence and remaining gaps. |

If an enabled skip rule cannot read the information it needs, the photo is skipped with an explanation. Rules are checked again inside the catalog write gate, so a newly protected photo is not changed after preview.

This independent implementation builds on the workflow popularized by Jeffrey Friedl's Bulk Develop Settings, with snapshot-aware rerun protection, conservative AI Denoise exclusion, and verified-write reporting. Jeffrey's plugin already offered per-control default-only checks; the whole-photo skip choices here have different semantics. This project does not claim complete feature parity with every option in that plugin.

## How the calculation works

The initial settings are an editable starting point, not a camera-quality recommendation:

- ISO 100 → luminance NR 0; ISO 6400 → luminance NR 50.
- Add 5 luminance points per positive Exposure stop.
- Add 1 luminance point per +10 Shadows.
- Cap the final luminance value at 100.
- Optional color NR varies from 25 to 40 across the same ISO range, with no Exposure/Shadows bonus.

ISO interpolation is linear by default. Below the low ISO, the low endpoint is used; above the high ISO, the high endpoint is used. Exposure and Shadows bonuses are then added. Negative Exposure and Shadows adjustments add nothing. Results are rounded to whole slider points and limited by the final cap.

For example, using those defaults:

| ISO | Exposure | Shadows | ISO contribution | Final luminance NR |
| ---: | ---: | ---: | ---: | ---: |
| 100 | 0 | 0 | 0 | 0 |
| 3250 | 0 | 0 | 25 | 25 |
| 3250 | +2 | +30 | 25 | 38 |
| 6400 | +2 | +30 | 50 | 63 |

The high-ISO endpoint and the final cap are different settings. Set the cap above the endpoint if you want Exposure/Shadows bonuses to increase NR at high ISO. For a curve of 0–40 from ISO 100–6400 and a hard maximum of 40, set the high endpoint and cap to 40.

The plugin calculates a fresh target each time. It does **not** add these amounts to the existing NR value, so running it again with unchanged inputs makes no further adjustment. Re-run it after changing Exposure or Shadows if you want the NR targets updated.

Settings are remembered per camera make/model in Lightroom's plugin preferences. Non-RAW photos are skipped unless enabled for that camera. DNGs are treated as RAW; HDR/panorama DNGs are not automatically excluded. The optional AI skip uses available enhancement metadata; older baked enhanced DNGs may not expose a usable marker and are not guaranteed to be recognized. Missing ISO or required develop values produces an explicit skip, not a guessed adjustment. There is also an optional logarithmic ISO scale.

## Preview, preservation, and recovery

Preview lists before/after values for up to 100 photos and counts the whole selection. Applying replaces the **enabled adjustment values**, including previous manual edits unless a skip option protects the photo. The only possible develop keys are `LuminanceSmoothing`, `ColorNoiseReduction`, `SharpenEdgeMasking`, `Contrast2012`, `Clarity2012`, and `Texture`; disabled controls are never included. It does not send a complete develop-settings table or set the process version.

Before each adjustment, the plugin creates a snapshot named `Before Adaptive Noise <run ID>`. If a snapshot cannot be created, that photo is not adjusted. To restore a photo, open it in Develop and select that snapshot from the Snapshots panel. Lightroom's Undo/History is also available; separate operations may be grouped differently by Lightroom.

If ISO, camera, process version, Exposure, Shadows, or any of the six current control values change after preview, that photo is skipped. Cancellation stops before the next photo; earlier confirmed changes remain and retain their recovery snapshots. A readback mismatch is reported as **unverified**, so a submitted write is never silently counted as a confirmed adjustment.

## Development and testing

The source is ordinary Lua, compatible with Lightroom's Lua 5.1 runtime:

```sh
lua tests/run.lua
lua tests/sdk_contract.lua
lua tests/main_workflow.lua
lua tests/skip_policy.lua
```

`NoiseModel.lua` contains the independent calculation. `PhotoAccess.lua` reads the SDK metadata/develop values. `Batch.lua` builds the preview plan and performs snapshot-protected writes. `Main.lua` provides the settings and preview dialogs. `SkipPolicy.lua` contains the explicit skip rules. See [REVIEW.md](REVIEW.md) for the review findings and fixes.

The separate **Adaptive Noise: Run isolated self-test…** command imports the three tiny, generated JPEGs bundled under `fixtures/` and only adjusts those test images. It does not use the current photo selection. It checks actual slider readback, preservation, rerun behavior, and snapshot recovery. This command changes the catalog by adding test photos; use it only after a backup. Keep its fixture files in place while the catalog references them.

The SDK develop-settings interface is experimental and may change between Lightroom releases. Unit tests are not proof of a Lightroom runtime result, photo rendering quality, Windows compatibility, or compatibility with every camera/process version.

## Origin and license

Inspired by the useful ISO/exposure-aware workflow popularized by [Jeffrey Friedl's Bulk Develop Settings](https://regex.info/blog/lightroom-goodies/bulk-develop). This is an independent implementation of that general idea using Adobe's Lightroom SDK. No code, compiled modules, artwork, registration system, or other assets from that plugin are included. It is not an official continuation or affiliated with Jeffrey Friedl or Adobe.

MIT licensed. Contributions and reports of Lightroom-version compatibility are welcome.
