$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir 'directory-transaction.ps1')
$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("oceans-directory-transaction-test-" + [Guid]::NewGuid().ToString('N'))

try {
  $Target = Join-Path $TestRoot 'managed-skill'
  New-Item -ItemType Directory -Force -Path $Target | Out-Null
  Set-Content -LiteralPath (Join-Path $Target 'version') -Value 'old' -Encoding UTF8

  $Staged = New-OceansStagingDirectory -TargetPath $Target
  Set-Content -LiteralPath (Join-Path $Staged 'version') -Value 'new' -Encoding UTF8
  Complete-OceansDirectoryTransaction -StagingPath $Staged -TargetPath $Target
  if ((Get-Content -LiteralPath (Join-Path $Target 'version') -Raw).Trim() -ne 'new') {
    throw 'Directory transaction did not activate staged content.'
  }

  $RecoveryTarget = Join-Path $TestRoot 'recovery-skill'
  $RecoveryBackup = Join-Path $TestRoot '.recovery-skill.oceans-backup'
  New-Item -ItemType Directory -Path $RecoveryBackup | Out-Null
  Set-Content -LiteralPath (Join-Path $RecoveryBackup 'version') -Value 'recoverable' -Encoding UTF8
  $Staged = New-OceansStagingDirectory -TargetPath $RecoveryTarget
  Set-Content -LiteralPath (Join-Path $Staged 'version') -Value 'recovered-update' -Encoding UTF8
  Complete-OceansDirectoryTransaction -StagingPath $Staged -TargetPath $RecoveryTarget
  if ((Get-Content -LiteralPath (Join-Path $RecoveryTarget 'version') -Raw).Trim() -ne 'recovered-update') {
    throw 'Directory transaction did not recover an interrupted backup.'
  }

  $FilterRoot = Join-Path $TestRoot 'filter-root'
  New-Item -ItemType Directory -Force -Path (Join-Path $FilterRoot 'node_modules\pkg') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $FilterRoot 'kept') | Out-Null
  Set-Content -LiteralPath (Join-Path $FilterRoot 'node_modules\pkg\file') -Value 'remove' -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $FilterRoot 'kept\file') -Value 'keep' -Encoding UTF8
  Remove-OceansExcludedPaths -RootPath $FilterRoot
  if (Test-Path -LiteralPath (Join-Path $FilterRoot 'node_modules')) { throw 'Excluded directory was copied.' }
  if (-not (Test-Path -LiteralPath (Join-Path $FilterRoot 'kept\file'))) { throw 'Included file was removed.' }

  Write-Host 'PowerShell directory transaction tests passed.'
} finally {
  if (Test-Path -LiteralPath $TestRoot) {
    Remove-Item -LiteralPath $TestRoot -Recurse -Force
  }
}
