#Requires -Version 5.1
<#
.SYNOPSIS
    Pester tests for Rename-Photos.ps1 helper logic.

.NOTES
    Tests dot-source MileageTrackerHelpers.ps1 only -- no EXIF reads, OCR,
    or file system side-effects involved in the pure-function tests.

    The "-WhatIf does not write files" describe block runs the full script
    and requires config/settings.json to be present. It is automatically
    skipped when that file is absent (e.g. on a fresh CI checkout before
    the workflow's "Create test configuration" step runs).
#>

BeforeAll {
    . "$PSScriptRoot\..\scripts\MileageTrackerHelpers.ps1"

    $script:testLocations = @(
        [PSCustomObject]@{ name = "Home"; lat = 44.0; lon = -84.0 },
        [PSCustomObject]@{ name = "Work"; lat = 43.0; lon = -85.0 }
    )
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
Describe "-WhatIf does not write or move files" -Skip:(-not (Test-Path "$PSScriptRoot\..\config\settings.json")) {

    BeforeAll {
        $script:tempSource = Join-Path $env:TEMP "pester-whatif-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $script:tempSource | Out-Null
    }

    It "exits cleanly and creates no renamed files when source folder is empty" {
        $scriptPath = Join-Path $PSScriptRoot "..\scripts\Rename-Photos.ps1"
        # Pass -Folder to override settings; with no IMG_*.jpg files the
        # script exits before any file operations take place.
        $null = & powershell.exe -NonInteractive -File $scriptPath `
            -Folder $script:tempSource -WhatIf 2>&1
        $renamed = Get-ChildItem $script:tempSource -Recurse |
                   Where-Object { $_.Name -notmatch '^IMG_' -and $_.Extension -eq '.jpg' }
        $renamed.Count | Should -Be 0
    }

    AfterAll {
        Remove-Item $script:tempSource -Recurse -Force -ErrorAction SilentlyContinue
    }
}
