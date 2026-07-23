$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Tests = @(Get-Item -LiteralPath (Join-Path $ScriptDir 'test-add-skill-from-url.ps1'))

foreach ($Test in $Tests) {
    Write-Host "[TEST] $($Test.Name)"
    & $Test.FullName
    if (-not $?) {
        throw "$($Test.Name) failed."
    }
}

Write-Host 'Selected PowerShell tests passed.'
exit 0
