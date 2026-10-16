# Changelog

## 1.1.1 — 2026-10-16

- Add the ShootCal logo, plugin name, and a Developed by ShootCal link above the settings.
- Give the scrolling area inner padding and group related settings into padded sections with consistent label alignment.
- Dim numeric fields when their adjustment is off, retaining the saved values.
- Add ShootCal attribution and a project link to GitHub's README.

## 1.1.0 — 2026-10-16

- Make Process the primary action, applying the chosen settings without a required preview.
- Add a separate Preview button for reviewing changes before processing. Both paths keep validation, skip rules, recovery snapshots, and verified-write reporting.
- Remove the isolated self-test command from Lightroom menus. Developer test sources remain available.
- Retain all six adjustments and three optional skip rules from 0.2.0.

## 0.2.0 — 2026-10-16

- Optional ISO-aware sharpening masking, contrast, clarity, and texture, including signed targets and coefficients for contrast/clarity/texture.
- Independent skip options for previous Adaptive Noise snapshots, existing manual NR settings, and AI Denoise. All three are off by default.
- Current Lightroom 15.6 AI Denoise ON/OFF runtime verification; conservative handling of uncertain enhancement metadata.
- Preserve existing per-camera NR settings during upgrade; all added controls start disabled.
- Fix cancellation while waiting for catalog access, uncertain SDK write accounting, filename-read failures, lost validation edits, malformed preferences, and native numeric input ranges.
- A direct latest-release ZIP link, expanded tests, and explicit validation/limitation documentation.

## 0.1.0 — 2026-10-15

- Initial independent ISO/Exposure/Shadows-based manual NR plugin, preview, recovery snapshots, and verified-write reporting.
