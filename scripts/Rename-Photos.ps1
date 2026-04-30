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

.PARAMETER Source
    Path to the folder containing odometer photos.

.PARAMETER LocationsJson
    Path to locations.json. Relative paths are resolved from the script directory.

.PARAMETER ExifToolPath
    Path to the exiftool executable. Relative paths are resolved from the script directory.

.PARAMETER ProximityThresholdMiles
    Maximum distance in miles from a known location to count as a match.

.PARAMETER MaxSpeedMph
    Maximum plausible vehicle speed in mph. Used with the elapsed time since the last accepted
    reading to compute an upper bound on the expected odometer delta.

.PARAMETER StartOdometer
    Seeds the initial last-known odometer value when no prior state can be found via the
    three-level fallback chain (rename-state.json, rename-log.json, output directory scan).
    After the first real run completes, rename-state.json is written and this parameter is
    never needed again.

.EXAMPLE
    .\Rename-Photos.ps1 -WhatIf
    .\Rename-Photos.ps1
    .\Rename-Photos.ps1 -Source "D:\Photos\Odometer" -WhatIf
    .\Rename-Photos.ps1 -Confirm
    .\Rename-Photos.ps1 -StartOdometer 224570
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Source                  = "",
    [string]$LocationsJson           = "$PSScriptRoot\..\config\locations.json",
    [string]$ExifToolPath            = "$PSScriptRoot\..\exiftool-13.53_64\exiftool.exe",
    [double]$ProximityThresholdMiles = 1.0,
    [double]$MaxSpeedMph             = 80,
    [int]   $StartOdometer
)

. "$PSScriptRoot\MileageTrackerHelpers.ps1"


function New-PhotoContext {
    <#
    .SYNOPSIS
        Creates the shared photo context object passed through the pipeline.

    .DESCRIPTION
        Initialises all fields to safe defaults so downstream functions can rely
        on a consistent shape without defensive null checks.

    .PARAMETER File
        The FileInfo object for the source photo.

    .OUTPUTS
        pscustomobject with File, Exif, OCR, Location, Status, and Error fields.
    #>
    param(
        [System.IO.FileInfo]$File
    )
    return [pscustomobject]@{
        File = [pscustomobject]@{
            FullName = $File.FullName
            Name     = $File.Name
        }
        Exif = @{
            RawLines  = @()
            DateTime  = $null
            DatePart  = $null
            GPS = @{
                Lat = $null
                Lon = $null
            }
        }
        OCR = [pscustomobject]@{
            Reading    = $null
            Confidence = $null
            RawText    = $null
            Digits     = @()
            Error      = $null
        }
        Location = $null
        Status   = "Pending"
        Error    = $null
    }
}

function Get-ExifRawData {
    <#
    .SYNOPSIS
        Invokes ExifTool and returns the raw output lines for a single file.

    .DESCRIPTION
        Runs ExifTool with -s3 (value-only) to extract DateTimeOriginal,
        GPSLatitude, and GPSLongitude. Blank lines are filtered out so callers
        can rely on index-based access.

    .PARAMETER ExifToolPath
        Full path to the exiftool executable.

    .PARAMETER FilePath
        Full path to the photo file to inspect.

    .OUTPUTS
        String array: [0] DateTimeOriginal, [1] GPSLatitude, [2] GPSLongitude.
        The array may be shorter if fields are absent.
    #>
    param (
        [string]$ExifToolPath,
        [string]$FilePath
    )

    $exifOut = & $ExifToolPath -s3 -DateTimeOriginal -GPSLatitude# -GPSLongitude# "$FilePath" 2>&1

    return @($exifOut | Where-Object { $_ -match '\S' })
}

function Add-ExifDateTimeToPhotoContext {
    <#
    .SYNOPSIS
        Parses DateTimeOriginal from ExifTool output and enriches the context.

    .DESCRIPTION
        Stores the raw ExifTool lines on the context, then parses ExifLines[0]
        as a DateTimeOriginal value (yyyy:MM:dd HH:mm:ss). Sets Exif.DateTime
        (a [datetime]) and Exif.DatePart (the yyMMdd-hhmm filename prefix).
        Sets Status="Skip" and returns $false if the field is absent or malformed.

    .PARAMETER Photo
        The photo context object created by New-PhotoContext.

    .PARAMETER ExifLines
        Raw output lines from Get-ExifRawData.

    .OUTPUTS
        Boolean. $true on success; $false if DateTimeOriginal is absent or unparseable.
    #>
    param (
        [pscustomobject]$Photo,
        [string[]]$ExifLines
    )

    $Photo.Exif.RawLines = $ExifLines

    # --- validate DateTimeOriginal
    if ($ExifLines.Count -lt 1 -or $ExifLines[0] -notmatch '^\d{4}:\d{2}:\d{2} \d{2}:\d{2}:\d{2}') {
        $Photo.Status = "Skip"
        $Photo | Add-Member -NotePropertyName Error -NotePropertyValue "EXIF missing DateTimeOriginal" -Force
        return $false
    }

    $dt = $ExifLines[0].Trim()

    if ($dt -notmatch '^(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2})') {
        $Photo.Status = "Skip"
        $Photo | Add-Member -NotePropertyName Error -NotePropertyValue "EXIF date unparseable: $dt" -Force
        return $false
    }

    $year = [int]$matches[1]
    $mm   = [int]$matches[2]
    $dd   = [int]$matches[3]
    $hh   = [int]$matches[4]
    $mi   = [int]$matches[5]

    $Photo.Exif.DateTime = [datetime]::new($year, $mm, $dd, $hh, $mi, 0)
    $Photo.Exif.DatePart = ("{0:00}{1:00}{2:00}-{3:00}{4:00}" -f ($year % 100), $mm, $dd, $hh, $mi)

    return $true
}

function Add-GpsToPhotoContext {
    <#
    .SYNOPSIS
        Copies raw GPS latitude and longitude strings from ExifTool output into the context.

    .DESCRIPTION
        Assigns ExifLines[1] to Exif.GPS.Lat and ExifLines[2] to Exif.GPS.Lon when
        present. GPS fields are stored as raw strings; Add-LocationToPhotoContext
        is responsible for parsing and validating them.

    .PARAMETER Photo
        The photo context object created by New-PhotoContext.

    .PARAMETER ExifLines
        Raw output lines from Get-ExifRawData.

    .OUTPUTS
        The same pscustomobject passed in (modified in place).
    #>
    param (
        [pscustomobject]$Photo,
        [string[]]$ExifLines
    )

    if ($ExifLines.Count -ge 3) {
        $Photo.Exif.GPS.Lat = $ExifLines[1]
        $Photo.Exif.GPS.Lon = $ExifLines[2]
    }

    return $Photo
}

function Add-LocationToPhotoContext {
    <#
    .SYNOPSIS
        Matches GPS coordinates to the nearest known location by name.

    .DESCRIPTION
        Reads Exif.GPS.Lat and Exif.GPS.Lon from the context and calls
        Get-NearestLocation. Sets Photo.Location to the matched location name,
        or to FallbackLocation when no match is within ThresholdMiles.
        Returns $false and sets Status="Skip" if GPS is absent or unparseable.

    .PARAMETER Photo
        The photo context object created by New-PhotoContext.

    .PARAMETER Locations
        Array of location objects loaded from locations.json. Each must have
        name, lat, and lon properties.

    .PARAMETER ThresholdMiles
        Maximum haversine distance in miles to count as a location match.

    .PARAMETER FallbackLocation
        Location name to assign when no known location is within ThresholdMiles.

    .OUTPUTS
        Boolean. $true on success (including fallback); $false if GPS is absent
        or cannot be parsed as decimal degrees.
    #>
    param(
        [pscustomobject]$Photo,
        [array]         $Locations,
        [double]        $ThresholdMiles,
        [string]        $FallbackLocation
    )

    $lat = $Photo.Exif.GPS.Lat
    $lon = $Photo.Exif.GPS.Lon

    if ($null -eq $lat -or $null -eq $lon) {
        $Photo.Status = "Skip"
        $Photo.Error  = "GPS absent"
        return $false
    }

    $latStr = $lat.ToString().Trim()
    $lonStr = $lon.ToString().Trim()

    if ($latStr -notmatch '^-?\d+(\.\d+)?$' -or $lonStr -notmatch '^-?\d+(\.\d+)?$') {
        $Photo.Status = "Skip"
        $Photo.Error  = "GPS unparseable: '$latStr', '$lonStr'"
        return $false
    }

    $match = Get-NearestLocation -Lat ([double]$latStr) -Lon ([double]$lonStr) `
                 -Locations $Locations -ThresholdMiles $ThresholdMiles

    if ($match) {
        $matchDist = Get-HaversineDistance ([double]$latStr) ([double]$lonStr) $match.lat $match.lon
        Write-Verbose "  GPS matched '$($match.name)' at $([Math]::Round($matchDist, 3)) mi"
        $Photo.Location = $match.name
    }
    else {
        Write-Warning "  GPS ($latStr, $lonStr) did not match any known location within $ThresholdMiles mi - using '$FallbackLocation'"
        $Photo.Location = $FallbackLocation
    }

    return $true
}
function Get-OdometerReading {
    <#
    .SYNOPSIS
        Extracts the odometer reading from a photo using Windows OCR.

    .DESCRIPTION
        Loads the image via WinRT BitmapDecoder, runs it through OcrEngine, and
        selects the longest digit run as the odometer value.

        Decodes the image at a configurable scale percentage before OCR. Downscaling
        normalises digit size for close-up photos and smooths pixelation artefacts
        from digital displays. Defaults to 25% (suitable for 4032x3024 source images).

        Requires Windows PowerShell 5.1. Returns Confidence="error" immediately
        under PowerShell 6+, which lacks the required WinRT APIs.

        Confidence values:
          ok    - longest digit group is >= 4 digits; reading is reliable
          low   - longest digit group is < 4 digits; reading may be partial
          none  - OCR produced no digit groups at all
          error - engine unavailable, PS version incompatible, or exception thrown

    .PARAMETER ImagePath
        Full path to the photo file to analyse.

    .OUTPUTS
        PSCustomObject with Reading (string), Confidence (string), RawText (string),
        Digits (string[]), and Error (string) fields.
    #>
    param(
        [string]$ImagePath,
        [int]   $ScalePct = 25
    )

    $result = [PSCustomObject]@{
        Reading    = $null
        Confidence = $null
        RawText    = $null
        Digits     = @()
        Error      = $null
    }

    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $result.Confidence = "error"
        $result.Error = "OCR requires Windows PowerShell 5.1"
        return $result
    }

    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime

        $null = [Windows.Media.Ocr.OcrEngine,                     Windows.Foundation, ContentType=WindowsRuntime]
        $null = [Windows.Graphics.Imaging.BitmapDecoder,           Windows.Foundation, ContentType=WindowsRuntime]
        $null = [Windows.Graphics.Imaging.SoftwareBitmap,          Windows.Foundation, ContentType=WindowsRuntime]
        $null = [Windows.Graphics.Imaging.BitmapTransform,         Windows.Foundation, ContentType=WindowsRuntime]
        $null = [Windows.Graphics.Imaging.BitmapPixelFormat,       Windows.Foundation, ContentType=WindowsRuntime]
        $null = [Windows.Graphics.Imaging.BitmapAlphaMode,         Windows.Foundation, ContentType=WindowsRuntime]
        $null = [Windows.Graphics.Imaging.BitmapInterpolationMode, Windows.Foundation, ContentType=WindowsRuntime]
        $null = [Windows.Graphics.Imaging.ExifOrientationMode,     Windows.Foundation, ContentType=WindowsRuntime]
        $null = [Windows.Graphics.Imaging.ColorManagementMode,     Windows.Foundation, ContentType=WindowsRuntime]

        $asTaskMethod = [System.WindowsRuntimeSystemExtensions].GetMethods() |
            Where-Object {
                $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetParameters().Count -eq 1
            } | Select-Object -First 1

        function Invoke-WinRTAsync {
            param($AsyncOp, [type]$ResultType)
            $task = $asTaskMethod.MakeGenericMethod($ResultType).Invoke($null, @($AsyncOp))
            $task.Wait()
            return $task.Result
        }

        $absPath   = (Resolve-Path $ImagePath).Path
        $netStream = [System.IO.File]::OpenRead($absPath)
        $winStream = [System.IO.WindowsRuntimeStreamExtensions]::AsRandomAccessStream($netStream)

        $decoder = Invoke-WinRTAsync ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($winStream)) ([Windows.Graphics.Imaging.BitmapDecoder])

        $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
        if (-not $engine) {
            $winStream.Dispose()
            $netStream.Dispose()
            $result.Confidence = "error"
            $result.Error = "OCR engine unavailable"
            return $result
        }

        $scale              = [Math]::Min(1.0, $ScalePct / 100.0)
        $transform              = [Windows.Graphics.Imaging.BitmapTransform]::new()
        $transform.ScaledWidth  = [uint32][Math]::Max(1, [Math]::Round($decoder.PixelWidth  * $scale))
        $transform.ScaledHeight = [uint32][Math]::Max(1, [Math]::Round($decoder.PixelHeight * $scale))
        $transform.InterpolationMode = [Windows.Graphics.Imaging.BitmapInterpolationMode]::Linear

        $bitmap = Invoke-WinRTAsync ($decoder.GetSoftwareBitmapAsync(
            [Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8,
            [Windows.Graphics.Imaging.BitmapAlphaMode]::Premultiplied,
            $transform,
            [Windows.Graphics.Imaging.ExifOrientationMode]::IgnoreExifOrientation,
            [Windows.Graphics.Imaging.ColorManagementMode]::DoNotColorManage
        )) ([Windows.Graphics.Imaging.SoftwareBitmap])

        $winStream.Dispose()
        $netStream.Dispose()

        $ocrResult  = Invoke-WinRTAsync ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
        $result.RawText = $ocrResult.Text

        $digitMatches = [regex]::Matches($result.RawText, '\d+')
        if ($digitMatches.Count -eq 0) {
            $result.Confidence = 'none'
            return $result
        }

        $result.Digits = @($digitMatches | ForEach-Object { $_.Value })
        $best = $digitMatches | Sort-Object Length | Select-Object -Last 1
        $result.Reading    = $best.Value
        $result.Confidence = if ($best.Length -ge 4) { 'ok' } else { 'low' }

        return $result
    }
    catch {
        $result.Confidence = "error"
        $result.Error = $_.Exception.Message
        return $result
    }
}

function Add-OcrToPhotoContext {
    <#
    .SYNOPSIS
        Runs Windows OCR on the photo image and populates all OCR fields on the context.

    .DESCRIPTION
        Delegates to Get-OdometerReading and copies every result field onto
        Photo.OCR (Reading, Confidence, RawText, Digits, Error). Does not return
        a value; callers inspect Photo.OCR.Confidence to decide whether to proceed.

    .PARAMETER Photo
        The photo context object created by New-PhotoContext.

    .PARAMETER OcrScalePct
        Percentage of original image dimensions to decode at before running OCR.
        Passed through to Get-OdometerReading.

    .OUTPUTS
        None. Modifies Photo.OCR in place.
    #>
    param(
        [pscustomobject]$Photo,
        [int]           $OcrScalePct = 25
    )

    $result = Get-OdometerReading -ImagePath $Photo.File.FullName -ScalePct $OcrScalePct
    $Photo.OCR.Reading    = $result.Reading
    $Photo.OCR.Confidence = $result.Confidence
    $Photo.OCR.RawText    = $result.RawText
    $Photo.OCR.Digits     = $result.Digits
    $Photo.OCR.Error      = $result.Error
}

function Test-OdometerReading {
    <#
    .SYNOPSIS
        Validates and, where possible, recovers the OCR odometer reading.

    .DESCRIPTION
        Four-stage validation:

        1. Time bound — if LastGoodDateTime is known, the reading must fall in
           [LastOdometer, LastOdometer + ceil(elapsedHours * MaxSpeedMph)].
           Without a prior DateTime, only the lower bound (>= LastOdometer) is enforced.

        2. Location cross-check — when the reading exceeds the time bound but both
           the previous and current locations are known and differ, the odometer
           delta is compared to the expected road distance (haversine * RoadFactor).
           A delta within TolerancePct of expected auto-approves the reading.

        3. Low-confidence digit recovery — when OCR confidence is "low" and a time
           bound is available, each digit group in OCR.Digits is treated as a
           potential suffix of the true reading. All integers in
           [LastOdometer, maxAllowable] whose last N digits match the group are
           collected. If exactly one unique candidate emerges across all groups it
           is accepted with Confidence="recovered". Zero or multiple candidates
           cause the photo to be skipped.

        4. Decreased-reading recovery — when an ok-confidence reading is less than
           LastOdometer (OCR dropped digits from either end, or split the number),
           three independent passes are attempted in order, each returning
           immediately on a unique find:

             a. Concatenation — join all OCR.Digits groups in order; if the result
                falls in [LastOdometer, maxAllowable] it is accepted.

             b. Suffix — same algorithm as stage 3; values in range whose last N
                digits match each group.

             c. Prefix — values in [LastOdometer, maxAllowable] whose string
                representation starts with each digit group. When multiple
                candidates survive, a location-distance estimate is used to narrow
                the field: candidates whose odometer delta falls within TolerancePct
                of the haversine road distance are kept. Accepted only if exactly
                one candidate remains.

           Requires a time bound (maxAllowable) for all three passes. Photos are
           skipped when no pass yields a unique candidate.

        Always returns $true when LastOdometer is $null (first reading).

    .PARAMETER Photo
        The photo context object created by New-PhotoContext.

    .PARAMETER LastOdometer
        The most recently accepted odometer reading, or $null if none exists yet.
        Typed as [object] to preserve $null through the call.

    .PARAMETER LastGoodDateTime
        The DateTime of the last accepted reading, or $null if none exists yet.
        Typed as [object] to preserve $null through the call.

    .PARAMETER LastGoodLocation
        The location name of the last accepted reading, or $null if none exists yet.
        Typed as [object] to preserve $null through the call.

    .PARAMETER LocationMap
        Hashtable of location name -> location object, from Get-LocationMap.

    .PARAMETER MaxSpeedMph
        Maximum plausible vehicle speed in mph, used to compute the upper time bound.

    .PARAMETER RoadFactor
        Multiplier applied to haversine distance to estimate road distance.

    .PARAMETER TolerancePct
        Fractional tolerance for location distance cross-check (default 0.20 = 20%).

    .OUTPUTS
        Boolean. $true if the reading is valid or was recovered; $false otherwise.
    #>
    param(
        [pscustomobject]$Photo,
        [object]        $LastOdometer,
        [object]        $LastGoodDateTime,
        [object]        $LastGoodLocation,
        [hashtable]     $LocationMap,
        [double]        $MaxSpeedMph,
        [double]        $RoadFactor   = 1.25,
        [double]        $TolerancePct = 0.20
    )

    # No prior reading — always pass
    if ($null -eq $LastOdometer) { return $true }

    $lastOdom = [int]$LastOdometer

    # --- compute upper bound --------------------------------------------------
    $maxAllowable = $null
    if ($null -ne $LastGoodDateTime) {
        $elapsed      = ($Photo.Exif.DateTime - [datetime]$LastGoodDateTime).TotalHours
        $maxAllowable = [int]($lastOdom + [Math]::Ceiling($elapsed * $MaxSpeedMph))
        Write-Verbose "  Time bound: elapsed=$([Math]::Round($elapsed, 2))h maxAllowable=$maxAllowable"
    }

    # --- digit recovery for low-confidence readings ---------------------------
    if ($Photo.OCR.Confidence -eq 'low') {
        if ($null -eq $maxAllowable) {
            $Photo.Status = "Skip"
            $Photo.Error  = "OCR low confidence; no time reference available for digit recovery"
            return $false
        }

        $candidates = [System.Collections.Generic.List[int]]::new()
        foreach ($group in $Photo.OCR.Digits) {
            $groupLen = $group.Length
            $modulus  = [int][Math]::Pow(10, $groupLen)
            $suffix   = [int]$group
            $rem      = $lastOdom % $modulus
            $delta    = ($suffix - $rem + $modulus) % $modulus
            $n        = $lastOdom + $delta
            while ($n -le $maxAllowable) {
                $candidates.Add($n)
                $n += $modulus
            }
        }

        $unique = @($candidates | Sort-Object -Unique)
        Write-Verbose "  Digit recovery: candidates=$($unique -join ', ')"

        if ($unique.Count -eq 1) {
            $Photo.OCR.Reading    = $unique[0].ToString()
            $Photo.OCR.Confidence = "recovered"
            Write-Verbose "  Recovered reading: $($Photo.OCR.Reading)"
            return $true
        }

        $Photo.Status = "Skip"
        $Photo.Error  = if ($unique.Count -eq 0) {
            "Digit recovery: no candidate in time window [$lastOdom, $maxAllowable]"
        } else {
            "Digit recovery: $($unique.Count) ambiguous candidates ($($unique -join ', '))"
        }
        return $false
    }

    # --- validate ok-confidence reading ---------------------------------------
    $reading = [int]$Photo.OCR.Reading
    Write-Verbose "  Odometer check: read=$reading prev=$lastOdom$(if ($null -ne $maxAllowable) { " max=$maxAllowable" })"

    if ($reading -lt $lastOdom) {
        # Require a time bound before attempting recovery
        if ($null -eq $maxAllowable) {
            $Photo.OCR.Confidence = "suspect"
            $Photo.Status         = "Skip"
            $Photo.Error          = "Odometer decreased: read $reading, previous was $lastOdom (no time reference for recovery)"
            return $false
        }

        # --- Pass a: concatenation — join all digit groups in order -----------
        $concat    = [string]::Join('', $Photo.OCR.Digits)
        $concatVal = $null
        if ($concat -match '^\d+$' -and [long]::TryParse($concat, [ref]$concatVal)) {
            Write-Verbose "  Decreased recovery (concat): trying $concatVal"
            if ($concatVal -ge $lastOdom -and $concatVal -le $maxAllowable) {
                $Photo.OCR.Reading    = $concatVal.ToString()
                $Photo.OCR.Confidence = "recovered"
                Write-Verbose "  Recovered reading (concatenation): $($Photo.OCR.Reading)"
                return $true
            }
        }

        # --- Pass b: suffix — values in range ending in each digit group ------
        $suffixCandidates = [System.Collections.Generic.List[int]]::new()
        foreach ($group in $Photo.OCR.Digits) {
            $groupLen = $group.Length
            $modulus  = [int][Math]::Pow(10, $groupLen)
            $suffix   = [int]$group
            $rem      = $lastOdom % $modulus
            $delta    = ($suffix - $rem + $modulus) % $modulus
            $n        = $lastOdom + $delta
            while ($n -le $maxAllowable) {
                $suffixCandidates.Add($n)
                $n += $modulus
            }
        }
        $uniqueSuffix = @($suffixCandidates | Sort-Object -Unique)
        Write-Verbose "  Decreased recovery (suffix): candidates=$($uniqueSuffix -join ', ')"
        if ($uniqueSuffix.Count -eq 1) {
            $Photo.OCR.Reading    = $uniqueSuffix[0].ToString()
            $Photo.OCR.Confidence = "recovered"
            Write-Verbose "  Recovered reading (suffix): $($Photo.OCR.Reading)"
            return $true
        }

        # --- Pass c: prefix — values in range starting with each digit group --
        $expectedLen      = $lastOdom.ToString().Length
        $prefixCandidates = [System.Collections.Generic.List[int]]::new()
        foreach ($group in $Photo.OCR.Digits) {
            $missingDigits = $expectedLen - $group.Length
            if ($missingDigits -le 0) { continue }
            $scale    = [long][Math]::Pow(10, $missingDigits)
            $pMin     = [long]([int]$group) * $scale
            $pMax     = ([long]([int]$group) + 1L) * $scale - 1L
            $rangeMin = [int][Math]::Max([long]$lastOdom, $pMin)
            $rangeMax = [int][Math]::Min([long]$maxAllowable, $pMax)
            for ($n = $rangeMin; $n -le $rangeMax; $n++) {
                $prefixCandidates.Add($n)
            }
        }
        $uniquePrefix = @($prefixCandidates | Sort-Object -Unique)
        Write-Verbose "  Decreased recovery (prefix): $($uniquePrefix.Count) candidate(s)"

        if ($uniquePrefix.Count -eq 1) {
            $Photo.OCR.Reading    = $uniquePrefix[0].ToString()
            $Photo.OCR.Confidence = "recovered"
            Write-Verbose "  Recovered reading (prefix): $($Photo.OCR.Reading)"
            return $true
        }

        if ($uniquePrefix.Count -gt 1 -and
            $LastGoodLocation -and $Photo.Location -and
            $Photo.Location -ne $LastGoodLocation) {
            $expectedDist = Get-ExpectedDistance ([string]$LastGoodLocation) $Photo.Location $LocationMap $RoadFactor
            if ($expectedDist -gt 0) {
                $locationFiltered = @($uniquePrefix | Where-Object {
                    [Math]::Abs($_ - $lastOdom - $expectedDist) / $expectedDist -le $TolerancePct
                })
                Write-Verbose "  Prefix + location: expected delta=$([Math]::Round($expectedDist)) filtered to $($locationFiltered.Count) candidate(s)"
                if ($locationFiltered.Count -eq 1) {
                    $Photo.OCR.Reading    = $locationFiltered[0].ToString()
                    $Photo.OCR.Confidence = "recovered"
                    Write-Verbose "  Recovered reading (prefix+location): $($Photo.OCR.Reading)"
                    return $true
                }
            }
        }

        $Photo.OCR.Confidence = "suspect"
        $Photo.Status         = "Skip"
        $Photo.Error          = "Odometer decreased: read $reading, previous was $lastOdom; recovery failed"
        return $false
    }

    if ($null -ne $maxAllowable -and $reading -gt $maxAllowable) {
        # Try location cross-check before rejecting
        $crossCheckPassed = $false
        if ($LastGoodLocation -and $Photo.Location -and $Photo.Location -ne $LastGoodLocation) {
            $expected = Get-ExpectedDistance ([string]$LastGoodLocation) $Photo.Location $LocationMap $RoadFactor
            if ($expected -gt 0) {
                $deviation = [Math]::Abs(($reading - $lastOdom) - $expected) / $expected
                Write-Verbose "  Location cross-check: delta=$($reading - $lastOdom) expected=$expected deviation=$([Math]::Round($deviation * 100, 1))%"
                if ($deviation -le $TolerancePct) {
                    $crossCheckPassed = $true
                    Write-Verbose "  Location cross-check auto-approved reading"
                }
            }
        }

        if (-not $crossCheckPassed) {
            $Photo.OCR.Confidence = "suspect"
            $Photo.Status         = "Skip"
            $Photo.Error          = "Odometer out of time range: read $reading, expected <= $maxAllowable (prev $lastOdom)"
            return $false
        }
    }

    return $true
}

function Invoke-PhotoRename {
    <#
    .SYNOPSIS
        Builds the target filename, checks for collisions, then renames and moves the file.

    .DESCRIPTION
        Derives the new name from Photo.Exif.DatePart, Photo.Location, and
        Photo.OCR.Reading. Derives the destination subfolder from Photo.Exif.DateTime
        formatted with SortFolderFormat. If the target path already exists, sets
        Status="Skip" and returns $null. Supports -WhatIf and -Confirm via
        ShouldProcess; returns $null without modifying Status when suppressed by -WhatIf.

    .PARAMETER Photo
        The photo context object created by New-PhotoContext.

    .PARAMETER OutputFolder
        Root folder under which the dated subfolder is created.

    .PARAMETER SortFolderFormat
        A .NET date format string (e.g. "yyyy/yyMM") used to build the subfolder path.

    .OUTPUTS
        String. The full path of the renamed file, or $null on collision or -WhatIf.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [pscustomobject]$Photo,
        [string]        $OutputFolder,
        [string]        $SortFolderFormat
    )

    $newName    = "$($Photo.Exif.DatePart) $($Photo.Location) $($Photo.OCR.Reading).jpg"
    $destFolder = Join-Path $OutputFolder $Photo.Exif.DateTime.ToString($SortFolderFormat, [System.Globalization.CultureInfo]::InvariantCulture)
    $newPath    = Join-Path $destFolder $newName

    if (Test-Path $newPath) {
        Write-Warning "  Target already exists: $newName - skipping $($Photo.File.Name)"
        $Photo.Status = "Skip"
        $Photo.Error  = "Target already exists: $newName"
        return $null
    }

    if ($PSCmdlet.ShouldProcess($Photo.File.FullName, "Rename to $newName and move to $destFolder")) {
        $renamedPath = Join-Path (Split-Path $Photo.File.FullName -Parent) $newName
        Rename-Item -Path $Photo.File.FullName -NewName $newName
        if (-not (Test-Path $destFolder)) { New-Item -ItemType Directory -Path $destFolder | Out-Null }
        Move-Item -Path $renamedPath -Destination $destFolder
        Write-Information "  Renamed and moved -> $newPath" -InformationAction Continue
        $Photo.Status = "Renamed"
        return $newPath
    }

    return $null
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Guard: when dot-sourced (e.g. by Pester), skip the main body so callers
# can access the functions defined above without running the script.
if ($MyInvocation.InvocationName -eq '.') { return }

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Load settings.json; command-line params take precedence over file values
# ---------------------------------------------------------------------------
$settingsFile = Join-Path $PSScriptRoot "..\config\settings.json"
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
    <#
    .SYNOPSIS
        Resolves a settings.json value to an absolute path.

    .DESCRIPTION
        Looks up Key in the $settings hashtable. If the value is already an
        absolute path it is returned as-is; otherwise it is resolved relative
        to the directory that contains settings.json.

    .PARAMETER Key
        The settings hashtable key whose value should be resolved.

    .OUTPUTS
        String. The absolute path for the setting value.
    #>
    param([string]$Key)
    $raw = $settings[$Key]
    if ([System.IO.Path]::IsPathRooted($raw)) { return $raw }
    return Join-Path (Split-Path $settingsFile -Parent) $raw
}

$Source = if ($paths -and $paths.PSObject.Properties['Source'] -and $paths.Source) {
    $paths.Source
}
if (-not $PSBoundParameters.ContainsKey('LocationsJson'))           { $LocationsJson           = Resolve-RelativeSetting 'LocationsJson' }
if (-not $PSBoundParameters.ContainsKey('ExifToolPath'))            { $ExifToolPath            = Resolve-RelativeSetting 'ExifToolPath' }
if (-not $PSBoundParameters.ContainsKey('ProximityThresholdMiles') -and $settings.ContainsKey('ProximityThresholdMiles')) { $ProximityThresholdMiles = [double]$settings['ProximityThresholdMiles'] }
if (-not $PSBoundParameters.ContainsKey('MaxSpeedMph')             -and $settings.ContainsKey('MaxSpeedMph'))             { $MaxSpeedMph             = [double]$settings['MaxSpeedMph'] }
$roadFactor   = if ($settings.ContainsKey('RoadFactor'))      { [double]$settings['RoadFactor'] }      else { 1.25 }
$tolerancePct = if ($settings.ContainsKey('TolerancePct'))    { [double]$settings['TolerancePct'] }    else { 0.20 }
$ocrScalePct  = if ($settings.ContainsKey('OcrScalePercent')) { [int]$settings['OcrScalePercent'] }    else { 25 }

$fallbackLocation = if ($settings.ContainsKey('FallbackLocation') -and $settings['FallbackLocation']) {
    $settings['FallbackLocation']
} else { "Unknown" }

$sortFolderFormat = if ($settings.ContainsKey('SortFolderFormat') -and $settings['SortFolderFormat']) {
    $settings['SortFolderFormat']
} else { "yyyy/yyMM" }

$configErrors = @()
if (-not $Source)                     { $configErrors += "settings.json: 'Paths.Source' (or 'Folder') is required" }
elseif (-not (Test-Path $Source))     { $configErrors += "Source folder not found: $Source" }
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
$locationMap = Get-LocationMap -Locations $locations

$outputFolder = if ($paths -and $paths.PSObject.Properties['Output'] -and $paths.Output) {
    $paths.Output
} else { $Source }

$logsDir = if ($paths -and $paths.PSObject.Properties['Logs'] -and $paths.Logs) {
    $paths.Logs
} else { Join-Path $PSScriptRoot "..\logs" }
if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir | Out-Null }
$stateFile = Join-Path $logsDir "rename-state.json"
$auditLog  = Join-Path $logsDir "rename-log.json"

Write-Information "[Rename-Photos] Starting - source: $Source" -InformationAction Continue

# Collect source photos before the fallback chain so temporal filtering is available.
$photos = @(Get-ChildItem -Path $Source -Filter "IMG_*.jpeg")
if ($photos.Count -eq 0) {
    Write-Information "No IMG_*.jpeg files found in $Source" -InformationAction Continue
    exit 0
}

# Pre-pass: find the earliest EXIF datetime across all source photos.
# Levels 1-3 of the prior-state fallback chain use this to skip state that is
# newer than the current batch, which would cause validation to fail on older photos.
$earliestSourceDate = $null
$prePassArgs = @('-s3', '-DateTimeOriginal') + ($photos | ForEach-Object { $_.FullName })
foreach ($raw in (& $ExifToolPath @prePassArgs 2>&1)) {
    if ($raw -match '^(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2})') {
        try {
            $d = [datetime]::new([int]$Matches[1],[int]$Matches[2],[int]$Matches[3],[int]$Matches[4],[int]$Matches[5],0)
            if ($null -eq $earliestSourceDate -or $d -lt $earliestSourceDate) { $earliestSourceDate = $d }
        } catch {}
    }
}
Write-Verbose "  Earliest source photo: $(if ($earliestSourceDate) { $earliestSourceDate } else { '(unknown)' })"

$lastOdometer     = $null
$lastGoodDateTime = $null
$lastGoodLocation = $null
$skipped          = [System.Collections.Generic.List[PSCustomObject]]::new()
$renamedCount     = 0

# Level 1: rename-state.json
if (Test-Path $stateFile) {
    try {
        $state = Get-Content $stateFile -Raw | ConvertFrom-Json
        if ($state.Odometer -and $state.DateTimeOriginal) {
            $stateDateTime = [datetime]::ParseExact($state.DateTimeOriginal.Trim(), "yyyy:MM:dd HH:mm:ss", $null)
            if ($null -ne $earliestSourceDate -and $stateDateTime -ge $earliestSourceDate) {
                Write-Verbose "  State file skipped: state datetime ($stateDateTime) is not before earliest source photo ($earliestSourceDate)"
            } else {
                $lastOdometer     = [int]$state.Odometer
                $lastGoodDateTime = $stateDateTime
                $lastGoodLocation = $state.Location
                Write-Verbose "  Prior state (state file): odometer=$lastOdometer dateTime=$lastGoodDateTime location=$lastGoodLocation"
            }
        }
    } catch {
        Write-Warning "Could not load state file ($stateFile): $($_.Exception.Message)"
    }
}

# Level 2: rename-log.json
if ($null -eq $lastOdometer -and (Test-Path $auditLog)) {
    try {
        $lastGood = @(Get-Content $auditLog -Raw | ConvertFrom-Json) |
            Where-Object { $_.OdometerConfidence -eq 'ok' -or $_.OdometerConfidence -eq 'recovered' } |
            Where-Object {
                if ($null -eq $earliestSourceDate) { return $true }
                try { ([datetime]::ParseExact($_.DateTimeOriginal.Trim(), "yyyy:MM:dd HH:mm:ss", $null)) -lt $earliestSourceDate }
                catch { $true }
            } |
            Select-Object -Last 1
        if ($lastGood) {
            $lastOdometer     = [int]$lastGood.Odometer
            $lastGoodDateTime = [datetime]::ParseExact($lastGood.DateTimeOriginal.Trim(), "yyyy:MM:dd HH:mm:ss", $null)
            $lastGoodLocation = $lastGood.Location
            Write-Verbose "  Prior state (audit log): odometer=$lastOdometer dateTime=$lastGoodDateTime location=$lastGoodLocation"
        }
    } catch {
        Write-Warning "Could not load prior state from audit log ($auditLog): $($_.Exception.Message)"
    }
}

# Level 3: output directory scan
if ($null -eq $lastOdometer) {
    try {
        $lastRenamed = Get-ChildItem -Path $outputFolder -Recurse -Filter "*.jpg" -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -match '^\d{6}-\d{4} ' } |
            Where-Object {
                if ($null -eq $earliestSourceDate) { return $true }
                if ($_.BaseName -match '^(\d{2})(\d{2})(\d{2})-(\d{2})(\d{2}) ') {
                    try { [datetime]::new(2000 + [int]$Matches[1],[int]$Matches[2],[int]$Matches[3],[int]$Matches[4],[int]$Matches[5],0) -lt $earliestSourceDate }
                    catch { $false }
                } else { $false }
            } |
            Sort-Object Name |
            Select-Object -Last 1
        if ($lastRenamed) {
            $tokens = $lastRenamed.BaseName -split ' '
            if ($tokens.Count -ge 3 -and $tokens[-1] -match '^\d+$') {
                $lastOdometer = [int]$tokens[-1]
                if ($lastRenamed.BaseName -match '^(\d{2})(\d{2})(\d{2})-(\d{2})(\d{2}) ') {
                    try { $lastGoodDateTime = [datetime]::new(2000 + [int]$Matches[1],[int]$Matches[2],[int]$Matches[3],[int]$Matches[4],[int]$Matches[5],0) }
                    catch {}
                }
                Write-Verbose "  Prior state (directory scan): odometer=$lastOdometer from $($lastRenamed.Name)"
            }
        }
    } catch {
        Write-Warning "Directory scan for prior state failed: $($_.Exception.Message)"
    }
}

# Level 4: -StartOdometer parameter
if ($null -eq $lastOdometer -and $PSBoundParameters.ContainsKey('StartOdometer')) {
    $lastOdometer = $StartOdometer
    Write-Verbose "  Prior state (StartOdometer): odometer=$lastOdometer"
}

# ---------------------------------------------------------------------------
# Data pipeline
# ---------------------------------------------------------------------------
foreach ($file in $photos) {

    Write-Information "Processing $($file.Name)..." -InformationAction Continue

    # 1. Create context
    $photo = New-PhotoContext -File $file

    # 2. EXIF extraction
    $exifLines = @(Get-ExifRawData -ExifToolPath $ExifToolPath -FilePath $file.FullName)
    Write-Verbose "  EXIF raw output ($($exifLines.Count) lines): $($exifLines -join ' | ')"

    # 3. DateTime enrichment
    if (-not (Add-ExifDateTimeToPhotoContext -Photo $photo -ExifLines $exifLines)) {
        Write-Warning "Skipping $($photo.File.Name): $($photo.Error)"
        $skipped.Add([PSCustomObject]@{ File = $photo.File.Name; Reason = $photo.Error })
        continue
    }

    # 4. GPS enrichment
    $null = Add-GpsToPhotoContext -Photo $photo -ExifLines $exifLines

    # 5. Location matching
    if (-not (Add-LocationToPhotoContext -Photo $photo -Locations $locations -ThresholdMiles $ProximityThresholdMiles -FallbackLocation $fallbackLocation)) {
        Write-Warning "Skipping $($photo.File.Name): $($photo.Error)"
        $skipped.Add([PSCustomObject]@{ File = $photo.File.Name; Reason = $photo.Error })
        continue
    }

    # 6. OCR reading
    Add-OcrToPhotoContext -Photo $photo -OcrScalePct $ocrScalePct
    Write-Verbose "  OCR result: reading=$($photo.OCR.Reading) confidence=$($photo.OCR.Confidence)"

    if ($photo.OCR.Confidence -eq 'none' -or $photo.OCR.Confidence -eq 'error') {
        Write-Warning "  OCR $($photo.OCR.Confidence) for $($photo.File.Name) - skipping"
        $skipped.Add([PSCustomObject]@{ File = $photo.File.Name; Reason = "OCR: $($photo.OCR.Confidence)" })
        continue
    }

    # 6a. Plausibility guard — skip readings that can't fit in Int32 or exceed 9,999,999 mi
    if ($photo.OCR.Reading -match '^\d+$' -and ($photo.OCR.Reading.Length -gt 7 -or [long]$photo.OCR.Reading -gt 9999999)) {
        Write-Warning "  OCR reading '$($photo.OCR.Reading)' out of plausible range for $($photo.File.Name) - skipping"
        $skipped.Add([PSCustomObject]@{ File = $photo.File.Name; Reason = "OCR reading out of range: $($photo.OCR.Reading)" })
        continue
    }

    # 7. Odometer validation
    if (-not (Test-OdometerReading -Photo $photo -LastOdometer $lastOdometer -LastGoodDateTime $lastGoodDateTime -LastGoodLocation $lastGoodLocation -LocationMap $locationMap -MaxSpeedMph $MaxSpeedMph -RoadFactor $roadFactor -TolerancePct $tolerancePct)) {
        Write-Warning "  $($photo.Error)"
        $skipped.Add([PSCustomObject]@{ File = $photo.File.Name; Reason = $photo.Error })
        continue
    }
    $lastOdometer     = [int]$photo.OCR.Reading
    $lastGoodDateTime = $photo.Exif.DateTime
    $lastGoodLocation = $photo.Location

    # 8. Rename and move
    $newPath = Invoke-PhotoRename -Photo $photo -OutputFolder $outputFolder -SortFolderFormat $sortFolderFormat
    if ($photo.Status -eq "Skip") {
        $skipped.Add([PSCustomObject]@{ File = $photo.File.Name; Reason = $photo.Error })
        continue
    }
    if (-not $newPath) { continue }  # WhatIf

    $renamedCount++

    $entry = [PSCustomObject]@{
        OriginalFile       = $photo.File.Name
        NewFile            = [System.IO.Path]::GetFileName($newPath)
        DestinationPath    = $newPath
        DateTimeOriginal   = $photo.Exif.RawLines[0]
        Location           = $photo.Location
        Odometer           = $photo.OCR.Reading
        OdometerConfidence = $photo.OCR.Confidence
        GPSLat             = $photo.Exif.GPS.Lat
        GPSLon             = $photo.Exif.GPS.Lon
    }

    [PSCustomObject]@{
        Odometer           = $photo.OCR.Reading
        DateTimeOriginal   = $photo.Exif.RawLines[0]
        Location           = $photo.Location
        OdometerConfidence = $photo.OCR.Confidence
    } | ConvertTo-Json | Out-File $stateFile -Encoding utf8

    $existing = @()
    if (Test-Path $auditLog) {
        try { $existing = @(Get-Content $auditLog -Raw | ConvertFrom-Json) } catch {}
    }
    $existing = @($existing | Where-Object { $_.OriginalFile -ne $entry.OriginalFile })
    $existing += $entry
    ConvertTo-Json -InputObject $existing | Out-File $auditLog -Encoding utf8
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
Write-Information "  Log       : $auditLog" -InformationAction Continue
Write-Information "[Rename-Photos] Done." -InformationAction Continue
