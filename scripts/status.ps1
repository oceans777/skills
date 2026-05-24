param(
  [ValidateSet("codex", "agents", "claude", "openclaw", "hermes", "custom")]
  [string] $Runtime,

  [switch] $AllExistingRuntimes
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $RepoRoot
. "$RepoRoot\scripts\common.ps1"

$RequestedRuntime = $Runtime
$RequestedAllExistingRuntimes = $AllExistingRuntimes
. "$RepoRoot\scripts\skill-roots.ps1" -DefineOnly
$Runtime = $RequestedRuntime
$AllExistingRuntimes = $RequestedAllExistingRuntimes

function Get-ManagedSkillCount {
  param([Parameter(Mandatory = $true)][string] $RootPath)

  if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
    return $null
  }

  return (Get-ChildItem -LiteralPath $RootPath -Directory | Where-Object {
    Test-Path -LiteralPath (Join-Path $_.FullName ".oceans-skill-source")
  }).Count
}

function Write-StatusRoot {
  param([Parameter(Mandatory = $true)] $Root)

  Write-Host "  runtime: $($Root.Runtime)"
  Write-Host "  status: $($Root.Status)"
  Write-Host "  path: $($Root.Path)"
  Write-Host "  reason: $($Root.Reason)"

  $ManagedCount = Get-ManagedSkillCount -RootPath $Root.Path
  if ($null -eq $ManagedCount) {
    Write-Host "  managed_oceans_skills: not_available"
  } else {
    Write-Host "  managed_oceans_skills: $ManagedCount"
  }
}

if ($Runtime -and $AllExistingRuntimes) {
  throw "runtime-and-all-existing-runtimes-are-mutually-exclusive"
}

if ($Runtime -eq "custom") {
  throw "custom-runtime-requires-path"
}

if ($Runtime) {
  $StatusRoots = @(Get-OceansSkillRootCandidates | Where-Object { $_.Runtime -eq $Runtime })
} elseif ($AllExistingRuntimes) {
  $StatusRoots = @(Get-OceansExistingSkillRoots)
} else {
  $StatusRoots = @(Get-OceansSkillRootCandidates)
}

Write-Host "Repository:"
Invoke-Git -Description "Read repository status" -Arguments @("status", "--short", "--branch")

Write-Host ""
Write-Host "Child repositories:"
Invoke-Git -Description "Read child repository status" -Arguments @("submodule", "status")

Write-Host ""
Write-Host "Runtime skill roots:"
if ($StatusRoots.Count -eq 0) {
  Write-Host "  No existing runtime skill roots found."
} else {
  foreach ($Root in $StatusRoots) {
    Write-StatusRoot -Root $Root
    Write-Host ""
  }
}
