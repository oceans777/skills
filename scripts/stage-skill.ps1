param(
  [string] $SourceRoot,
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

$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$ExcludedNames = @(".git", ".oceans-skill-source", ".DS_Store", "Thumbs.db", ".pytest_cache", "__pycache__", "node_modules")

function Resolve-DefaultSourceRoot {
  if ($SourceRoot) {
    return $SourceRoot
  }

  if ($env:CODEX_HOME) {
    return (Join-Path $env:CODEX_HOME "skills")
  }

  return (Join-Path $HOME ".codex\skills")
}

function Test-SkillName {
  param([string] $Name)
  return ($Name -match '^[a-z0-9]+(-[a-z0-9]+)*$')
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
    if ($PathText -like "* -> *") {
      $PathText = ($PathText -split " -> ")[-1]
    }

    $PathText = $PathText.Trim('"')
    if ($PathText -notlike "skills/*" -and $PathText -notlike "skills\*") {
      Write-Host "target-dirty-outside-skills: $RepositoryName"
      exit 1
    }
  }
}

function Test-ExcludedRelativePath {
  param([Parameter(Mandatory = $true)][string] $RelativePath)

  foreach ($Part in ($RelativePath -split '[\\/]')) {
    if ($ExcludedNames -contains $Part) {
      return $true
    }
  }

  return $false
}

function Get-RiskNotes {
  param([Parameter(Mandatory = $true)][string] $SkillPath)

  $Risks = New-Object System.Collections.Generic.List[string]
  $SecretPattern = '(?i)(api[_-]?key\s*[:=]|secret\s*[:=]|token\s*[:=]|password\s*[:=]|authorization\s*:?\s*bearer|sk-[a-zA-Z0-9_-]{10,})'
  $LocalPathPattern = '(?i)(/Users/|/home/|[A-Z]:\\Users\\|[A-Z]:/Users/|/private/)'
  $SourceAbs = Resolve-AbsolutePath -Path $SkillPath

  $Files = Get-ChildItem -LiteralPath $SourceAbs -File -Recurse -Force -ErrorAction SilentlyContinue
  foreach ($File in $Files) {
    $RelativePath = $File.FullName.Substring($SourceAbs.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    if (Test-ExcludedRelativePath -RelativePath $RelativePath) {
      continue
    }

    if ($File.Length -gt 1048576 -and -not $Risks.Contains("risk: file larger than 1 MB")) {
      $Risks.Add("risk: file larger than 1 MB")
      continue
    }

    try {
      $Bytes = [System.IO.File]::ReadAllBytes($File.FullName)
      if ($Bytes -contains 0) {
        if (-not $Risks.Contains("risk: binary or unreadable file")) {
          $Risks.Add("risk: binary or unreadable file")
        }
        continue
      }

      $StrictUtf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false, $true
      $Content = $StrictUtf8.GetString($Bytes)
    } catch {
      if (-not $Risks.Contains("risk: binary or unreadable file")) {
        $Risks.Add("risk: binary or unreadable file")
      }
      continue
    }

    if ($Content -match $SecretPattern -and -not $Risks.Contains("risk: secret-like text")) {
      $Risks.Add("risk: secret-like text")
    }

    if ($Content -match $LocalPathPattern -and -not $Risks.Contains("risk: local absolute path")) {
      $Risks.Add("risk: local absolute path")
    }
  }

  return $Risks
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

  $ExistingAttribution =
    (Test-NonEmptyFile -Path (Join-Path $SkillPath "UPSTREAM.md")) -and
    (Test-NonEmptyFile -Path (Join-Path $SkillPath "PATCHES.md")) -and
    (Test-NonEmptyFile -Path (Join-Path $SkillPath "LICENSE"))

  if ($ExistingAttribution) {
    return $true
  }

  if ([string]::IsNullOrWhiteSpace($UpstreamUrl) -or
      [string]::IsNullOrWhiteSpace($UpstreamAuthor) -or
      [string]::IsNullOrWhiteSpace($UpstreamLicense) -or
      [string]::IsNullOrWhiteSpace($LicenseFile) -or
      -not (Test-Path -LiteralPath $LicenseFile -PathType Leaf)) {
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
    if (Test-ExcludedRelativePath -RelativePath $RelativePath) {
      continue
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

  $ExistingAttribution =
    (Test-NonEmptyFile -Path (Join-Path $TargetPath "UPSTREAM.md")) -and
    (Test-NonEmptyFile -Path (Join-Path $TargetPath "PATCHES.md")) -and
    (Test-NonEmptyFile -Path (Join-Path $TargetPath "LICENSE"))

  if ($ExistingAttribution) {
    return
  }

  $UpstreamContent = @(
    "# Upstream",
    "",
    "Original repository: $UpstreamUrl",
    "Original author: $UpstreamAuthor",
    "License: $UpstreamLicense",
    "Imported by: oceans777"
  ) -join [Environment]::NewLine
  Set-Content -LiteralPath (Join-Path $TargetPath "UPSTREAM.md") -Value $UpstreamContent -Encoding UTF8

  if ([string]::IsNullOrWhiteSpace($PatchSummary)) {
    $PatchContent = "# Patches" + [Environment]::NewLine + [Environment]::NewLine + "No local changes."
  } else {
    $PatchContent = "# Patches" + [Environment]::NewLine + [Environment]::NewLine + $PatchSummary
  }
  Set-Content -LiteralPath (Join-Path $TargetPath "PATCHES.md") -Value $PatchContent -Encoding UTF8

  Copy-Item -LiteralPath $LicenseFile -Destination (Join-Path $TargetPath "LICENSE") -Force
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

if (-not (Test-SkillName -Name $Skill)) {
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

$Risks = @(Get-RiskNotes -SkillPath $SourceSkillPath)
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
