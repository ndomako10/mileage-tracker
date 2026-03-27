# Claude Code Instructions — Mileage Tracker

## Project overview

Two-script PowerShell pipeline: odometer photos → renamed files → trip CSV.

1. `scripts/Rename-Photos.ps1` — reads EXIF, matches GPS to known location, OCRs odometer, renames files, writes `logs/rename-log.json`
2. `scripts/Build-Trips.ps1` — reads `rename-log.csv`, pairs entries into trips, writes `trips.csv`

## Repo layout

```
scripts/    PowerShell scripts
config/     settings.example.json, locations.example.json (templates only — see below)
logs/       rename-log output (gitignored)
```

## PowerShell version

**Scripts require Windows PowerShell 5.1.** They will not work under PowerShell 7+ because Windows OCR uses WinRT APIs that are unavailable in PS7. Do not add PS7 compatibility without confirming the WinRT dependency can be resolved.

## Configuration files

`config/settings.json` and `config/locations.json` are the user's local config. They are **gitignored and must never be committed**. Only the `*.example.json` templates belong in the repo.

The same applies to all generated output: `logs/rename-log.json`, `trips.csv`.

## Path conventions

Both scripts locate their dependencies using `$PSScriptRoot` with relative `..` traversal:

- Settings: `$PSScriptRoot\..\config\settings.json`
- Locations: resolved relative to the config directory (`Split-Path $settingsPath -Parent`)
- Log output: `$PSScriptRoot\..\logs\`

When adding new file references in either script, follow this same pattern — never hardcode absolute paths.

## Testing

Use the `-DryRun` flag on `Rename-Photos.ps1` to preview renames without making changes:

```powershell
.\scripts\Rename-Photos.ps1 -DryRun
```

`Build-Trips.ps1` has no dry-run mode; running it only writes `trips.csv` which is gitignored.

## Implementation plan

See [PLAN.md](../PLAN.md) for the full implementation plan, issue groupings, and recommended branch order.

## Changelog

`CHANGELOG.md` is maintained by hand following [Keep a Changelog](https://keepachangelog.com/) conventions — do not regenerate it from commit history.

