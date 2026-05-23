$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $RepoRoot

if ($env:CODEX_HOME) {
  $InstallRoot = Join-Path $env:CODEX_HOME "skills"
} else {
  $InstallRoot = Join-Path $HOME ".codex\skills"
}

Write-Host "Repository:"
git status --short --branch

Write-Host ""
Write-Host "Submodules:"
git submodule status

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
