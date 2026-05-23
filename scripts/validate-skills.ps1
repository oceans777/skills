$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Failures = New-Object System.Collections.Generic.List[string]

function Test-SkillDirectory {
  param(
    [string] $RepositoryName,
    [string] $SkillsPath,
    [bool] $RequireUpstream
  )

  if (-not (Test-Path $SkillsPath)) {
    $Failures.Add("Missing skills path: $SkillsPath")
    return
  }

  Get-ChildItem -Path $SkillsPath -Directory | ForEach-Object {
    if ($_.Name -notmatch '^[a-z0-9-]+$') {
      $Failures.Add("Invalid skill folder name in ${RepositoryName}: $($_.Name)")
    }

    if (-not (Test-Path (Join-Path $_.FullName "SKILL.md"))) {
      $Failures.Add("Missing SKILL.md in ${RepositoryName}: $($_.Name)")
    }

    if ($RequireUpstream) {
      foreach ($Required in @("UPSTREAM.md", "PATCHES.md", "LICENSE")) {
        if (-not (Test-Path (Join-Path $_.FullName $Required))) {
          $Failures.Add("Missing $Required in ${RepositoryName}: $($_.Name)")
        }
      }
    }
  }
}

Test-SkillDirectory `
  -RepositoryName "oceans-skills" `
  -SkillsPath (Join-Path $RepoRoot "repos\oceans-skills\skills") `
  -RequireUpstream $false

Test-SkillDirectory `
  -RepositoryName "community-skills" `
  -SkillsPath (Join-Path $RepoRoot "repos\community-skills\skills") `
  -RequireUpstream $true

if ($Failures.Count -gt 0) {
  $Failures | ForEach-Object { Write-Error $_ }
  throw "Validation failed with $($Failures.Count) issue(s)."
}

Write-Host "Validation passed."
