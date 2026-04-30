#Requires -Version 5.1
<#
.SYNOPSIS
    Pester tests for Rename-Photos.ps1 helper logic.

.NOTES
    Tests dot-source MileageTrackerHelpers.ps1 and Rename-Photos.ps1 (functions
    only — the main body is guarded by an InvocationName check). No EXIF reads,
    OCR, or file system side-effects are involved in the pure-function tests.

    The "-WhatIf does not write files" describe block runs the full script
    and requires config/settings.json to be present. It is automatically
    skipped when that file is absent (e.g. on a fresh CI checkout before
    the workflow's "Create test configuration" step runs).
#>

BeforeAll {
    . "$PSScriptRoot\..\scripts\MileageTrackerHelpers.ps1"
    . "$PSScriptRoot\..\scripts\Rename-Photos.ps1"

    $script:testLocations = @(
        [PSCustomObject]@{ name = "Home"; lat = 44.0; lon = -84.0 },
        [PSCustomObject]@{ name = "Work"; lat = 43.0; lon = -85.0 }
    )
    $script:locationMap = Get-LocationMap $script:testLocations

    # Build a minimal photo context suitable for Test-OdometerReading.
    # Callers only need to supply the fields the function actually reads.
    function New-TestPhoto {
        param(
            [string]   $Reading,
            [string]   $Confidence = 'ok',
            [string[]] $Digits     = @($Reading),
            [datetime] $DateTime   = [datetime]::Now,
            [string]   $Location   = $null
        )
        return [pscustomobject]@{
            File     = [pscustomobject]@{ Name = 'test.jpg' }
            Exif     = @{ DateTime = $DateTime }
            OCR      = [pscustomobject]@{
                Reading    = $Reading
                Confidence = $Confidence
                RawText    = $null
                Digits     = $Digits
                Error      = $null
            }
            Location = $Location
            Status   = 'Pending'
            Error    = $null
        }
    }
}

# ---------------------------------------------------------------------------
Describe "Get-HaversineDistance" {

    It "returns 0 for identical points" {
        $d = Get-HaversineDistance 44.0 -84.0 44.0 -84.0
        $d | Should -Be 0.0
    }

    It "returns a plausible straight-line distance for Home -> Work (~85 mi)" {
        $d = Get-HaversineDistance 44.0 -84.0 43.0 -85.0
        $d | Should -BeGreaterThan 80
        $d | Should -BeLessThan 95
    }
}

# ---------------------------------------------------------------------------
Describe "Get-NearestLocation" {

    It "returns the correct location for a coordinate within threshold" {
        # 0.001 degrees away from Home -- well within 1.0 mile
        $result = Get-NearestLocation -Lat 44.001 -Lon -84.0 `
            -Locations $script:testLocations -ThresholdMiles 1.0
        $result | Should -Not -BeNullOrEmpty
        $result.name | Should -Be "Home"
    }

    It "returns null when the nearest location exceeds the threshold" {
        # Far from both known locations
        $result = Get-NearestLocation -Lat 40.0 -Lon -80.0 `
            -Locations $script:testLocations -ThresholdMiles 1.0
        $result | Should -BeNullOrEmpty
    }

    It "returns the nearest location when multiple candidates exist" {
        $result = Get-NearestLocation -Lat 43.001 -Lon -85.001 `
            -Locations $script:testLocations -ThresholdMiles 5.0
        $result.name | Should -Be "Work"
    }
}

# ---------------------------------------------------------------------------
Describe "New filename string construction" {

    It "produces the expected filename from date, location, and odometer" {
        $datePart     = "260301-1432"
        $locationName = "Home"
        $ocrReading   = "47823"
        $result       = "$datePart $locationName $ocrReading.jpg"
        $result | Should -Be "260301-1432 Home 47823.jpg"
    }

    It "pads a short odometer reading to 5 digits" {
        $datePart     = "260301-1432"
        $locationName = "Work"
        $ocrReading   = "823".PadLeft(5, '0')
        $result       = "$datePart $locationName $ocrReading.jpg"
        $result | Should -Be "260301-1432 Work 00823.jpg"
    }

    It "does not alter an already 5-digit odometer reading" {
        $ocrReading = "47823".PadLeft(5, '0')
        $ocrReading | Should -Be "47823"
    }
}

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
Describe "Test-OdometerReading - decreased-reading recovery" {

    BeforeAll {
        # Shared params — use $script: so they are visible inside It blocks
        $script:maxSpeedMph  = 80
        $script:roadFactor   = 1.25
        $script:tolerancePct = 0.20
    }

    It "skips when reading decreased and no LastGoodDateTime is available" {
        $photo  = New-TestPhoto -Reading "2228" -Digits @("2228")
        $result = Test-OdometerReading -Photo $photo `
            -LastOdometer 222841 -LastGoodDateTime $null -LastGoodLocation $null `
            -LocationMap $script:locationMap -MaxSpeedMph $script:maxSpeedMph
        $result            | Should -BeFalse
        $photo.OCR.Confidence | Should -Be "suspect"
        $photo.Error       | Should -Match "no time reference"
    }

    It "recovers via concatenation when OCR splits the number into groups" {
        # OCR read "2228" + "41" separately; true value is 222841
        $t0    = [datetime]::Now.AddHours(-1)
        $photo = New-TestPhoto -Reading "2228" -Digits @("2228", "41") -DateTime ([datetime]::Now)
        $result = Test-OdometerReading -Photo $photo `
            -LastOdometer 222841 -LastGoodDateTime $t0 -LastGoodLocation $null `
            -LocationMap $script:locationMap -MaxSpeedMph $script:maxSpeedMph `
            -RoadFactor $script:roadFactor -TolerancePct $script:tolerancePct
        $result               | Should -BeTrue
        $photo.OCR.Reading    | Should -Be "222841"
        $photo.OCR.Confidence | Should -Be "recovered"
    }

    It "recovers via suffix when OCR drops leading digits" {
        # OCR read "2841"; true value is 22841 (leading "2" dropped)
        $t0    = [datetime]::Now.AddHours(-1)
        $photo = New-TestPhoto -Reading "2841" -Digits @("2841") -DateTime ([datetime]::Now)
        $result = Test-OdometerReading -Photo $photo `
            -LastOdometer 22841 -LastGoodDateTime $t0 -LastGoodLocation $null `
            -LocationMap $script:locationMap -MaxSpeedMph $script:maxSpeedMph `
            -RoadFactor $script:roadFactor -TolerancePct $script:tolerancePct
        $result               | Should -BeTrue
        $photo.OCR.Reading    | Should -Be "22841"
        $photo.OCR.Confidence | Should -Be "recovered"
    }

    It "recovers via prefix when the time window contains exactly one matching value" {
        # lastOdom = maxAllowable (elapsed ~0s): only one prefix candidate exists
        $t0    = [datetime]::Now
        $photo = New-TestPhoto -Reading "999" -Digits @("999") -DateTime $t0
        $result = Test-OdometerReading -Photo $photo `
            -LastOdometer 99900 -LastGoodDateTime $t0 -LastGoodLocation $null `
            -LocationMap $script:locationMap -MaxSpeedMph $script:maxSpeedMph `
            -RoadFactor $script:roadFactor -TolerancePct $script:tolerancePct
        $result               | Should -BeTrue
        $photo.OCR.Reading    | Should -Be "99900"
        $photo.OCR.Confidence | Should -Be "recovered"
    }

    It "recovers via prefix+location when distance estimate narrows candidates to one" {
        # OCR read "100" (prefix of 10050); expected road distance is mocked to 50 miles.
        # TolerancePct = 0.01 means ±0.5 miles, so only 10050 survives the filter.
        Mock Get-ExpectedDistance { return 50.0 }
        $t0    = [datetime]::Now.AddHours(-1)
        $photo = New-TestPhoto -Reading "100" -Digits @("100") -DateTime ([datetime]::Now) -Location "Work"
        $result = Test-OdometerReading -Photo $photo `
            -LastOdometer 10000 -LastGoodDateTime $t0 -LastGoodLocation "Home" `
            -LocationMap $script:locationMap -MaxSpeedMph $script:maxSpeedMph `
            -RoadFactor $script:roadFactor -TolerancePct 0.01
        $result               | Should -BeTrue
        $photo.OCR.Reading    | Should -Be "10050"
        $photo.OCR.Confidence | Should -Be "recovered"
    }

    It "skips when all recovery passes produce ambiguous candidates" {
        # "100" prefix gives ~51 candidates in [10000,10050]; no location to narrow
        $t0    = [datetime]::Now.AddHours(-0.625)   # ceil(0.625*80)=50 -> max=10050
        $photo = New-TestPhoto -Reading "100" -Digits @("100") -DateTime ([datetime]::Now)
        $result = Test-OdometerReading -Photo $photo `
            -LastOdometer 10000 -LastGoodDateTime $t0 -LastGoodLocation $null `
            -LocationMap $script:locationMap -MaxSpeedMph $script:maxSpeedMph `
            -RoadFactor $script:roadFactor -TolerancePct $script:tolerancePct
        $result            | Should -BeFalse
        $photo.OCR.Confidence | Should -Be "suspect"
        $photo.Error       | Should -Match "recovery failed"
    }
}

# ---------------------------------------------------------------------------
Describe "-WhatIf does not write or move files" -Skip:(-not (Test-Path "$PSScriptRoot\..\config\settings.json")) {

    BeforeAll {
        $script:tempSource = Join-Path $env:TEMP "pester-whatif-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $script:tempSource | Out-Null
    }

    It "exits cleanly and creates no renamed files when source folder is empty" {
        $scriptPath = Join-Path $PSScriptRoot "..\scripts\Rename-Photos.ps1"
        # Pass -Source to override settings; with no IMG_*.jpeg files the
        # script exits before any file operations take place.
        $null = & powershell.exe -NonInteractive -File $scriptPath `
            -Source $script:tempSource -WhatIf 2>&1
        $renamed = @(Get-ChildItem $script:tempSource -Recurse |
                   Where-Object { $_.Name -notmatch '^IMG_' -and $_.Extension -eq '.jpg' })
        $renamed.Count | Should -Be 0
    }

    AfterAll {
        Remove-Item $script:tempSource -Recurse -Force -ErrorAction SilentlyContinue
    }
}
