# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- `Rename-Photos.ps1` — replaced custom `-DryRun` switch with standard `[CmdletBinding(SupportsShouldProcess)]`; use `-WhatIf` to preview renames and `-Confirm` to prompt before each rename
- `Build-Trips.ps1` — added `[CmdletBinding(SupportsShouldProcess)]`; use `-WhatIf` to preview the CSV write

### Removed
- `Rename-Photos.ps1` — `-DryRun` parameter

## [0.1.0] - 2026-03-26

### Added
- `Rename-Photos.ps1` — renames odometer photos using EXIF date/time, GPS location matching, and Windows OCR
- `Build-Trips.ps1` — pairs consecutive odometer readings into trips and validates distances via Haversine × road factor
- `locations.example.json` — template for known locations with GPS coordinates
- `settings.example.json` — template for local configuration (photo folder path, ExifTool path, thresholds)
- `PLAN.md` — full technical design document

[Unreleased]: https://github.com/ndomako10/mileage-tracker/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/ndomako10/mileage-tracker/releases/tag/v0.1.0
