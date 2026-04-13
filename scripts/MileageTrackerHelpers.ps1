<#
.SYNOPSIS
    Pure helper functions shared by Rename-Photos.ps1 and Build-Trips.ps1.

.DESCRIPTION
    This file has no top-level executable code. Dot-source it to bring all
    functions into scope:

        . "$PSScriptRoot\MileageTrackerHelpers.ps1"

    Functions:
      Get-HaversineDistance  - straight-line distance in miles between two lat/lon points
      Get-NearestLocation    - matches GPS coordinates to the closest known location
      Get-LocationMap        - builds a hashtable from a locations array (keyed by name)
      Get-ExpectedDistance   - road-distance estimate between two named locations
      Format-TripDate        - formats a datetime as M/d/yyyy
      Get-TripPairings       - deduplicates log entries and pairs them into trip rows
#>

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
# Deduplicate and pair log entries into trip rows
#
# Deduplication: removes entries where location, odometer, and timestamp are
# all the same as the previous entry within DuplicateWindowSeconds.
#
# Pairing: walks entries chronologically; each entry serves as the destination
# of the previous trip AND the origin of the next. Same-location consecutive
# entries (beyond the dedup window) are emitted as "stop" rows. A trailing
# unpaired entry is always emitted as "unpaired".
#
# Returns an array of PSCustomObject trip rows with columns:
#   Date, DepartureTime, ArrivalTime, Origin, Destination,
#   OdometerStart, OdometerEnd, Distance, ExpectedMiles,
#   MatchConfidence, Status, Notes, OriginFile, DestinationFile
# ---------------------------------------------------------------------------
function Get-TripPairings {
    param(
        [array]    $Entries,
        [hashtable]$LocationMap,
        [double]   $RoadFactor             = 1.25,
        [double]   $TolerancePct           = 0.20,
        [int]      $DuplicateWindowSeconds = 120
    )

    if (-not $Entries -or $Entries.Count -eq 0) { return @() }

    # --- Deduplication pre-pass -------------------------------------------
    $deduped   = @()
    $prevEntry = $null
    $dupCount  = 0

    foreach ($entry in $Entries) {
        if ($null -ne $prevEntry) {
            $gap          = ($entry.DateTime - $prevEntry.DateTime).TotalSeconds
            $sameLocation = $entry.Location -eq $prevEntry.Location
            $sameOdom     = $entry.Odometer -eq $prevEntry.Odometer

            if ($sameLocation -and $sameOdom -and $gap -lt $DuplicateWindowSeconds) {
                Write-Verbose "  Dedup: removing $($entry.File) (dup of $($prevEntry.File), $([int]$gap)s gap)"
                Write-Information "  Deduplicating $($entry.File) (duplicate of $($prevEntry.File), $([int]$gap)s gap)" -InformationAction Continue
                $dupCount++
                continue
            }
        }
        $deduped  += $entry
        $prevEntry = $entry
    }

    if ($dupCount -gt 0) {
        Write-Information "  Removed $dupCount duplicate(s). Proceeding with $($deduped.Count) entries." -InformationAction Continue
    }

    # --- Pairing pass -------------------------------------------------------
    $trips   = @()
    $pending = $null

    foreach ($entry in $deduped) {

        if ($null -eq $pending) {
            $pending = $entry
            continue
        }

        # Same location: dwell (arrival + departure)
        if ($entry.Location -eq $pending.Location) {
            $gap = ($entry.DateTime - $pending.DateTime).TotalSeconds
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
            $pending = $entry
            continue
        }

        # Different locations: this is a trip
        $odomDelta    = $entry.Odometer - $pending.Odometer
        $expectedDist = Get-ExpectedDistance $pending.Location $entry.Location $LocationMap $RoadFactor
        Write-Verbose "  Pairing: '$($pending.Location)' -> '$($entry.Location)' | odomDelta=$odomDelta | expectedDist=$expectedDist"

        $ocrBad     = ($pending.OdometerConfidence -ne "ok") -or ($entry.OdometerConfidence -ne "ok")
        $unknownLoc = ($pending.Location -eq "Unknown") -or ($entry.Location -eq "Unknown")

        $status = "review"
        $notes  = @()

        if ($ocrBad)     { $notes += "OCR low confidence" }
        if ($unknownLoc) { $notes += "unknown location" }

        if ($odomDelta -lt 0) {
            $notes  += "odometer decreased"
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
            Write-Verbose "  Distance check: deviation=$([Math]::Round($deviation*100,1))% tolerance=$([Math]::Round($TolerancePct*100,0))%"
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
        Write-Verbose "  Trip status: $status$(if ($notes) { ' - ' + ($notes -join '; ') })"

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

    return $trips
}
