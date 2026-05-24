param(
  [string] $FirstPartySkillsRoot,
  [string] $CommunitySkillsRoot
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptRoot "skill-publish-rules.ps1")
$Failures = New-Object System.Collections.Generic.List[string]

if (-not $FirstPartySkillsRoot) {
  $FirstPartySkillsRoot = Join-Path $RepoRoot "repos\oceans-skills\skills"
}

if (-not $CommunitySkillsRoot) {
  $CommunitySkillsRoot = Join-Path $RepoRoot "repos\community-skills\skills"
}

function Test-SkillDirectory {
  param(
    [string] $RepositoryName,
    [string] $SkillsPath,
    [bool] $RequireUpstream
  )

  if (-not (Test-Path -LiteralPath $SkillsPath)) {
    $Failures.Add("Missing skills path: $SkillsPath")
    return
  }

  Get-ChildItem -LiteralPath $SkillsPath -Directory | ForEach-Object {
    if ($_.Name -notmatch '^[a-z0-9-]+$') {
      $Failures.Add("Invalid skill folder name in ${RepositoryName}: $($_.Name)")
    }

    $IsSkillReparsePoint = (($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
    if ($IsSkillReparsePoint) {
      $Failures.Add("Unsupported symlink in ${RepositoryName}: $($_.Name)")
    }

    if (-not $IsSkillReparsePoint) {
      Get-ChildItem -LiteralPath $_.FullName -Force -Recurse -ErrorAction SilentlyContinue |
        Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 } |
        ForEach-Object {
          $Failures.Add("Unsupported symlink in ${RepositoryName}: $($_.FullName)")
        }
    }

    if (-not (Test-Path -LiteralPath (Join-Path $_.FullName "SKILL.md") -PathType Leaf)) {
      $Failures.Add("Missing SKILL.md in ${RepositoryName}: $($_.Name)")
    } elseif (Test-OceansMissingLicenseReference -SkillPath $_.FullName) {
      $Failures.Add("Missing referenced license file in ${RepositoryName}: $($_.Name)")
    }

    if ($RequireUpstream) {
      foreach ($Required in @("UPSTREAM.md", "PATCHES.md", "LICENSE")) {
        $RequiredPath = Join-Path $_.FullName $Required
        $RequiredContent = ""
        if (Test-Path -LiteralPath $RequiredPath -PathType Leaf) {
          $RequiredContent = [string](Get-Content -LiteralPath $RequiredPath -Raw)
        }
        if (-not (Test-Path -LiteralPath $RequiredPath -PathType Leaf) -or
            $RequiredContent.Trim().Length -eq 0) {
          $Failures.Add("Missing or empty $Required in ${RepositoryName}: $($_.Name)")
        }
      }
    }
  }
}

function Get-SkillNames {
  param([string] $SkillsPath)

  if (-not (Test-Path -LiteralPath $SkillsPath)) {
    return @()
  }

  return @(Get-ChildItem -LiteralPath $SkillsPath -Directory | ForEach-Object { $_.Name })
}

Test-SkillDirectory `
  -RepositoryName "oceans-skills" `
  -SkillsPath $FirstPartySkillsRoot `
  -RequireUpstream $false

Test-SkillDirectory `
  -RepositoryName "community-skills" `
  -SkillsPath $CommunitySkillsRoot `
  -RequireUpstream $true

$FirstPartyNames = Get-SkillNames -SkillsPath $FirstPartySkillsRoot
$CommunityNames = Get-SkillNames -SkillsPath $CommunitySkillsRoot
foreach ($Name in $FirstPartyNames) {
  if ($CommunityNames -contains $Name) {
    $Failures.Add("Duplicate skill name across repositories: $Name")
  }
}

if ($Failures.Count -gt 0) {
  $Failures | ForEach-Object { Write-Output "ERROR: $_" }
  throw "Validation failed with $($Failures.Count) issue(s)."
}

Write-Host "Validation passed."
