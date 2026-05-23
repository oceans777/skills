param(
  [Parameter(Position = 0)]
  [ValidateSet("sync", "install", "validate", "status", "help")]
  [string] $Command = "help"
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

switch ($Command) {
  "sync" {
    & "$RepoRoot\scripts\sync.ps1"
  }
  "install" {
    & "$RepoRoot\scripts\install-skills.ps1"
  }
  "validate" {
    & "$RepoRoot\scripts\validate-skills.ps1"
  }
  "status" {
    & "$RepoRoot\scripts\status.ps1"
  }
  "help" {
    Write-Host "oceans777 skills commands:"
    Write-Host "  .\oceans.ps1 sync      Pull updates and check out pinned child repositories"
    Write-Host "  .\oceans.ps1 install   Install skills locally"
    Write-Host "  .\oceans.ps1 validate  Validate repository and skill structure"
    Write-Host "  .\oceans.ps1 status    Show repository and install status"
  }
}
