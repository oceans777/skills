param(
  [Parameter(Mandatory = $true)][string] $Url,
  [string] $SkillPath,
  [ValidateSet("oceans", "community")][string] $Target = "community",
  [switch] $Activate,
  [switch] $AllowRisk,
  [switch] $ReplaceExisting,
  [switch] $DryRun,
  [string] $LocalRepository,
  [string] $FirstPartySkillsRoot,
  [string] $CommunitySkillsRoot,
  [string] $CatalogRoot
)

$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptRoot
. (Join-Path $ScriptRoot "skill-publish-rules.ps1")
. (Join-Path $ScriptRoot "skill-catalog.ps1")

if (-not $FirstPartySkillsRoot) { $FirstPartySkillsRoot = Join-Path $RepoRoot "repos\oceans-skills\skills" }
if (-not $CommunitySkillsRoot) { $CommunitySkillsRoot = Join-Path $RepoRoot "repos\community-skills\skills" }
if (-not $CatalogRoot) { $CatalogRoot = Join-Path $RepoRoot "catalog" }

function Invoke-GitChecked {
  param([Parameter(Mandatory = $true)][string[]] $Arguments)
  $Output = & git @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "git $($Arguments -join ' ') failed.`n$($Output | Out-String)"
  }
  return @($Output)
}

function Write-Utf8NoBom {
  param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string[]] $Lines)
  [System.IO.File]::WriteAllLines($Path, $Lines, (New-Object System.Text.UTF8Encoding($false)))
}

$Uri = [Uri]$Url
if ($Uri.Scheme -ne "https" -or $Uri.Host -ne "github.com") {
  throw "Only https://github.com skill URLs are supported."
}
$Segments = @($Uri.AbsolutePath.Trim('/') -split '/')
if ($Segments.Count -lt 2) { throw "Invalid GitHub repository URL." }
$Owner = $Segments[0]
$Repository = $Segments[1] -replace '\.git$', ''
$SourceRef = ""
$UrlSkillPath = ""
if ($Segments.Count -gt 2) {
  switch ($Segments[2]) {
    "tree" {
      if ($Segments.Count -lt 4) { throw "GitHub tree URL is missing a ref." }
      $SourceRef = $Segments[3]
      if ($Segments.Count -gt 4) { $UrlSkillPath = ($Segments[4..($Segments.Count - 1)] -join '/') }
    }
    "blob" {
      if ($Segments.Count -lt 5) { throw "GitHub blob URL is missing a file path." }
      $SourceRef = $Segments[3]
      $BlobPath = ($Segments[4..($Segments.Count - 1)] -join '/')
      if ($BlobPath -eq "SKILL.md") { $UrlSkillPath = "" }
      elseif ($BlobPath.EndsWith('/SKILL.md')) { $UrlSkillPath = $BlobPath.Substring(0, $BlobPath.Length - '/SKILL.md'.Length) }
      else { throw "Blob URL must point to SKILL.md." }
    }
    default { throw "Unsupported GitHub URL shape. Use a repository, tree directory, or SKILL.md blob URL." }
  }
}
if ($SkillPath) { $UrlSkillPath = $SkillPath.Replace('\', '/') }
if ([System.IO.Path]::IsPathRooted($UrlSkillPath) -or ($UrlSkillPath -split '/') -contains '..') {
  throw "Unsafe skill path: $UrlSkillPath"
}

$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "oceans-skill-intake-$([Guid]::NewGuid().ToString('N'))"
$CloneRoot = Join-Path $TempRoot "repository"
New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null
try {
  if ($LocalRepository) {
    if (-not (Test-Path -LiteralPath (Join-Path $LocalRepository '.git') -PathType Container)) {
      throw "-LocalRepository must point to a Git repository."
    }
    Invoke-GitChecked -Arguments @("clone", "--quiet", $LocalRepository, $CloneRoot) | Out-Null
    if ($SourceRef) {
      $ResolvedRef = ((Invoke-GitChecked -Arguments @("-C", $CloneRoot, "rev-parse", "--verify", "$SourceRef^{commit}")) -join '').Trim()
      Invoke-GitChecked -Arguments @("-C", $CloneRoot, "checkout", "--quiet", "--detach", $ResolvedRef) | Out-Null
    }
  } else {
    $CloneUrl = "https://github.com/$Owner/$Repository.git"
    $CloneArguments = @("clone", "--quiet", "--depth", "1")
    if ($SourceRef) { $CloneArguments += @("--branch", $SourceRef) }
    $CloneArguments += @($CloneUrl, $CloneRoot)
    Invoke-GitChecked -Arguments $CloneArguments | Out-Null
  }

  $SourceCommit = ((Invoke-GitChecked -Arguments @("-C", $CloneRoot, "rev-parse", "HEAD")) -join '').Trim()
  if (-not $SourceRef) {
    $SourceRef = ((Invoke-GitChecked -Arguments @("-C", $CloneRoot, "rev-parse", "--abbrev-ref", "HEAD")) -join '').Trim()
  }

  if ($UrlSkillPath) {
    $SourceSkill = Join-Path $CloneRoot ($UrlSkillPath.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
    if (-not (Test-Path -LiteralPath (Join-Path $SourceSkill 'SKILL.md') -PathType Leaf)) {
      throw "The selected path does not contain SKILL.md: $UrlSkillPath"
    }
  } elseif (Test-Path -LiteralPath (Join-Path $CloneRoot 'SKILL.md') -PathType Leaf) {
    $SourceSkill = $CloneRoot
    $UrlSkillPath = "."
  } else {
    $Matches = @(Get-ChildItem -LiteralPath $CloneRoot -Filter SKILL.md -File -Recurse | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' })
    if ($Matches.Count -eq 0) { throw "No SKILL.md was found in the repository." }
    if ($Matches.Count -gt 1) {
      $Paths = $Matches | ForEach-Object { $_.FullName.Substring($CloneRoot.Length + 1) }
      throw "Multiple skills were found; rerun with -SkillPath.`n$($Paths -join [Environment]::NewLine)"
    }
    $SourceSkill = $Matches[0].Directory.FullName
    $UrlSkillPath = $SourceSkill.Substring($CloneRoot.Length).TrimStart('\', '/').Replace('\', '/')
  }

  $Frontmatter = Get-OceansSkillFrontmatter -SkillPath $SourceSkill
  $SkillName = Get-OceansSkillFrontmatterValue -Frontmatter $Frontmatter -Key "name"
  if (-not $SkillName) { throw "The selected SKILL.md has no name." }
  if (-not (Test-OceansSkillName -Name $SkillName)) { throw "Invalid skill name: $SkillName" }
  $MetadataIssues = @(Get-OceansSkillMetadataIssues -SkillPath $SourceSkill -ExpectedName $SkillName)
  if ($MetadataIssues.Count -gt 0) { throw "Invalid skill metadata: $SkillName`n$($MetadataIssues -join [Environment]::NewLine)" }

  $ExistingState = Get-OceansCatalogStateForSkill -CatalogRoot $CatalogRoot -SkillName $SkillName
  $ExistingRecordPath = $null
  if ($ExistingState) {
    if (-not $ReplaceExisting) {
      throw "Skill already exists in catalog state ${ExistingState}: $SkillName. Use -ReplaceExisting for an intentional update."
    }
    $ExistingRecordPath = Get-OceansCatalogRecordPath -CatalogRoot $CatalogRoot -State $ExistingState -SkillName $SkillName
    $ExistingRecord = Get-OceansCatalogRecord -Path $ExistingRecordPath
    $DesiredRepository = if ($Target -eq "oceans") { "oceans-skills" } else { "community-skills" }
    if ([string]$ExistingRecord["repository"] -cne $DesiredRepository) {
      throw "Existing skill belongs to $([string]$ExistingRecord['repository']); refusing to move it across repositories."
    }
  }

  $PreparedRoot = Join-Path $TempRoot "prepared"
  $PreparedSkill = Join-Path $PreparedRoot $SkillName
  New-Item -ItemType Directory -Force -Path $PreparedSkill | Out-Null
  Get-ChildItem -LiteralPath $SourceSkill -Force | Copy-Item -Destination $PreparedSkill -Recurse -Force
  $PreparedGit = Join-Path $PreparedSkill '.git'
  if (Test-Path -LiteralPath $PreparedGit) { Remove-Item -LiteralPath $PreparedGit -Recurse -Force }

  if ($Target -eq "community") {
    $PreparedLicense = Join-Path $PreparedSkill "LICENSE"
    if (-not (Test-Path -LiteralPath $PreparedLicense -PathType Leaf) -or (Get-Item $PreparedLicense).Length -eq 0) {
      $LicenseSource = $null
      foreach ($Candidate in @("LICENSE", "LICENSE.md", "LICENSE.txt", "COPYING", "COPYING.md")) {
        $CandidatePath = Join-Path $CloneRoot $Candidate
        if (Test-Path -LiteralPath $CandidatePath -PathType Leaf) { $LicenseSource = $CandidatePath; break }
      }
      if (-not $LicenseSource) { throw "Community skill has no preserved license file." }
      Copy-Item -LiteralPath $LicenseSource -Destination $PreparedLicense -Force
    }
    $UpstreamPath = Join-Path $PreparedSkill "UPSTREAM.md"
    if (-not (Test-Path -LiteralPath $UpstreamPath -PathType Leaf) -or (Get-Item $UpstreamPath).Length -eq 0) {
      Write-Utf8NoBom -Path $UpstreamPath -Lines @(
        "# Upstream", "", "- Repository: https://github.com/$Owner/$Repository",
        "- Submitted URL: $($Uri.GetLeftPart([UriPartial]::Path).TrimEnd('/'))", "- Author or owner: $Owner",
        "- Imported commit: $SourceCommit", "- Imported path: $UrlSkillPath", "- License: preserved in LICENSE"
      )
    }
    $PatchesPath = Join-Path $PreparedSkill "PATCHES.md"
    if (-not (Test-Path -LiteralPath $PatchesPath -PathType Leaf) -or (Get-Item $PatchesPath).Length -eq 0) {
      Write-Utf8NoBom -Path $PatchesPath -Lines @(
        "# Local changes", "", "- Added oceans777 packaging and attribution metadata during intake.",
        "- No functional source changes were made by the intake command."
      )
    }
  }

  $TargetRoot = if ($Target -eq "oceans") { $FirstPartySkillsRoot } else { $CommunitySkillsRoot }
  $TargetPath = Join-Path $TargetRoot $SkillName
  $BackupPath = $null
  if ($ReplaceExisting -and (Test-Path -LiteralPath $TargetPath -PathType Container)) {
    $BackupPath = Join-Path $TempRoot "existing-skill-backup"
    New-Item -ItemType Directory -Force -Path $BackupPath | Out-Null
    Get-ChildItem -LiteralPath $TargetPath -Force | Copy-Item -Destination $BackupPath -Recurse -Force
  }

  $StageArguments = @{
    SourceRoot = $PreparedRoot
    Skill = $SkillName
    Target = $Target
    FirstPartySkillsRoot = $FirstPartySkillsRoot
    CommunitySkillsRoot = $CommunitySkillsRoot
  }
  if ($AllowRisk) { $StageArguments.AllowRisk = $true }
  if ($ReplaceExisting) { $StageArguments.ReplaceExisting = $true }
  if ($DryRun) { $StageArguments.DryRun = $true }
  & (Join-Path $ScriptRoot "stage-skill.ps1") @StageArguments

  $State = if ($Activate) { "active" } else { "pending-review" }
  $CatalogRepository = if ($Target -eq "oceans") { "oceans-skills" } else { "community-skills" }
  if ($DryRun) {
    Write-Host "catalog-plan-state: $State"
    Write-Host "catalog-plan-skill: $SkillName"
    exit 0
  }

  try {
    $NewRecordPath = Write-OceansCatalogRecord `
      -CatalogRoot $CatalogRoot -State $State -SkillName $SkillName -Repository $CatalogRepository `
      -SourceUrl ($Uri.GetLeftPart([UriPartial]::Path).TrimEnd('/')) -SourcePath "skills/$SkillName" `
      -SourceRef $SourceRef -SourceCommit $SourceCommit
    if ($ExistingRecordPath -and -not $ExistingRecordPath.Equals($NewRecordPath, [StringComparison]::OrdinalIgnoreCase)) {
      Remove-Item -LiteralPath $ExistingRecordPath -Force
    }
  } catch {
    if (Test-Path -LiteralPath $TargetPath) { Remove-Item -LiteralPath $TargetPath -Recurse -Force }
    if ($BackupPath) {
      New-Item -ItemType Directory -Force -Path $TargetPath | Out-Null
      Get-ChildItem -LiteralPath $BackupPath -Force | Copy-Item -Destination $TargetPath -Recurse -Force
    }
    throw "Catalog registration failed; staged skill was rolled back: $SkillName. $($_.Exception.Message)"
  }

  Write-Host "added-skill: $SkillName"
  Write-Host "catalog-state: $State"
  Write-Host "source-commit: $SourceCommit"
  if ($State -eq "pending-review") {
    Write-Host "next: review files, then run .\oceans.ps1 catalog -Action activate -Skill $SkillName"
  } else {
    Write-Host "next: run .\oceans.ps1 validate, then .\oceans.ps1 publish"
  }
} finally {
  if (Test-Path -LiteralPath $TempRoot) { Remove-Item -LiteralPath $TempRoot -Recurse -Force }
}
