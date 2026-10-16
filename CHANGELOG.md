# Changelog

## 0.2.0 — 2026-10-16

- Optional ISO-aware sharpening masking, contrast, clarity, and texture, including signed targets and coefficients for contrast/clarity/texture.
- Independent skip options for previous Adaptive Noise snapshots, existing manual NR settings, and AI Denoise. All three are off by default.
- Current Lightroom 15.6 AI Denoise ON/OFF runtime verification; conservative handling of uncertain enhancement metadata.
- Preserve existing per-camera NR settings during upgrade; all added controls start disabled.
- Fix cancellation while waiting for catalog access, uncertain SDK write accounting, filename-read failures, lost validation edits, malformed preferences, and native numeric input ranges.
- A direct latest-release ZIP link, expanded tests, and explicit validation/limitation documentation.

## 0.1.0 — 2026-10-15

- Initial independent ISO/Exposure/Shadows-based manual NR plugin, preview, recovery snapshots, and verified-write reporting.
