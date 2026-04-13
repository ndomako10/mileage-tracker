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
    .\Build-Trips.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Folder          = "",
    [string]$LocationsJson   = "$PSScriptRoot\..\config\locations.json",
    [double]$RoadFactor             = 1.25,
    [double]$TolerancePct           = 0.20,
    [int]   $DuplicateWindowSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\MileageTrackerHelpers.ps1"

# ---------------------------------------------------------------------------
# Load settings.json - values override param defaults; explicit args win
# ---------------------------------------------------------------------------
$paths = $null
$settingsPath = Join-Path $PSScriptRoot "..\config\settings.json"
if (-not (Test-Path $settingsPath)) {
    Write-Error "settings.json not found: $settingsPath"
    exit 1
}
try {
    $cfg = Get-Content $settingsPath -Raw | ConvertFrom-Json
} catch {
    Write-Error "settings.json is not valid JSON ($settingsPath): $($_.Exception.Message)"
    exit 1
}
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

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$reportsDir = if ($paths -and $paths.PSObject.Properties['Reports'] -and $paths.Reports) {
    $paths.Reports
} else { $Folder }
$logFile  = Join-Path $reportsDir "rename-log.csv"
$tripsOut = Join-Path $reportsDir "trips.csv"

$logsDir = if ($paths -and $paths.PSObject.Properties['Logs'] -and $paths.Logs) {
    $paths.Logs
} else { Join-Path $PSScriptRoot "..\logs" }
if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir | Out-Null }
$transcriptPath = Join-Path $logsDir "build-trips-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Start-Transcript -Path $transcriptPath -Append | Out-Null

Write-Information "[Build-Trips] Starting - reports: $reportsDir" -InformationAction Continue

try {

$configErrors = @()
if (-not $Folder)                    { $configErrors += "settings.json: 'Paths.Source' (or 'Folder') is required" }
if (-not (Test-Path $logFile))       { $configErrors += "rename-log.csv not found (run Rename-Photos.ps1 first): $logFile" }
if (-not (Test-Path $LocationsJson)) { $configErrors += "locations.json not found: $LocationsJson" }
if ($configErrors.Count -gt 0) {
    $configErrors | ForEach-Object { Write-Error $_ }
    exit 1
}

try {
    $locations = Get-Content $LocationsJson -Raw | ConvertFrom-Json
} catch {
    Write-Error "locations.json is not valid JSON ($LocationsJson): $($_.Exception.Message)"
    exit 1
}
if (@($locations).Count -eq 0) {
    Write-Error "locations.json must contain at least one entry: $LocationsJson"
    exit 1
}
$locationMap = Get-LocationMap $locations

# Load and parse log entries
$rawLog = Import-Csv $logFile
$entries = @()
foreach ($row in $rawLog) {

    # Skip rows where the photo was skipped (no rename / no date)
    if (-not $row.DateTimeOriginal) { continue }

    # Parse DateTimeOriginal: "2026:03:01 14:32:15"
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
    Write-Verbose "  Parsed entry: $($row.NewFile) | $dt | $($row.Location) | odom=$odom | conf=$($row.OdometerConfidence)"

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

Write-Information "Loaded $($entries.Count) log entries. Building trips..." -InformationAction Continue

$trips = Get-TripPairings -Entries $entries -LocationMap $locationMap `
    -RoadFactor $RoadFactor -TolerancePct $TolerancePct `
    -DuplicateWindowSeconds $DuplicateWindowSeconds

# Summary
$auto     = ($trips | Where-Object { $_.Status -eq "auto"     }).Count
$review   = ($trips | Where-Object { $_.Status -eq "review"   }).Count
$unpaired = ($trips | Where-Object { $_.Status -eq "unpaired" }).Count
$stops    = ($trips | Where-Object { $_.Status -eq "stop"     }).Count

Write-Information "  Auto-matched : $auto" -InformationAction Continue
Write-Information "  Needs review : $review" -InformationAction Continue
Write-Information "  Unpaired     : $unpaired" -InformationAction Continue
Write-Information "  Stops (ref)  : $stops" -InformationAction Continue

# Export CSV
if ($PSCmdlet.ShouldProcess($tripsOut, "Write trips CSV")) {
    $trips | Export-Csv -Path $tripsOut -NoTypeInformation -Encoding utf8
    Write-Information "" -InformationAction Continue
    Write-Information "Trips written to: $tripsOut" -InformationAction Continue
    if ($review -gt 0 -or $unpaired -gt 0) {
        Write-Information "" -InformationAction Continue
        Write-Information "Open trips.csv and manually complete rows where Status = 'review' or 'unpaired'." -InformationAction Continue
    }
}

Write-Information "[Build-Trips] Done." -InformationAction Continue

} finally {
    Stop-Transcript | Out-Null
}
