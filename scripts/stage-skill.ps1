param(
  [string] $SourceRoot,
  [ValidateSet("codex", "agents", "claude", "openclaw", "hermes", "custom")]
  [string] $Runtime = "codex",
  [Parameter(Mandatory = $true)] [string] $Skill,
  [Parameter(Mandatory = $true)] [ValidateSet("oceans", "community")] [string] $Target,
  [string] $FirstPartySkillsRoot,
  [string] $CommunitySkillsRoot,
  [switch] $AllowRisk,
  [switch] $ReplaceExisting,
  [switch] $DryRun,
  [string] $UpstreamUrl,
  [string] $UpstreamAuthor,
  [string] $UpstreamLicense,
  [string] $LicenseFile,
  [string] $PatchSummary
)

$ErrorActionPreference = "Stop"

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptRoot
$RequestedSourceRoot = $SourceRoot
$RequestedRuntime = $Runtime
. (Join-Path $ScriptRoot "skill-roots.ps1") -DefineOnly
. (Join-Path $ScriptRoot "skill-publish-rules.ps1")
$SourceRoot = $RequestedSourceRoot
$Runtime = $RequestedRuntime

function Resolve-DefaultSourceRoot {
  if ($SourceRoot) {
    return $SourceRoot
  }

  return (Get-OceansRuntimeRoot -Runtime $Runtime -Operation "stage").Path
}

function Resolve-AbsolutePath {
  param([Parameter(Mandatory = $true)][string] $Path)

  if (Test-Path -LiteralPath $Path) {
    return [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).Path)
  }

  return [System.IO.Path]::GetFullPath($Path)
}

function Assert-PathInsideRoot {
  param(
    [Parameter(Mandatory = $true)][string] $Path,
    [Parameter(Mandatory = $true)][string] $Root
  )

  $ResolvedPath = Resolve-AbsolutePath -Path $Path
  $ResolvedRoot = Resolve-AbsolutePath -Path $Root
  if (-not $ResolvedRoot.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
    $ResolvedRoot += [System.IO.Path]::DirectorySeparatorChar
  }

  if (-not $ResolvedPath.StartsWith($ResolvedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe target path outside skills root: $ResolvedPath"
  }
}

function Invoke-GitText {
  param(
    [Parameter(Mandatory = $true)][string] $Repo,
    [Parameter(Mandatory = $true)][string[]] $Arguments
  )

  $Output = & git -C $Repo @Arguments 2>$null
  if ($LASTEXITCODE -ne 0) {
    return $null
  }

  return ($Output | Out-String).Trim()
}

function Test-RepositoryOnMain {
  param(
    [Parameter(Mandatory = $true)][string] $Repo,
    [Parameter(Mandatory = $true)][string] $RepositoryName
  )

  $Branch = Invoke-GitText -Repo $Repo -Arguments @("rev-parse", "--abbrev-ref", "HEAD")
  if ($Branch -ne "main") {
    Write-Host "target-not-main: $RepositoryName"
    exit 1
  }
}

function Test-RepositoryDirtyOutsideSkills {
  param(
    [Parameter(Mandatory = $true)][string] $Repo,
    [Parameter(Mandatory = $true)][string] $RepositoryName
  )

  $Status = & git -C $Repo status --porcelain
  if ($LASTEXITCODE -ne 0) {
    throw "git status failed for $Repo"
  }

  foreach ($Line in $Status) {
    if (-not $Line) {
      continue
    }

    $PathText = $Line.Substring([Math]::Min(3, $Line.Length)).Trim()
    $PathsToCheck = @($PathText)
    if ($PathText -like "* -> *") {
      $PathsToCheck = $PathText -split " -> "
    }

    foreach ($PathToCheck in $PathsToCheck) {
      $PathToCheck = $PathToCheck.Trim('"')
      if ($PathToCheck -notlike "skills/*" -and $PathToCheck -notlike "skills\*") {
        Write-Host "target-dirty-outside-skills: $RepositoryName"
        exit 1
      }
    }
  }
}

function Test-ReparsePoint {
  param([Parameter(Mandatory = $true)] $Item)

  return (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Get-UnsupportedLinkPaths {
  param([Parameter(Mandatory = $true)][string] $SkillPath)

  $Unsupported = New-Object System.Collections.Generic.List[string]
  $SourceAbs = Resolve-AbsolutePath -Path $SkillPath

  $Items = Get-ChildItem -LiteralPath $SourceAbs -Force -Recurse -ErrorAction SilentlyContinue
  foreach ($Item in $Items) {
    if (-not (Test-ReparsePoint -Item $Item)) {
      continue
    }

    $RelativePath = $Item.FullName.Substring($SourceAbs.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    if (Test-OceansExcludedRelativePath -RelativePath $RelativePath) {
      continue
    }

    $Unsupported.Add($RelativePath)
  }

  return $Unsupported
}

function Test-NonEmptyFile {
  param([Parameter(Mandatory = $true)][string] $Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $false
  }

  return ((Get-Content -LiteralPath $Path -Raw).Trim().Length -gt 0)
}

function Test-CommunityAttribution {
  param([Parameter(Mandatory = $true)][string] $SkillPath)

  $NeedsUpstream = -not (Test-NonEmptyFile -Path (Join-Path $SkillPath "UPSTREAM.md"))
  $NeedsLicense = -not (Test-NonEmptyFile -Path (Join-Path $SkillPath "LICENSE"))

  if ($NeedsUpstream -and
      ([string]::IsNullOrWhiteSpace($UpstreamUrl) -or
       [string]::IsNullOrWhiteSpace($UpstreamAuthor) -or
       [string]::IsNullOrWhiteSpace($UpstreamLicense))) {
    return $false
  }

  if ($NeedsLicense -and
      ([string]::IsNullOrWhiteSpace($LicenseFile) -or
       -not (Test-Path -LiteralPath $LicenseFile -PathType Leaf))) {
    return $false
  }

  return $true
}

function Copy-SkillDirectory {
  param(
    [Parameter(Mandatory = $true)][string] $From,
    [Parameter(Mandatory = $true)][string] $To
  )

  $FromAbs = Resolve-AbsolutePath -Path $From
  New-Item -ItemType Directory -Force -Path $To | Out-Null

  $Items = Get-ChildItem -LiteralPath $FromAbs -Force -Recurse
  foreach ($Item in $Items) {
    $RelativePath = $Item.FullName.Substring($FromAbs.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    if (Test-OceansExcludedRelativePath -RelativePath $RelativePath) {
      continue
    }

    if (Test-ReparsePoint -Item $Item) {
      throw "Unsupported symlink or reparse point in skill: $RelativePath"
    }

    $Destination = Join-Path $To $RelativePath
    if ($Item.PSIsContainer) {
      New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    } else {
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
      Copy-Item -LiteralPath $Item.FullName -Destination $Destination -Force
    }
  }
}

function Write-CommunityAttribution {
  param([Parameter(Mandatory = $true)][string] $TargetPath)

  $UpstreamPath = Join-Path $TargetPath "UPSTREAM.md"
  $PatchesPath = Join-Path $TargetPath "PATCHES.md"
  $LicensePath = Join-Path $TargetPath "LICENSE"

  if (-not (Test-NonEmptyFile -Path $UpstreamPath)) {
    $UpstreamContent = @(
      "# Upstream",
      "",
      "Original repository: $UpstreamUrl",
      "Original author: $UpstreamAuthor",
      "License: $UpstreamLicense",
      "Imported by: oceans777"
    ) -join [Environment]::NewLine
    Set-Content -LiteralPath $UpstreamPath -Value $UpstreamContent -Encoding UTF8
  }

  if (-not (Test-NonEmptyFile -Path $PatchesPath)) {
    if ([string]::IsNullOrWhiteSpace($PatchSummary)) {
      $PatchContent = "# Patches" + [Environment]::NewLine + [Environment]::NewLine + "No local changes."
    } else {
      $PatchContent = "# Patches" + [Environment]::NewLine + [Environment]::NewLine + $PatchSummary
    }
    Set-Content -LiteralPath $PatchesPath -Value $PatchContent -Encoding UTF8
  }

  if (-not (Test-NonEmptyFile -Path $LicensePath)) {
    Copy-Item -LiteralPath $LicenseFile -Destination $LicensePath -Force
  }
}

$SourceRoot = Resolve-DefaultSourceRoot
if (-not $FirstPartySkillsRoot) {
  $FirstPartySkillsRoot = Join-Path $RepoRoot "repos\oceans-skills\skills"
}
if (-not $CommunitySkillsRoot) {
  $CommunitySkillsRoot = Join-Path $RepoRoot "repos\community-skills\skills"
}

if ($Skill -eq ".system") {
  Write-Host "skip-system: .system"
  exit 1
}

if (-not (Test-OceansSkillName -Name $Skill)) {
  Write-Host "invalid-skill-name: $Skill"
  exit 1
}

$TargetSkillsRoot = if ($Target -eq "oceans") { $FirstPartySkillsRoot } else { $CommunitySkillsRoot }
$OtherSkillsRoot = if ($Target -eq "oceans") { $CommunitySkillsRoot } else { $FirstPartySkillsRoot }
$TargetRepository = if ($Target -eq "oceans") { "oceans-skills" } else { "community-skills" }
$TargetRepoPath = Split-Path -Parent $TargetSkillsRoot

Test-RepositoryOnMain -Repo $TargetRepoPath -RepositoryName $TargetRepository
Test-RepositoryDirtyOutsideSkills -Repo $TargetRepoPath -RepositoryName $TargetRepository

$SourceSkillPath = Join-Path $SourceRoot $Skill
if (-not (Test-Path -LiteralPath $SourceSkillPath -PathType Container)) {
  Write-Host "missing-source-skill: $SourceSkillPath"
  exit 1
}

$SourceSkillPath = Resolve-AbsolutePath -Path $SourceSkillPath
if (-not (Test-Path -LiteralPath (Join-Path $SourceSkillPath "SKILL.md") -PathType Leaf)) {
  Write-Host "missing-skill-md: $Skill"
  exit 1
}

$MetadataIssues = @(Get-OceansSkillMetadataIssues -SkillPath $SourceSkillPath -ExpectedName $Skill)
if ($MetadataIssues.Count -gt 0) {
  Write-Host "invalid-skill-metadata: $Skill"
  foreach ($Issue in $MetadataIssues) {
    Write-Host $Issue
  }
  Write-Host "risk_status: blocked"
  exit 1
}

$UnsupportedLinks = @(Get-UnsupportedLinkPaths -SkillPath $SourceSkillPath)
if ($UnsupportedLinks.Count -gt 0) {
  Write-Host "unsupported-symlink: $Skill"
  foreach ($UnsupportedLink in $UnsupportedLinks) {
    Write-Host "unsupported-symlink-path: $UnsupportedLink"
  }
  exit 1
}

$Risks = @(Get-OceansSkillRiskNotes -SkillPath $SourceSkillPath)
if ($Risks.Count -gt 0 -and -not $AllowRisk) {
  Write-Host "risk-blocked: $Skill"
  foreach ($Risk in $Risks) {
    Write-Host $Risk
  }
  Write-Host "risk_status: blocked"
  exit 1
}

if ($Target -eq "community" -and -not (Test-CommunityAttribution -SkillPath $SourceSkillPath)) {
  Write-Host "missing-community-attribution: $Skill"
  exit 1
}

$TargetPath = Join-Path $TargetSkillsRoot $Skill
$OtherPath = Join-Path $OtherSkillsRoot $Skill
if (Test-Path -LiteralPath $OtherPath -PathType Container) {
  Write-Host "duplicate-cross-repository: $Skill"
  exit 1
}

if ((Test-Path -LiteralPath $TargetPath -PathType Container) -and -not $ReplaceExisting) {
  Write-Host "duplicate-existing-target: $Skill"
  exit 1
}

Assert-PathInsideRoot -Path $TargetPath -Root $TargetSkillsRoot

$RiskStatus = if ($Risks.Count -eq 0) { "none detected" } else { "allowed" }

if ($DryRun) {
  Write-Host "staged-skill: $Skill"
  Write-Host "target_repository: $TargetRepository"
  Write-Host "target_path: $TargetPath"
  Write-Host "risk_status: $RiskStatus"
  Write-Host "dry_run: true"
  Write-Host "next: run validate, then publish"
  exit 0
}

if (Test-Path -LiteralPath $TargetPath -PathType Container) {
  Assert-PathInsideRoot -Path $TargetPath -Root $TargetSkillsRoot
  Remove-Item -LiteralPath (Resolve-AbsolutePath -Path $TargetPath) -Recurse -Force
}

Copy-SkillDirectory -From $SourceSkillPath -To $TargetPath

if ($Target -eq "community") {
  Write-CommunityAttribution -TargetPath $TargetPath
}

Write-Host "staged-skill: $Skill"
Write-Host "target_repository: $TargetRepository"
Write-Host "target_path: $TargetPath"
Write-Host "risk_status: $RiskStatus"
Write-Host "dry_run: false"
Write-Host "next: run validate, then publish"
