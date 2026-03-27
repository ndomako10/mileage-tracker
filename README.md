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
Rename-Photos.ps1
  │  For each photo:
  │    1. Read DateTimeOriginal from EXIF (ExifTool)
  │    2. Read GPS lat/lon from EXIF (ExifTool)
  │    3. Match GPS to nearest known location (locations.json, Haversine ≤ proximity threshold)
  │    4. Extract odometer digits via Windows OCR
  │    5. Rename:  yyMMdd-hhmm Location Odometer.jpg
  │    6. Append row to rename-log.csv
  │
  ▼
rename-log.csv                          ← audit trail; input for Build-Trips.ps1
  │
  ▼
Build-Trips.ps1
  │  1. Load and sort entries by timestamp
  │  2. Pair consecutive entries into trips
  │  3. Validate: odometer delta vs Haversine × road factor
  │  4. Assign status: auto | review | unpaired
  │
  ▼
trips.csv                               ← ready for Excel import or manual completion
```

---

## Requirements

- Windows 10 / 11
- PowerShell 5.1 or later
- [ExifTool](https://exiftool.org/) (place in `exiftool-13.53_64\` beside the scripts, or update `settings.json`)

---

## Setup

1. Copy `config/settings.example.json` → `config/settings.json` and set your photo folder path and other preferences.
2. Copy `config/locations.example.json` → `config/locations.json` and add your known locations.
3. Download [ExifTool for Windows](https://exiftool.org/) and place `exiftool.exe` at the path specified in `config/settings.json`.

---

## Configuration

All settings live in **`config/settings.json`** (copy from `config/settings.example.json`). Command-line parameters
override `settings.json` values; `settings.json` values override script defaults.

| Key | Default | Description |
|-----|---------|-------------|
| `Folder` | — | Path to the folder containing odometer photos |
| `LocationsJson` | `locations.json` | Path to your locations file |
| `ExifToolPath` | `exiftool-13.53_64\exiftool.exe` | Path to ExifTool executable |
| `ProximityThresholdMiles` | `1.0` | Max distance (miles) to match a GPS reading to a known location |
| `MaxTripMiles` | `250` | Max plausible miles for a single trip (used to flag suspect OCR readings) |
| `RoadFactor` | `1.25` | Straight-line → road distance multiplier (see [Calibrating the Road Factor](#calibrating-the-road-factor)) |
| `TolerancePct` | `0.20` | Allowed fractional deviation before a trip is flagged `review` |
| `DuplicateWindowSeconds` | `120` | Photos taken at the same location within this window are treated as duplicates |

---

## Usage

```powershell
# Step 1 — preview renames (no changes made)
.\scripts\Rename-Photos.ps1 -DryRun

# Step 1 — rename photos
.\scripts\Rename-Photos.ps1

# Step 2 — build trip pairs
.\scripts\Build-Trips.ps1
```

Open `trips.csv` and review any rows where `Status` is `review` or `unpaired`.
Once satisfied, import into the appropriate monthly sheet of the Excel workbook.

---

## File Naming

Photos are renamed to:

```
yyMMdd-hhmm Location Odometer.jpg

Examples:
  260301-0845 Home 47823.jpg
  260301-1432 North Site 47823.jpg
  260315-1605 Main Office 48201.jpg
```

- Files sort chronologically by default
- Location and odometer are visible at a glance
- Already-renamed files (matching `^\d{6}-\d{4} `) are skipped on re-run

---

## Known Locations

Defined in `locations.json`. Each entry requires a name, abbreviation, type, and GPS coordinates.
Coordinates can be sourced from Google Maps, Google Plus Codes, or photo GPS metadata.

```json
{
  "name": "Main Office",
  "abbreviation": "MO",
  "type": "work",
  "lat": 00.0000000,
  "lon": -00.0000000,
  "street": "123 Example St",
  "city": "Your City",
  "state": "MI"
}
```

See `config/locations.example.json` for a full template.

GPS proximity threshold is controlled by `ProximityThresholdMiles` in `settings.json` (default: **1.0 mile**).
If a photo's GPS does not match any location within the threshold, the location is set to `Unknown`
and the trip is flagged `review`.

---

## Output

### rename-log.csv

Written by `Rename-Photos.ps1`. One row per photo processed.

| Column | Example | Notes |
|--------|---------|-------|
| OriginalFile | `IMG_1234.jpg` | Filename before rename |
| NewFile | `260301-0845 Home 47823.jpg` | Filename after rename |
| DateTimeOriginal | `2026:03:01 08:45:22` | Raw EXIF value |
| Location | `Home` | Matched location name, or `Unknown` |
| Odometer | `47823` | OCR result; `00000` if unreadable |
| OdometerConfidence | `ok` | `ok`, `low:digits`, `none`, `error:msg` |
| GPSLat | `44.0000000` | Decimal degrees; empty if no GPS |
| GPSLon | `-84.0000000` | Decimal degrees; empty if no GPS |

### trips.csv

Written by `Build-Trips.ps1`. One row per paired trip (or unpaired reading).

| Column | Notes |
|--------|-------|
| Date | M/d/yyyy — matches Excel sheet format |
| DepartureTime | HH:mm |
| ArrivalTime | HH:mm; blank for unpaired entries |
| Origin | Location name |
| Destination | Location name; blank for unpaired |
| OdometerStart | Whole number |
| OdometerEnd | Whole number; blank for unpaired |
| Distance | OdometerEnd − OdometerStart; blank for unpaired |
| ExpectedMiles | Haversine × road factor; blank if unknown route |
| MatchConfidence | `auto` / `review` / `unpaired` |
| Status | Same as MatchConfidence |
| Notes | Human-readable explanation of any flags |
| OriginFile | Source photo filename |
| DestinationFile | Partner photo filename; blank for unpaired |

`Status` values:
- `auto` — matched within tolerance, no issues
- `review` — needs manual verification (bad OCR, unknown location, or distance mismatch)
- `unpaired` — only one reading found; fill in destination and end odometer manually
- `stop` — same-location dwell between two readings (reference row, not a trip)

---

## Trip Matching Logic

**Road factor:** straight-line (Haversine) distance × `RoadFactor` ≈ road distance.
Calibrate after reviewing a few confirmed trips (see [Calibrating the Road Factor](#calibrating-the-road-factor)).

**Tolerance:** a trip auto-matches if `|actual − expected| / expected ≤ TolerancePct`.

**A trip is flagged `review` when any of the following are true:**
- OCR confidence is not `ok` on either reading
- Either location is `Unknown`
- Odometer delta deviates from expected distance by more than the tolerance

**A reading is marked `unpaired` when:**
- The odometer decreased from the previous reading (photos are not a pair)
- No partner is found by end of file

---

## Handling Incomplete Data

| Situation | Behaviour |
|-----------|-----------|
| No GPS | Location set to `Unknown`; trip flagged `review` |
| OCR fails | Odometer set to `00000`; trip flagged `review` |
| Single photo (no pair) | Status `unpaired`; fill OdometerEnd and Destination manually |
| Gap across days | Consecutive entries are still paired; distance check catches bad matches |
| Multi-stop days | Each photo is matched to the next in time order; validate manually if stops occurred |

For `review` and `unpaired` rows in `trips.csv`:
- Cross-reference email or calendar history for the travel date
- Verify route on Google Maps using the Origin and Destination addresses
- Enter corrected values and change Status to `manual`

---

## Calibrating the Road Factor

After a few confirmed trips, compare `Distance` (odometer delta) to `ExpectedMiles`:

```
Actual road distance   = odometer delta (ground truth)
Straight-line distance = ExpectedMiles / RoadFactor

Best road factor = mean(odometer delta / straight-line distance) across confirmed trips
```

Update `RoadFactor` in `config/settings.json` accordingly, or override at runtime:

```powershell
.\scripts\Build-Trips.ps1 -RoadFactor 1.30 -TolerancePct 0.25
```

---

## Known Limitations

- **EXIF rotation:** Windows OCR does not correct for EXIF orientation. If photos are
  rotated, OCR accuracy may suffer. Workaround: ensure iPhone photos are taken upright.
- **City-level coordinates:** For some locations, only city-centre coordinates may be
  available. The default 1-mile proximity threshold handles this unless another known
  location is within 1 mile.
- **Trip order assumption:** `Build-Trips.ps1` pairs entries in strict timestamp order.
  Out-of-sequence photos (e.g., a photo taken at the end of a trip before a mid-trip photo)
  will cause a mismatch and be flagged for review.

---

## Future Improvements

- Excel direct-write via `ImportExcel` PowerShell module (replace CSV import step)
- Image pre-processing (crop + contrast) before OCR to improve accuracy on worn odometers
- Per-route calibrated road factors stored in `locations.json`
- Web or GUI front-end for the review/correction step
