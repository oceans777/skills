$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Tests = Get-ChildItem -LiteralPath $ScriptDir -Filter 'test-*.ps1' -File | Sort-Object Name

foreach ($Test in $Tests) {
    Write-Host "[TEST] $($Test.Name)"
    & $Test.FullName
    if (-not $?) {
        throw "$($Test.Name) failed."
    }
}

Write-Host 'All PowerShell tests passed.'
exit 0
