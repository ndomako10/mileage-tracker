# Mileage Tracker

Automated pipeline for tracking work-vehicle mileage from iPhone odometer photos to a
structured CSV ready for import into an Excel mileage workbook.

**Stack:** PowerShell 5.1+, ExifTool 13.53, Windows OCR (built-in, no API key required)

---

## How It Works

```
iPhone odometer photos (auto-uploaded via OneDrive)
  │
  ▼
Rename-Photos.ps1   — reads EXIF date/GPS, matches location, OCRs odometer, renames files
  │
  ▼
rename-log.json / rename-log.csv   — audit trail
  │
  ▼
Build-Trips.ps1     — pairs consecutive readings into trips, validates distances
  │
  ▼
trips.csv           — ready for Excel import
```

Each photo is renamed to: `yyMMdd-hhmm Location Odometer.jpg`

---

## Requirements

- Windows 10 / 11
- PowerShell 5.1 or later
- [ExifTool](https://exiftool.org/) (place in `exiftool-13.53_64\` beside the scripts, or update `settings.json`)

---

## Setup

1. Copy `settings.example.json` → `settings.json` and set your photo folder path.
2. Copy `locations.example.json` → `locations.json` and add your known locations.
3. Download [ExifTool for Windows](https://exiftool.org/) and place `exiftool.exe` at the
   path specified in `settings.json`.

---

## Usage

```powershell
# Step 1 — preview renames (no changes made)
.\Rename-Photos.ps1 -DryRun

# Step 1 — rename photos
.\Rename-Photos.ps1

# Step 2 — build trip pairs
.\Build-Trips.ps1
```

Open `trips.csv` and review any rows where `Status` is `review` or `unpaired`.
Once satisfied, import into the appropriate monthly sheet of the Excel workbook.

---

## Configuration

**`settings.json`** (copy from `settings.example.json`):

| Key | Default | Description |
|-----|---------|-------------|
| `Folder` | — | Path to the folder containing odometer photos |
| `LocationsJson` | `locations.json` | Path to your locations file |
| `ExifToolPath` | `exiftool-13.53_64\exiftool.exe` | Path to ExifTool executable |
| `ProximityThresholdMiles` | `1.0` | Max distance (miles) to match a GPS reading to a known location |
| `MaxTripMiles` | `250` | Max plausible miles for a single trip (used to flag suspect OCR readings) |

**`Build-Trips.ps1`** runtime overrides:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-RoadFactor` | `1.25` | Straight-line → road distance multiplier |
| `-TolerancePct` | `0.20` | Allowed deviation before a trip is flagged `review` |

---

## Output

**`trips.csv`** columns: `Date`, `DepartureTime`, `ArrivalTime`, `Origin`, `Destination`,
`OdometerStart`, `OdometerEnd`, `Distance`, `ExpectedMiles`, `MatchConfidence`, `Status`, `Notes`,
`OriginFile`, `DestinationFile`

`Status` values:
- `auto` — matched within tolerance, no issues
- `review` — needs manual verification (bad OCR, unknown location, or distance mismatch)
- `unpaired` — only one reading found; fill in destination and end odometer manually

---

## See Also

[PLAN.md](PLAN.md) — full technical design, schema definitions, calibration guide, and known limitations.
