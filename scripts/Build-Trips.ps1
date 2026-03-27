<#
.SYNOPSIS
    Pairs odometer photos into trips and validates distances against known routes.

.DESCRIPTION
    Reads rename-log.csv (produced by Rename-Photos.ps1), sorts entries by timestamp,
    then attempts to pair consecutive readings into trips using these rules:

      1. Consecutive entries whose odometer delta is within tolerance of the straight-line
         Haversine distance x road factor between their two locations are auto-matched.
      2. Entries that cannot be confidently paired are flagged for manual review.
      3. Entries with OCR confidence problems are always flagged.

    Output: trips.csv with columns matching the monthly Excel sheet format plus
    validation metadata (ExpectedMiles, MatchConfidence, Status, Notes).

.PARAMETER Folder
    Folder containing rename-log.csv and where trips.csv will be written.

.PARAMETER LocationsJson
    Path to locations.json.

.PARAMETER RoadFactor
    Multiplier applied to straight-line (Haversine) distance to estimate road distance.
    Default: 1.25. Calibrate this after reviewing a few confirmed trips.

.PARAMETER TolerancePct
    Percentage tolerance when comparing actual odometer delta to expected road distance.
    Default: 0.20 (20%). A 100-mile trip will auto-match if the odometer delta is 80-120 mi.

.EXAMPLE
    .\Build-Trips.ps1
    .\Build-Trips.ps1 -RoadFactor 1.30 -TolerancePct 0.25
#>
param(
    [string]$Folder          = "",
    [string]$LocationsJson   = "$PSScriptRoot\..\config\locations.json",
    [double]$RoadFactor             = 1.25,
    [double]$TolerancePct           = 0.20,
    [int]   $DuplicateWindowSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Load settings.json — values override param defaults; explicit args win
# ---------------------------------------------------------------------------
$paths = $null
$settingsPath = Join-Path $PSScriptRoot ".." "config" "settings.json"
if (Test-Path $settingsPath) {
    $cfg = Get-Content $settingsPath -Raw | ConvertFrom-Json
    $paths = if ($cfg.PSObject.Properties['Paths']) { $cfg.Paths } else { $null }
    if (-not $PSBoundParameters.ContainsKey('Folder')) {
        if ($paths -and $paths.PSObject.Properties['Source'] -and $paths.Source) {
            $Folder = $paths.Source
        } elseif ($cfg.Folder) {
            $Folder = $cfg.Folder
        }
    }
    if (-not $PSBoundParameters.ContainsKey('LocationsJson') -and $cfg.LocationsJson) {
        $LocationsJson = if ([System.IO.Path]::IsPathRooted($cfg.LocationsJson)) {
            $cfg.LocationsJson
        } else {
            Join-Path (Split-Path $settingsPath -Parent) $cfg.LocationsJson
        }
    }
    if (-not $PSBoundParameters.ContainsKey('RoadFactor') -and $null -ne $cfg.RoadFactor) {
        $RoadFactor = [double]$cfg.RoadFactor
    }
    if (-not $PSBoundParameters.ContainsKey('TolerancePct') -and $null -ne $cfg.TolerancePct) {
        $TolerancePct = [double]$cfg.TolerancePct
    }
    if (-not $PSBoundParameters.ContainsKey('DuplicateWindowSeconds') -and $null -ne $cfg.DuplicateWindowSeconds) {
        $DuplicateWindowSeconds = [int]$cfg.DuplicateWindowSeconds
    }
}

# ---------------------------------------------------------------------------
# Haversine distance (miles)
# ---------------------------------------------------------------------------
function Get-HaversineDistance {
    param([double]$Lat1, [double]$Lon1, [double]$Lat2, [double]$Lon2)
    $R    = 3958.8
    $dLat = ($Lat2 - $Lat1) * [Math]::PI / 180
    $dLon = ($Lon2 - $Lon1) * [Math]::PI / 180
    $a    = [Math]::Sin($dLat / 2) * [Math]::Sin($dLat / 2) +
            [Math]::Cos($Lat1 * [Math]::PI / 180) * [Math]::Cos($Lat2 * [Math]::PI / 180) *
            [Math]::Sin($dLon / 2) * [Math]::Sin($dLon / 2)
    $c    = 2 * [Math]::Atan2([Math]::Sqrt($a), [Math]::Sqrt(1 - $a))
    return $R * $c
}

# ---------------------------------------------------------------------------
# Build a lookup: location name -> location object
# ---------------------------------------------------------------------------
function Get-LocationMap {
    param([array]$Locations)
    $map = @{}
    foreach ($loc in $Locations) { $map[$loc.name] = $loc }
    return $map
}

# ---------------------------------------------------------------------------
# Expected road distance between two named locations (miles)
# Returns -1 if either location is unknown
# ---------------------------------------------------------------------------
function Get-ExpectedDistance {
    param([string]$FromName, [string]$ToName, [hashtable]$LocationMap, [double]$RoadFactor)
    if (-not $LocationMap.ContainsKey($FromName) -or -not $LocationMap.ContainsKey($ToName)) {
        return -1
    }
    $a = $LocationMap[$FromName]
    $b = $LocationMap[$ToName]
    $straight = Get-HaversineDistance $a.lat $a.lon $b.lat $b.lon
    return [Math]::Round($straight * $RoadFactor, 1)
}

# ---------------------------------------------------------------------------
# Format a DateTime as the Excel Date column value (M/d/yyyy)
# ---------------------------------------------------------------------------
function Format-TripDate {
    param([datetime]$dt)
    return $dt.ToString("M/d/yyyy")
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$reportsDir = if ($paths -and $paths.PSObject.Properties['Reports'] -and $paths.Reports) {
    $paths.Reports
} else { $Folder }
$logFile  = Join-Path $reportsDir "rename-log.csv"
$tripsOut = Join-Path $reportsDir "trips.csv"

if (-not (Test-Path $logFile)) {
    Write-Error "rename-log.csv not found. Run Rename-Photos.ps1 first: $logFile"
    exit 1
}
if (-not (Test-Path $LocationsJson)) {
    Write-Error "locations.json not found: $LocationsJson"
    exit 1
}

$locations   = Get-Content $LocationsJson -Raw | ConvertFrom-Json
$locationMap = Get-LocationMap $locations

# Load and parse log entries
$rawLog = Import-Csv $logFile
$entries = @()
foreach ($row in $rawLog) {

    # Skip rows where the photo was skipped (no rename / no date)
    if (-not $row.DateTimeOriginal) { continue }

    # Parse DateTimeOriginal: "2026:03:01 14:32:15"
    $dts = $row.DateTimeOriginal -replace ':', '-' -replace '-', '/', 2   # "2026/03/01 14:32:15"
    # More reliable: manual parse
    if ($row.DateTimeOriginal -match '^(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})') {
        $dt = [datetime]::new(
            [int]$matches[1], [int]$matches[2], [int]$matches[3],
            [int]$matches[4], [int]$matches[5], [int]$matches[6]
        )
    }
    else {
        Write-Warning "Could not parse date '$($row.DateTimeOriginal)' in log - skipping row"
        continue
    }

    $odom = 0
    [int]::TryParse($row.Odometer, [ref]$odom) | Out-Null

    $entries += [PSCustomObject]@{
        File               = $row.NewFile
        DateTime           = $dt
        Location           = $row.Location
        Odometer           = $odom
        OdometerConfidence = $row.OdometerConfidence
    }
}

# Sort by timestamp
$entries = $entries | Sort-Object DateTime

Write-Host "Loaded $($entries.Count) log entries. Building trips..."

# ---------------------------------------------------------------------------
# Deduplication pre-pass
# Removes entries that are true duplicates: same location, same odometer,
# and taken within DuplicateWindowSeconds of the previous entry.
# ---------------------------------------------------------------------------
$deduped   = @()
$prevEntry = $null
$dupCount  = 0

foreach ($entry in $entries) {
    if ($null -ne $prevEntry) {
        $gap          = ($entry.DateTime - $prevEntry.DateTime).TotalSeconds
        $sameLocation = $entry.Location -eq $prevEntry.Location
        $sameOdom     = $entry.Odometer -eq $prevEntry.Odometer

        if ($sameLocation -and $sameOdom -and $gap -lt $DuplicateWindowSeconds) {
            Write-Host "  Deduplicating $($entry.File) (duplicate of $($prevEntry.File), $([int]$gap)s gap)"
            $dupCount++
            continue
        }
    }
    $deduped  += $entry
    $prevEntry = $entry
}

if ($dupCount -gt 0) {
    Write-Host "  Removed $dupCount duplicate(s). Proceeding with $($deduped.Count) entries."
}

# ---------------------------------------------------------------------------
# Pairing pass
#
# Walks entries in chronological order. Each entry serves as the destination
# of the previous trip AND the origin of the next -- so after emitting any
# row (trip or stop), $pending advances to $entry rather than being cleared.
#
# Same-location consecutive entries (gap >= DuplicateWindowSeconds) are
# treated as arrival + departure: a reference "stop" row is emitted and
# the departure entry becomes the origin of the next trip.
# ---------------------------------------------------------------------------
$trips   = @()
$pending = $null

foreach ($entry in $deduped) {

    if ($null -eq $pending) {
        $pending = $entry
        continue
    }

    # --- Same location: dwell (arrival + departure) -------------------------
    if ($entry.Location -eq $pending.Location) {
        $gap = ($entry.DateTime - $pending.DateTime).TotalSeconds
        # Gap should always be >= DuplicateWindowSeconds here (duplicates removed above),
        # but guard anyway.
        if ($gap -ge $DuplicateWindowSeconds) {
            $dwellMin = [int]($gap / 60)
            $trips += [PSCustomObject]@{
                Date             = Format-TripDate $pending.DateTime
                DepartureTime    = $entry.DateTime.ToString("HH:mm")
                ArrivalTime      = $pending.DateTime.ToString("HH:mm")
                Origin           = $pending.Location
                Destination      = ""
                OdometerStart    = $pending.Odometer
                OdometerEnd      = ""
                Distance         = ""
                ExpectedMiles    = ""
                MatchConfidence  = ""
                Status           = "stop"
                Notes            = "Dwell $dwellMin min at $($pending.Location)"
                OriginFile       = $pending.File
                DestinationFile  = $entry.File
            }
        }
        # Departure entry becomes new pending regardless
        $pending = $entry
        continue
    }

    # --- Different locations: this is a trip --------------------------------
    $odomDelta    = $entry.Odometer - $pending.Odometer
    $expectedDist = Get-ExpectedDistance $pending.Location $entry.Location $locationMap $RoadFactor

    $ocrBad     = ($pending.OdometerConfidence -ne "ok") -or ($entry.OdometerConfidence -ne "ok")
    $unknownLoc = ($pending.Location -eq "Unknown") -or ($entry.Location -eq "Unknown")

    $status = "review"
    $notes  = @()

    if ($ocrBad)     { $notes += "OCR low confidence" }
    if ($unknownLoc) { $notes += "unknown location" }

    if ($odomDelta -lt 0) {
        $notes  += "odometer decreased"
        $status  = "unpaired"
        $trips += [PSCustomObject]@{
            Date             = Format-TripDate $pending.DateTime
            DepartureTime    = $pending.DateTime.ToString("HH:mm")
            ArrivalTime      = ""
            Origin           = $pending.Location
            Destination      = ""
            OdometerStart    = $pending.Odometer
            OdometerEnd      = ""
            Distance         = ""
            ExpectedMiles    = ""
            MatchConfidence  = ""
            Status           = "unpaired"
            Notes            = $notes -join "; "
            OriginFile       = $pending.File
            DestinationFile  = ""
        }
        $pending = $entry
        continue
    }

    if ($expectedDist -gt 0 -and -not $ocrBad -and -not $unknownLoc) {
        $deviation = [Math]::Abs($odomDelta - $expectedDist) / $expectedDist
        if ($deviation -le $TolerancePct) {
            $status = "auto"
        }
        else {
            $notes += "delta $odomDelta mi vs expected $expectedDist mi ($([Math]::Round($deviation*100,0))% off)"
        }
    }
    elseif ($expectedDist -lt 0) {
        $notes += "no route data for this location pair"
    }

    $trips += [PSCustomObject]@{
        Date             = Format-TripDate $pending.DateTime
        DepartureTime    = $pending.DateTime.ToString("HH:mm")
        ArrivalTime      = $entry.DateTime.ToString("HH:mm")
        Origin           = $pending.Location
        Destination      = $entry.Location
        OdometerStart    = $pending.Odometer
        OdometerEnd      = $entry.Odometer
        Distance         = $odomDelta
        ExpectedMiles    = if ($expectedDist -gt 0) { $expectedDist } else { "" }
        MatchConfidence  = $status
        Status           = $status
        Notes            = $notes -join "; "
        OriginFile       = $pending.File
        DestinationFile  = $entry.File
    }

    # Destination becomes the origin of the next trip
    $pending = $entry
}

# Emit any trailing unpaired entry
if ($null -ne $pending) {
    $trips += [PSCustomObject]@{
        Date             = Format-TripDate $pending.DateTime
        DepartureTime    = $pending.DateTime.ToString("HH:mm")
        ArrivalTime      = ""
        Origin           = $pending.Location
        Destination      = ""
        OdometerStart    = $pending.Odometer
        OdometerEnd      = ""
        Distance         = ""
        ExpectedMiles    = ""
        MatchConfidence  = ""
        Status           = "unpaired"
        Notes            = "no partner found"
        OriginFile       = $pending.File
        DestinationFile  = ""
    }
}

# Export CSV
$trips | Export-Csv -Path $tripsOut -NoTypeInformation -Encoding utf8

# Summary
$auto     = ($trips | Where-Object { $_.Status -eq "auto"     }).Count
$review   = ($trips | Where-Object { $_.Status -eq "review"   }).Count
$unpaired = ($trips | Where-Object { $_.Status -eq "unpaired" }).Count
$stops    = ($trips | Where-Object { $_.Status -eq "stop"     }).Count

Write-Host ""
Write-Host "Trips written to: $tripsOut"
Write-Host "  Auto-matched : $auto"
Write-Host "  Needs review : $review"
Write-Host "  Unpaired     : $unpaired"
Write-Host "  Stops (ref)  : $stops"
if ($review -gt 0 -or $unpaired -gt 0) {
    Write-Host ""
    Write-Host "Open trips.csv and manually complete rows where Status = 'review' or 'unpaired'."
}
