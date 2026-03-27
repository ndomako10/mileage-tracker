<#
.SYNOPSIS
    Renames odometer photos using EXIF date/time, GPS-matched location, and OCR odometer reading.

.DESCRIPTION
    For each IMG_*.jpg in the target folder:
      1. Reads DateTimeOriginal from EXIF via ExifTool
      2. Reads GPS coordinates from EXIF via ExifTool
      3. Matches GPS to the nearest known location from locations.json
      4. Extracts the odometer reading via Windows OCR
      5. Validates the reading against the previous known-good odometer value
      6. Renames the file: yyMMdd-hhmm Location Odometer.jpg
      7. Appends an entry to rename-log.json (in the repo root)

    Default values are loaded from settings.json beside this script.
    Any parameter passed on the command line overrides the corresponding setting.

.PARAMETER Folder
    Path to the folder containing odometer photos.

.PARAMETER LocationsJson
    Path to locations.json. Relative paths are resolved from the script directory.

.PARAMETER ExifToolPath
    Path to the exiftool executable. Relative paths are resolved from the script directory.

.PARAMETER ProximityThresholdMiles
    Maximum distance in miles from a known location to count as a match.

.PARAMETER MaxTripMiles
    Maximum plausible miles for a single trip. OCR readings that exceed the previous known-good
    odometer by more than (gaps + 1) * MaxTripMiles are flagged as suspect.

.EXAMPLE
    .\Rename-Photos.ps1 -WhatIf
    .\Rename-Photos.ps1
    .\Rename-Photos.ps1 -Folder "D:\Photos\Odometer" -WhatIf
    .\Rename-Photos.ps1 -Confirm
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Folder                  = "",
    [string]$LocationsJson           = "$PSScriptRoot\..\config\locations.json",
    [string]$ExifToolPath            = "$PSScriptRoot\..\exiftool-13.53_64\exiftool.exe",
    [double]$ProximityThresholdMiles = 1.0,
    [int]$MaxTripMiles               = 250
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Haversine distance (miles) between two lat/lon points
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
# Match GPS coordinates to the nearest known location
# Returns the location object, or $null if nothing is within threshold
# ---------------------------------------------------------------------------
function Get-NearestLocation {
    param([double]$Lat, [double]$Lon, [array]$Locations, [double]$ThresholdMiles)
    $nearest = $null
    $minDist = [double]::MaxValue
    foreach ($loc in $Locations) {
        $dist = Get-HaversineDistance $Lat $Lon $loc.lat $loc.lon
        if ($dist -lt $minDist) {
            $minDist = $dist
            $nearest = $loc
        }
    }
    if ($minDist -le $ThresholdMiles) { return $nearest }
    return $null
}

# ---------------------------------------------------------------------------
# Windows OCR -- extract the odometer reading from a photo
# Returns a hashtable: @{ Reading = "47823"; Confidence = "ok"|"low:..."|"none"|"error:..." }
# ---------------------------------------------------------------------------
function Get-OdometerReading {
    param([string]$ImagePath)

    # WinRT type loading only works in Windows PowerShell 5.1, not PowerShell 7+
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        return @{ Reading = "00000"; Confidence = "error:OCR requires Windows PowerShell 5.1. Run: powershell.exe -File '$PSCommandPath'" }
    }

    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime

        $null = [Windows.Media.Ocr.OcrEngine,             Windows.Foundation, ContentType=WindowsRuntime]
        $null = [Windows.Media.Ocr.OcrResult,             Windows.Foundation, ContentType=WindowsRuntime]
        $null = [Windows.Graphics.Imaging.BitmapDecoder,  Windows.Foundation, ContentType=WindowsRuntime]
        $null = [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Foundation, ContentType=WindowsRuntime]

        # Reflection helper: await IAsyncOperation<T> -> T
        $asTaskMethod = [System.WindowsRuntimeSystemExtensions].GetMethods() |
            Where-Object {
                $_.Name -eq 'AsTask' -and
                $_.IsGenericMethod -and
                $_.GetGenericArguments().Count -eq 1 -and
                $_.GetParameters().Count -eq 1
            } | Select-Object -First 1

        function Invoke-WinRTAsync {
            param($AsyncOp, [type]$ResultType)
            $task = $asTaskMethod.MakeGenericMethod($ResultType).Invoke($null, @($AsyncOp))
            $task.Wait()
            return $task.Result
        }

        # Open the file as a .NET stream and wrap it as IRandomAccessStream.
        # This avoids StorageFile.OpenReadAsync() whose IAsyncOperation<IRandomAccessStream>
        # return type cannot be cast from System.__ComObject in PS5.1 COM interop.
        $absPath    = (Resolve-Path $ImagePath).Path
        $netStream  = [System.IO.File]::OpenRead($absPath)
        $winStream  = [System.IO.WindowsRuntimeStreamExtensions]::AsRandomAccessStream($netStream)
        $decoder    = Invoke-WinRTAsync ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($winStream)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $bitmap     = Invoke-WinRTAsync ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
        $winStream.Dispose()
        $netStream.Dispose()

        $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
        if ($null -eq $engine) {
            return @{ Reading = "00000"; Confidence = "error:OCR engine unavailable" }
        }

        $ocrResult = Invoke-WinRTAsync ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
        $allText   = $ocrResult.Text

        # Find all digit sequences; the longest is most likely the odometer
        $digitMatches = [regex]::Matches($allText, '\d+')
        if ($digitMatches.Count -eq 0) {
            return @{ Reading = "00000"; Confidence = "none" }
        }

        $best = $digitMatches | Sort-Object { $_.Length } | Select-Object -Last 1

        if ($best.Length -ge 4) {
            return @{ Reading = $best.Value.PadLeft(5, '0'); Confidence = "ok" }
        }
        else {
            $allSeqs = ($digitMatches | ForEach-Object { $_.Value }) -join ","
            return @{ Reading = "00000"; Confidence = "low:$allSeqs" }
        }
    }
    catch {
        return @{ Reading = "00000"; Confidence = "error:$($_.Exception.Message)" }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Load settings.json; command-line params take precedence over file values
# ---------------------------------------------------------------------------
$settingsFile = Join-Path $PSScriptRoot ".." "config" "settings.json"
if (-not (Test-Path $settingsFile)) {
    Write-Error "settings.json not found: $settingsFile"
    exit 1
}
try {
    $s = Get-Content $settingsFile -Raw | ConvertFrom-Json
} catch {
    Write-Error "settings.json is not valid JSON ($settingsFile): $($_.Exception.Message)"
    exit 1
}
$settings = @{}
$s.PSObject.Properties | ForEach-Object { $settings[$_.Name] = $_.Value }
$paths = if ($s.PSObject.Properties['Paths']) { $s.Paths } else { $null }

function Resolve-RelativeSetting {
    param([string]$Key)
    $raw = $settings[$Key]
    if ([System.IO.Path]::IsPathRooted($raw)) { return $raw }
    return Join-Path (Split-Path $settingsFile -Parent) $raw
}

if (-not $PSBoundParameters.ContainsKey('Folder')) {
    $Folder = if ($paths -and $paths.PSObject.Properties['Source'] -and $paths.Source) {
        $paths.Source
    } else { $settings['Folder'] }
}
if (-not $PSBoundParameters.ContainsKey('LocationsJson'))           { $LocationsJson           = Resolve-RelativeSetting 'LocationsJson' }
if (-not $PSBoundParameters.ContainsKey('ExifToolPath'))            { $ExifToolPath            = Resolve-RelativeSetting 'ExifToolPath' }
if (-not $PSBoundParameters.ContainsKey('ProximityThresholdMiles')) { $ProximityThresholdMiles = [double]$settings['ProximityThresholdMiles'] }
if (-not $PSBoundParameters.ContainsKey('MaxTripMiles'))            { $MaxTripMiles            = [int]$settings['MaxTripMiles'] }

$fallbackLocation = if ($settings.ContainsKey('FallbackLocation') -and $settings['FallbackLocation']) {
    $settings['FallbackLocation']
} else { "Unknown" }

$configErrors = @()
if (-not $Folder)                     { $configErrors += "settings.json: 'Paths.Source' (or 'Folder') is required" }
elseif (-not (Test-Path $Folder))     { $configErrors += "Source folder not found: $Folder" }
if (-not (Test-Path $LocationsJson))  { $configErrors += "locations.json not found: $LocationsJson" }
if (-not (Test-Path $ExifToolPath))   { $configErrors += "ExifTool not found: $ExifToolPath" }
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

$outputFolder = if ($paths -and $paths.PSObject.Properties['Output'] -and $paths.Output) {
    $paths.Output
} else { $Folder }

$reportsDir = if ($paths -and $paths.PSObject.Properties['Reports'] -and $paths.Reports) {
    $paths.Reports
} else { Join-Path $PSScriptRoot ".." "logs" }
$logFile = Join-Path $reportsDir "rename-log.json"

$logsDir = if ($paths -and $paths.PSObject.Properties['Logs'] -and $paths.Logs) {
    $paths.Logs
} else { Join-Path $PSScriptRoot ".." "logs" }
if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir | Out-Null }
$transcriptPath = Join-Path $logsDir "rename-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Start-Transcript -Path $transcriptPath -Append | Out-Null

Write-Information "[Rename-Photos] Starting — source: $Folder" -InformationAction Continue

try {

$logEntries       = @()
$lastOdometer     = $null
$gapSinceLastGood = 0
$skipped          = [System.Collections.Generic.List[PSCustomObject]]::new()
$renamedCount     = 0

if (Test-Path $logFile) {
    $loaded = Get-Content $logFile -Raw | ConvertFrom-Json
    if ($null -ne $loaded) {
        $logEntries = @($loaded)
        $lastGood = $logEntries | Where-Object { $_.OdometerConfidence -eq 'ok' } | Select-Object -Last 1
        if ($lastGood) {
            $lastOdometer = [int]$lastGood.Odometer
            # Count non-ok entries after the last good one
            $lastGoodIndex = [array]::LastIndexOf($logEntries, $lastGood)
            $gapSinceLastGood = $logEntries.Count - $lastGoodIndex - 1
        }
    }
}

$photos = Get-ChildItem -Path $Folder -Filter "IMG_*.jpg"
if ($photos.Count -eq 0) {
    Write-Information "No IMG_*.jpg files found in $Folder" -InformationAction Continue
    exit 0
}

foreach ($file in $photos) {

    # Skip already-renamed files (pattern: yyMMdd-hhmm ...)
    if ($file.Name -match '^\d{6}-\d{4} ') {
        Write-Warning "  Already renamed, skipping: $($file.Name)"
        continue
    }

    Write-Information "Processing $($file.Name)..." -InformationAction Continue

    # --- EXIF: date/time and GPS ----------------------------------------
    $exifOut = & $ExifToolPath -s3 -DateTimeOriginal -GPSLatitude# -GPSLongitude# "$($file.FullName)" 2>&1
    $exifLines = @($exifOut | Where-Object { $_ -match '\S' })
    Write-Verbose "  EXIF raw output ($($exifLines.Count) lines): $($exifLines -join ' | ')"

    if ($exifLines.Count -lt 1 -or $exifLines[0] -notmatch '^\d{4}:\d{2}:\d{2} \d{2}:\d{2}:\d{2}') {
        Write-Warning "  No DateTimeOriginal - skipping $($file.Name)"
        $skipped.Add([PSCustomObject]@{ File = $file.Name; Reason = "EXIF: DateTimeOriginal missing or unreadable" })
        continue
    }

    $dateTimeRaw = $exifLines[0].Trim()   # e.g. "2026:03:01 14:32:15"
    Write-Verbose "  EXIF DateTimeOriginal: $dateTimeRaw"
    if ($dateTimeRaw -match '^(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2})') {
        $yy   = $matches[1].Substring(2, 2)
        $mm   = $matches[2]
        $dd   = $matches[3]
        $hh   = $matches[4]
        $mi   = $matches[5]
        $datePart = "$yy$mm$dd-$hh$mi"   # e.g. "260301-1432"
    }
    else {
        Write-Warning "  Could not parse date from '$dateTimeRaw' - skipping $($file.Name)"
        $skipped.Add([PSCustomObject]@{ File = $file.Name; Reason = "EXIF: date unparseable: '$dateTimeRaw'" })
        continue
    }

    # --- GPS proximity matching -----------------------------------------
    $locationName = $fallbackLocation
    $gpsLat       = ""
    $gpsLon       = ""

    if ($exifLines.Count -ge 3) {
        $latStr = $exifLines[1].Trim()
        $lonStr = $exifLines[2].Trim()
        Write-Verbose "  GPS raw: lat=$latStr lon=$lonStr"
        if ($latStr -match '^-?\d+(\.\d+)?$' -and $lonStr -match '^-?\d+(\.\d+)?$') {
            $gpsLat = $latStr
            $gpsLon = $lonStr
            $match  = Get-NearestLocation -Lat ([double]$latStr) -Lon ([double]$lonStr) `
                          -Locations $locations -ThresholdMiles $ProximityThresholdMiles
            if ($match) {
                $matchDist = Get-HaversineDistance ([double]$latStr) ([double]$lonStr) $match.lat $match.lon
                Write-Verbose "  GPS matched '$($match.name)' at $([Math]::Round($matchDist,3)) mi"
                $locationName = $match.name
            }
            else {
                Write-Warning "  GPS ($latStr, $lonStr) did not match any known location within $ProximityThresholdMiles mi - using '$fallbackLocation'"
            }
        }
        else {
            Write-Warning "  GPS data unparseable in $($file.Name) - skipping"
            $skipped.Add([PSCustomObject]@{ File = $file.Name; Reason = "GPS unparseable: '$latStr', '$lonStr'" })
            continue
        }
    }
    else {
        Write-Warning "  No GPS data in $($file.Name) - skipping"
        $skipped.Add([PSCustomObject]@{ File = $file.Name; Reason = "GPS absent" })
        continue
    }

    # --- OCR: odometer reading ------------------------------------------
    $ocr = Get-OdometerReading -ImagePath $file.FullName
    Write-Verbose "  OCR result: reading=$($ocr.Reading) confidence=$($ocr.Confidence)"
    if ($ocr.Confidence -eq 'ok') {
        $reading  = [int]$ocr.Reading
        $maxDelta = ($gapSinceLastGood + 1) * $MaxTripMiles
        Write-Verbose "  Odometer check: read=$reading prev=$lastOdometer maxDelta=$maxDelta"
        if ($null -ne $lastOdometer -and ($reading -lt $lastOdometer -or $reading -gt ($lastOdometer + $maxDelta))) {
            Write-Warning "  Odometer suspect: read $reading, previous was $lastOdometer (max delta $maxDelta mi)"
            $ocr = @{ Reading = "00000"; Confidence = "suspect:got=$reading,prev=$lastOdometer" }
        }
        else {
            $lastOdometer     = $reading
            $gapSinceLastGood = 0
        }
    }
    else {
        $gapSinceLastGood++
    }
    if ($ocr.Confidence -ne 'ok') {
        Write-Warning "  OCR confidence '$($ocr.Confidence)' for $($file.Name) - skipping"
        $skipped.Add([PSCustomObject]@{ File = $file.Name; Reason = "OCR: $($ocr.Confidence)" })
        continue
    }

    # --- Build new filename ---------------------------------------------
    $newName = "$datePart $locationName $($ocr.Reading).jpg"
    $newPath = Join-Path $outputFolder $newName

    # Skip rather than overwrite an existing file
    if (Test-Path $newPath) {
        Write-Warning "  Target already exists: $newName - skipping $($file.Name)"
        $skipped.Add([PSCustomObject]@{ File = $file.Name; Reason = "Target already exists: $newName" })
        continue
    }

    # --- Rename and log -------------------------------------------------
    if ($PSCmdlet.ShouldProcess($file.FullName, "Rename to $newName")) {
        Rename-Item -Path $file.FullName -NewName $newName
        Write-Information "  Renamed -> $newName" -InformationAction Continue
        $renamedCount++

        $logEntries += [PSCustomObject]@{
            OriginalFile       = $file.Name
            NewFile            = $newName
            DateTimeOriginal   = $dateTimeRaw
            Location           = $locationName
            Odometer           = $ocr.Reading
            OdometerConfidence = $ocr.Confidence
            GPSLat             = $gpsLat
            GPSLon             = $gpsLon
        }
        $logEntries | ConvertTo-Json | Out-File $logFile -Encoding utf8
    }
}

$processedCount = @($photos | Where-Object { $_.Name -notmatch '^\d{6}-\d{4} ' }).Count
Write-Information "" -InformationAction Continue
Write-Information "--- Summary ---" -InformationAction Continue
Write-Information "  Processed : $processedCount" -InformationAction Continue
Write-Information "  Renamed   : $renamedCount" -InformationAction Continue
Write-Information "  Skipped   : $($skipped.Count)" -InformationAction Continue
if ($skipped.Count -gt 0) {
    foreach ($s in $skipped) {
        Write-Information "    - $($s.File): $($s.Reason)" -InformationAction Continue
    }
}
Write-Information "  Log       : $logFile" -InformationAction Continue
Write-Information "[Rename-Photos] Done." -InformationAction Continue

} finally {
    Stop-Transcript | Out-Null
}
