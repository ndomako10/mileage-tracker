# Pester 5 configuration for the mileage-tracker test suite.
# Run from the repo root:
#   Invoke-Pester -Configuration (& .\pester.config.ps1)
$config = New-PesterConfiguration
$config.Run.Path                = "./tests"
$config.Run.Exit                = $true
$config.Output.Verbosity        = "Detailed"
$config.TestResult.Enabled      = $true
$config.TestResult.OutputFormat = "NUnitXml"
$config.TestResult.OutputPath   = "./test-results/pester-results.xml"
return $config
