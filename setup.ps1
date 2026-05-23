$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $RepoRoot
. "$RepoRoot\scripts\common.ps1"

Write-Host "Setting up oceans777 skills..."

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  throw "Git is required but was not found in PATH."
}

Write-Host "Initializing child repositories..."
Invoke-GitWithRetry -Description "Initialize child repositories" -Arguments @("submodule", "update", "--init", "--recursive") -Attempts 3 -DelaySeconds 5

& "$RepoRoot\scripts\validate-skills.ps1"
& "$RepoRoot\scripts\install-skills.ps1"

Write-Host ""
Write-Host "Setup complete."
Write-Host "Next commands:"
Write-Host "  .\oceans.ps1 sync"
Write-Host "  .\oceans.ps1 status"
