#Requires -Version 5.1
<#
.SYNOPSIS
    Pester tests for Build-Trips.ps1 helper logic and trip-pairing algorithm.

.NOTES
    Tests dot-source MileageTrackerHelpers.ps1 only -- no file system, CSV
    reads, or settings.json required.

    Test locations use the same round coordinates as locations.example.json:
      Home: 44.0, -84.0
      Work: 43.0, -85.0
    Haversine straight-line distance ~85.4 mi; road distance ~106.7 mi.
#>

BeforeAll {
    . "$PSScriptRoot\..\scripts\MileageTrackerHelpers.ps1"

    $script:testLocations = @(
        [PSCustomObject]@{ name = "Home"; lat = 44.0; lon = -84.0 },
        [PSCustomObject]@{ name = "Work"; lat = 43.0; lon = -85.0 }
    )
    $script:locationMap = Get-LocationMap $script:testLocations

    function script:New-Entry {
        param(
            [string]   $File,
            [datetime] $DateTime,
            [string]   $Location,
            [int]      $Odometer,
            [string]   $Confidence = "ok"
        )
        [PSCustomObject]@{
            File               = $File
            DateTime           = $DateTime
            Location           = $Location
            Odometer           = $Odometer
            OdometerConfidence = $Confidence
        }
    }
}

# ---------------------------------------------------------------------------
Describe "Format-TripDate" {

    It "formats a single-digit month and day as M/d/yyyy" {
        $dt = [datetime]::new(2026, 3, 1, 14, 32, 0)
        Format-TripDate $dt | Should -Be "3/1/2026"
    }

    It "formats a double-digit month and day as M/d/yyyy" {
        $dt = [datetime]::new(2026, 11, 15, 9, 0, 0)
        Format-TripDate $dt | Should -Be "11/15/2026"
    }
}

# ---------------------------------------------------------------------------
Describe "Get-LocationMap" {

    It "builds a hashtable keyed by location name" {
        $map = Get-LocationMap $script:testLocations
        $map.ContainsKey("Home") | Should -Be $true
        $map.ContainsKey("Work") | Should -Be $true
    }

    It "preserves lat/lon values" {
        $map = Get-LocationMap $script:testLocations
        $map["Work"].lat | Should -Be 43
        $map["Work"].lon | Should -Be -85
    }
}

# ---------------------------------------------------------------------------
Describe "Get-ExpectedDistance" {

    It "returns -1 when a location name is unknown" {
        $d = Get-ExpectedDistance "Home" "Nowhere" $script:locationMap 1.25
        $d | Should -Be -1
    }

    It "returns -1 when both location names are unknown" {
        $d = Get-ExpectedDistance "Nowhere" "Elsewhere" $script:locationMap 1.25
        $d | Should -Be -1
    }

    It "returns a positive road distance for two known locations" {
        # Straight-line Home->Work ~85.4 mi; x 1.25 ~106.7 mi
        $d = Get-ExpectedDistance "Home" "Work" $script:locationMap 1.25
        $d | Should -BeGreaterThan 95
        $d | Should -BeLessThan 120
    }

    It "is symmetric (Home->Work equals Work->Home)" {
        $d1 = Get-ExpectedDistance "Home" "Work" $script:locationMap 1.25
        $d2 = Get-ExpectedDistance "Work" "Home" $script:locationMap 1.25
        $d1 | Should -Be $d2
    }
}

# ---------------------------------------------------------------------------
Describe "Get-TripPairings - pairing" {

    It "pairs two consecutive different-location entries into one trip plus a trailing unpaired" {
        $entries = @(
            (New-Entry "a.jpg" ([datetime]"2026-03-01 08:00:00") "Home" 47800),
            (New-Entry "b.jpg" ([datetime]"2026-03-01 09:45:00") "Work" 47910)
        )
        $trips = Get-TripPairings -Entries $entries -LocationMap $script:locationMap
        # trip[0]: Home->Work; trip[1]: Work trailing unpaired
        $trips.Count            | Should -Be 2
        $trips[0].Origin        | Should -Be "Home"
        $trips[0].Destination   | Should -Be "Work"
        $trips[0].OdometerStart | Should -Be 47800
        $trips[0].OdometerEnd   | Should -Be 47910
        $trips[0].Distance      | Should -Be 110
    }

    It "assigns Status = auto when odometer delta is within tolerance of expected distance" {
        # Expected Home->Work ~106.7 mi; delta 110 = ~3% off (< 20%)
        $entries = @(
            (New-Entry "a.jpg" ([datetime]"2026-03-01 08:00:00") "Home" 47800),
            (New-Entry "b.jpg" ([datetime]"2026-03-01 09:45:00") "Work" 47910)
        )
        $trips = Get-TripPairings -Entries $entries -LocationMap $script:locationMap
        $trips[0].Status | Should -Be "auto"
    }

    It "assigns Status = review when odometer delta is outside tolerance" {
        # delta 300 mi is ~181% off expected ~106.7 mi
        $entries = @(
            (New-Entry "a.jpg" ([datetime]"2026-03-01 08:00:00") "Home" 47800),
            (New-Entry "b.jpg" ([datetime]"2026-03-01 09:45:00") "Work" 48100)
        )
        $trips = Get-TripPairings -Entries $entries -LocationMap $script:locationMap
        $trips[0].Status | Should -Be "review"
    }

    It "assigns Status = review when OCR confidence is not ok" {
        $entries = @(
            (New-Entry "a.jpg" ([datetime]"2026-03-01 08:00:00") "Home" 47800 "low:1234"),
            (New-Entry "b.jpg" ([datetime]"2026-03-01 09:45:00") "Work" 47910 "ok")
        )
        $trips = Get-TripPairings -Entries $entries -LocationMap $script:locationMap
        $trips[0].Status | Should -Be "review"
    }

    It "includes OriginFile and DestinationFile on trip rows" {
        $entries = @(
            (New-Entry "orig.jpg" ([datetime]"2026-03-01 08:00:00") "Home" 47800),
            (New-Entry "dest.jpg" ([datetime]"2026-03-01 09:45:00") "Work" 47910)
        )
        $trips = Get-TripPairings -Entries $entries -LocationMap $script:locationMap
        $trips[0].OriginFile      | Should -Be "orig.jpg"
        $trips[0].DestinationFile | Should -Be "dest.jpg"
    }
}

# ---------------------------------------------------------------------------
Describe "Get-TripPairings - unpaired entries" {

    It "marks the trailing entry as unpaired after a round trip" {
        # Home->Work->Home: two complete trips + trailing Home unpaired
        $entries = @(
            (New-Entry "a.jpg" ([datetime]"2026-03-01 08:00:00") "Home" 47800),
            (New-Entry "b.jpg" ([datetime]"2026-03-01 09:45:00") "Work" 47910),
            (New-Entry "c.jpg" ([datetime]"2026-03-02 08:00:00") "Home" 48015)
        )
        $trips = Get-TripPairings -Entries $entries -LocationMap $script:locationMap
        $trips.Count          | Should -Be 3
        $trips[0].Status      | Should -Be "auto"     # Home->Work
        $trips[1].Status      | Should -Be "auto"     # Work->Home
        $trips[2].Status      | Should -Be "unpaired"
        $trips[2].Destination | Should -Be ""
        $trips[2].Notes       | Should -Be "no partner found"
    }

    It "handles a single entry -- emits it as unpaired" {
        $entries = @(
            (New-Entry "only.jpg" ([datetime]"2026-03-01 08:00:00") "Home" 47800)
        )
        # Wrap in @() to prevent PS unwrapping single-element result
        $trips = @(Get-TripPairings -Entries $entries -LocationMap $script:locationMap)
        $trips.Count     | Should -Be 1
        $trips[0].Status | Should -Be "unpaired"
        $trips[0].Notes  | Should -Be "no partner found"
    }

    It "returns an empty array for an empty entry list" {
        $trips = Get-TripPairings -Entries @() -LocationMap $script:locationMap
        @($trips).Count | Should -Be 0
    }
}

# ---------------------------------------------------------------------------
Describe "Get-TripPairings - deduplication" {

    It "removes a duplicate entry within the window and still pairs correctly" {
        # file2 is a dup of file1 (60s gap, same loc+odom, within 120s window)
        $entries = @(
            (New-Entry "file1.jpg" ([datetime]"2026-03-01 08:00:00") "Home" 47800),
            (New-Entry "file2.jpg" ([datetime]"2026-03-01 08:01:00") "Home" 47800),
            (New-Entry "file3.jpg" ([datetime]"2026-03-01 09:45:00") "Work" 47910)
        )
        $trips = Get-TripPairings -Entries $entries -LocationMap $script:locationMap `
            -DuplicateWindowSeconds 120
        # After dedup: [file1, file3] -> trip + trailing unpaired
        $trips.Count              | Should -Be 2
        $trips[0].OriginFile      | Should -Be "file1.jpg"
        $trips[0].DestinationFile | Should -Be "file3.jpg"
    }

    It "keeps an entry that falls outside the dedup window" {
        # file2 is 200s after file1 (> 120s window) -- should NOT be removed
        # same loc+odom but gap too large, so it becomes a same-location stop row
        $entries = @(
            (New-Entry "file1.jpg" ([datetime]"2026-03-01 08:00:00") "Home" 47800),
            (New-Entry "file2.jpg" ([datetime]"2026-03-01 08:03:20") "Home" 47800),
            (New-Entry "file3.jpg" ([datetime]"2026-03-01 09:45:00") "Work" 47910)
        )
        $trips = Get-TripPairings -Entries $entries -LocationMap $script:locationMap `
            -DuplicateWindowSeconds 120
        # file1 and file2 are same-location (stop row emitted), then file3 is a trip from file2
        $trips.Count | Should -BeGreaterThan 1
    }
}

# ---------------------------------------------------------------------------
Describe "Get-TripPairings - output columns" {

    It "produces all 14 expected column names on a trip row" {
        $entries = @(
            (New-Entry "a.jpg" ([datetime]"2026-03-01 08:00:00") "Home" 47800),
            (New-Entry "b.jpg" ([datetime]"2026-03-01 09:45:00") "Work" 47910)
        )
        $trip  = (Get-TripPairings -Entries $entries -LocationMap $script:locationMap)[0]
        $props = $trip.PSObject.Properties.Name
        $expectedCols = @(
            "Date", "DepartureTime", "ArrivalTime", "Origin", "Destination",
            "OdometerStart", "OdometerEnd", "Distance", "ExpectedMiles",
            "MatchConfidence", "Status", "Notes", "OriginFile", "DestinationFile"
        )
        foreach ($col in $expectedCols) {
            $props | Should -Contain $col
        }
    }

    It "sets Date to the departure date in M/d/yyyy format" {
        $entries = @(
            (New-Entry "a.jpg" ([datetime]"2026-03-01 08:00:00") "Home" 47800),
            (New-Entry "b.jpg" ([datetime]"2026-03-01 09:45:00") "Work" 47910)
        )
        $trip = (Get-TripPairings -Entries $entries -LocationMap $script:locationMap)[0]
        $trip.Date | Should -Be "3/1/2026"
    }

    It "sets DepartureTime and ArrivalTime in HH:mm format" {
        $entries = @(
            (New-Entry "a.jpg" ([datetime]"2026-03-01 08:05:00") "Home" 47800),
            (New-Entry "b.jpg" ([datetime]"2026-03-01 09:45:00") "Work" 47910)
        )
        $trip = (Get-TripPairings -Entries $entries -LocationMap $script:locationMap)[0]
        $trip.DepartureTime | Should -Be "08:05"
        $trip.ArrivalTime   | Should -Be "09:45"
    }
}
