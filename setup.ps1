$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $RepoRoot

function Invoke-Git {
  & git @args
  if ($LASTEXITCODE -ne 0) {
    throw "git $($args -join ' ') failed with exit code $LASTEXITCODE."
  }
}

Write-Host "Setting up oceans777 skills..."

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  throw "Git is required but was not found in PATH."
}

Write-Host "Initializing child repositories..."
Invoke-Git submodule update --init --recursive

& "$RepoRoot\scripts\validate-skills.ps1"
& "$RepoRoot\scripts\install-skills.ps1"

Write-Host ""
Write-Host "Setup complete."
Write-Host "Next commands:"
Write-Host "  .\oceans.ps1 sync"
Write-Host "  .\oceans.ps1 status"
