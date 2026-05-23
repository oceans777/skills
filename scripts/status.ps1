$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $RepoRoot

function Invoke-Git {
  & git @args
  if ($LASTEXITCODE -ne 0) {
    throw "git $($args -join ' ') failed with exit code $LASTEXITCODE."
  }
}

if ($env:CODEX_HOME) {
  $InstallRoot = Join-Path $env:CODEX_HOME "skills"
} else {
  $InstallRoot = Join-Path $HOME ".codex\skills"
}

Write-Host "Repository:"
Invoke-Git status --short --branch

Write-Host ""
Write-Host "Child repositories:"
Invoke-Git submodule status

Write-Host ""
Write-Host "Install root:"
Write-Host "  $InstallRoot"

if (Test-Path $InstallRoot) {
  $ManagedCount = (Get-ChildItem -Path $InstallRoot -Directory | Where-Object {
    Test-Path (Join-Path $_.FullName ".oceans-skill-source")
  }).Count
  Write-Host "Managed oceans777 skills: $ManagedCount"
} else {
  Write-Host "Install root does not exist yet."
}
