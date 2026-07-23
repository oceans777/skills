param(
  [Parameter(Mandatory = $true)][string] $Url,
  [string] $SkillPath,
  [string] $SourceRef,
  [ValidateSet("oceans", "community")][string] $Target = "community",
  [switch] $AllowRisk,
  [switch] $ReplaceExisting,
  [switch] $AllowSourceChange,
  [switch] $DryRun,
  [string] $LocalRepository,
  [string] $CatalogRoot
)

$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptRoot
. (Join-Path $ScriptRoot "skill-publish-rules.ps1")
. (Join-Path $ScriptRoot "skill-catalog.ps1")
. (Join-Path $ScriptRoot "directory-transaction.ps1")

if (-not $CatalogRoot) { $CatalogRoot = Join-Path $RepoRoot "catalog" }
$MaxFiles = if ($env:OCEANS_INTAKE_MAX_FILES) { [int]$env:OCEANS_INTAKE_MAX_FILES } else { 1000 }
$MaxBytes = if ($env:OCEANS_INTAKE_MAX_BYTES) { [long]$env:OCEANS_INTAKE_MAX_BYTES } else { 20971520 }
if ($MaxFiles -le 0 -or $MaxBytes -le 0) { throw "Intake budgets must be positive integers." }
if ($LocalRepository -and $env:OCEANS_TEST_MODE -ne "1") { throw "-LocalRepository is test-only and requires OCEANS_TEST_MODE=1." }
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "oceans-skill-intake-$([Guid]::NewGuid().ToString('N'))"
$CloneRoot = Join-Path $TempRoot "repository"
$LockHeld = $false
$OriginalGitLfsSkipSmudge = $env:GIT_LFS_SKIP_SMUDGE
New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null

function Invoke-GitChecked {
  param([Parameter(Mandatory = $true)][string[]] $Arguments)
  $Output = & git @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed.`n$($Output | Out-String)" }
  return @($Output)
}

function Write-Utf8NoBom {
  param(
    [Parameter(Mandatory = $true)][string] $Path,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string[]] $Lines
  )
  [System.IO.File]::WriteAllLines($Path, $Lines, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-AvailableSourceRefs {
  if ($LocalRepository) {
    return @(Invoke-GitChecked -Arguments @("-C", $LocalRepository, "for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/tags"))
  }
  $Lines = @(Invoke-GitChecked -Arguments @("ls-remote", "--heads", "--tags", $script:CloneUrl))
  $Refs = New-Object System.Collections.Generic.List[string]
  foreach ($Line in $Lines) {
    if ($Line -match '\srefs/(?:heads|tags)/(.+?)(?:\^\{\})?$') {
      $Value = $Matches[1]
      if (-not $Refs.Contains($Value)) { $Refs.Add($Value) }
    }
  }
  return @($Refs)
}

try {
  $Uri = [Uri]$Url
  if ($Uri.Scheme -ne "https" -or $Uri.Host -ne "github.com") { throw "Only https://github.com skill URLs are supported." }
  if ($Uri.AbsolutePath.Contains('%')) { throw "Percent-encoded GitHub paths are not accepted; provide the canonical visible URL." }
  $Segments = @($Uri.AbsolutePath.Trim('/') -split '/')
  if ($Segments.Count -lt 2) { throw "Invalid GitHub repository URL." }
  $Owner = $Segments[0]
  $Repository = $Segments[1] -replace '\.git$', ''
  if ($Owner -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,38}$') { throw "Invalid GitHub owner: $Owner" }
  if ($Repository -notmatch '^[A-Za-z0-9._-]{1,100}$') { throw "Invalid GitHub repository: $Repository" }
  $UpstreamRepository = "https://github.com/$Owner/$Repository"
  $script:CloneUrl = "$UpstreamRepository.git"
  $UrlKind = "repository"
  $RefAndPath = ""
  if ($Segments.Count -gt 2) {
    switch ($Segments[2]) {
      "tree" {
        if ($Segments.Count -lt 4) { throw "GitHub tree URL is missing a ref." }
        $UrlKind = "tree"
        $RefAndPath = ($Segments[3..($Segments.Count - 1)] -join '/')
      }
      "blob" {
        if ($Segments.Count -lt 5) { throw "GitHub blob URL is missing a ref and file path." }
        $UrlKind = "blob"
        $RefAndPath = ($Segments[3..($Segments.Count - 1)] -join '/')
      }
      default { throw "Unsupported GitHub URL shape. Use a repository, tree directory, or SKILL.md blob URL." }
    }
  }

  $ResolvedSourceRef = $SourceRef
  $UrlSkillPath = ""
  if ($UrlKind -ne "repository") {
    if (-not $ResolvedSourceRef) {
      $BestRef = ""
      foreach ($CandidateRef in @(Get-AvailableSourceRefs)) {
        if ($RefAndPath -eq $CandidateRef -or $RefAndPath.StartsWith("$CandidateRef/", [StringComparison]::Ordinal)) {
          if ($CandidateRef.Length -gt $BestRef.Length) { $BestRef = $CandidateRef }
        }
      }
      $ResolvedSourceRef = if ($BestRef) { $BestRef } else { ($RefAndPath -split '/', 2)[0] }
    }
    if ($RefAndPath -ne $ResolvedSourceRef) { $UrlSkillPath = $RefAndPath.Substring($ResolvedSourceRef.Length + 1) }
  }
  if ($UrlKind -eq "blob") {
    if ($UrlSkillPath -eq "SKILL.md") { $UrlSkillPath = "" }
    elseif ($UrlSkillPath.EndsWith('/SKILL.md')) { $UrlSkillPath = $UrlSkillPath.Substring(0, $UrlSkillPath.Length - '/SKILL.md'.Length) }
    else { throw "Blob URL must point to SKILL.md." }
  }
  if ($SkillPath) { $UrlSkillPath = $SkillPath.Replace('\', '/') }
  if ([System.IO.Path]::IsPathRooted($UrlSkillPath) -or $UrlSkillPath.Contains('\') -or (($UrlSkillPath -split '/') -contains '..')) { throw "Unsafe skill path: $UrlSkillPath" }

  $env:GIT_LFS_SKIP_SMUDGE = "1"
  if ($LocalRepository) {
    if (-not (Test-Path -LiteralPath (Join-Path $LocalRepository '.git') -PathType Container)) { throw "-LocalRepository must point to a Git repository." }
    Invoke-GitChecked -Arguments @("clone", "--quiet", "--filter=blob:none", "--no-checkout", $LocalRepository, $CloneRoot) | Out-Null
    if ($ResolvedSourceRef) {
      $ResolvedCommit = ((Invoke-GitChecked -Arguments @("-C", $LocalRepository, "rev-parse", "--verify", "$ResolvedSourceRef^{commit}")) -join '').Trim()
      Invoke-GitChecked -Arguments @("-C", $CloneRoot, "checkout", "--quiet", "--detach", $ResolvedCommit) | Out-Null
    } else {
      Invoke-GitChecked -Arguments @("-C", $CloneRoot, "checkout", "--quiet") | Out-Null
    }
  } else {
    if ($ResolvedSourceRef) {
      Invoke-GitChecked -Arguments @("clone", "--quiet", "--filter=blob:none", "--no-checkout", $script:CloneUrl, $CloneRoot) | Out-Null
      Invoke-GitChecked -Arguments @("-C", $CloneRoot, "fetch", "--quiet", "--depth", "1", "origin", $ResolvedSourceRef) | Out-Null
      Invoke-GitChecked -Arguments @("-C", $CloneRoot, "checkout", "--quiet", "--detach", "FETCH_HEAD") | Out-Null
    } else {
      Invoke-GitChecked -Arguments @("clone", "--quiet", "--depth", "1", "--filter=blob:none", $script:CloneUrl, $CloneRoot) | Out-Null
    }
  }

  $SourceCommit = ((Invoke-GitChecked -Arguments @("-C", $CloneRoot, "rev-parse", "HEAD")) -join '').Trim()
  if (-not $ResolvedSourceRef) {
    $ResolvedSourceRef = ((& git -C $CloneRoot symbolic-ref --quiet --short HEAD 2>$null | Out-String).Trim())
    if (-not $ResolvedSourceRef) { $ResolvedSourceRef = $SourceCommit }
  }

  if ($UrlSkillPath) {
    $SourceSkill = Join-Path $CloneRoot ($UrlSkillPath.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
    if (-not (Test-Path -LiteralPath (Join-Path $SourceSkill 'SKILL.md') -PathType Leaf)) { throw "The selected path does not contain SKILL.md: $UrlSkillPath" }
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

  $SourceSkillItem = Get-Item -LiteralPath $SourceSkill -Force
  if (($SourceSkillItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Selected skill path is a symlink." }
  $SourceSkill = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $SourceSkill).Path)
  $ResolvedCloneRoot = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $CloneRoot).Path)
  $ClonePrefix = $ResolvedCloneRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  if ($SourceSkill -ne $ResolvedCloneRoot -and -not $SourceSkill.StartsWith($ClonePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Selected skill escapes the cloned repository." }

  $Frontmatter = Get-OceansSkillFrontmatter -SkillPath $SourceSkill
  $SkillName = Get-OceansSkillFrontmatterValue -Frontmatter $Frontmatter -Key "name"
  if (-not $SkillName) { throw "The selected SKILL.md has no name." }
  if (-not (Test-OceansSkillName -Name $SkillName)) { throw "Invalid skill name: $SkillName" }
  $MetadataIssues = @(Get-OceansSkillMetadataIssues -SkillPath $SourceSkill -ExpectedName $SkillName)
  if ($MetadataIssues.Count -gt 0) { throw "Invalid skill metadata: $SkillName`n$($MetadataIssues -join [Environment]::NewLine)" }
  $PathIssues = @(Get-OceansSkillPathIssues -SkillPath $SourceSkill)
  if ($PathIssues.Count -gt 0) { throw "Unsafe skill paths: $SkillName`n$($PathIssues -join [Environment]::NewLine)" }

  $IncludedFiles = @(Get-OceansIncludedSkillFiles -SkillPath $SourceSkill)
  if ($IncludedFiles.Count -gt $MaxFiles) { throw "Skill exceeds intake file budget: $($IncludedFiles.Count) > $MaxFiles" }
  $TotalBytes = [long]0
  foreach ($File in $IncludedFiles) {
    $TotalBytes += [long]$File.Length
    if ($TotalBytes -gt $MaxBytes) { throw "Skill exceeds intake size budget: $TotalBytes > $MaxBytes" }
  }

  $PreparedRoot = Join-Path $TempRoot "prepared"
  $PreparedSkill = Join-Path $PreparedRoot $SkillName
  New-Item -ItemType Directory -Force -Path $PreparedSkill | Out-Null
  Get-ChildItem -LiteralPath $SourceSkill -Force | Copy-Item -Destination $PreparedSkill -Recurse -Force
  Remove-OceansExcludedPaths -RootPath $PreparedSkill
  $PackageRepository = if ($Target -eq "oceans") { "oceans-skills" } else { "community-skills" }

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
        "# Upstream", "", "- Repository: $UpstreamRepository", "- Submitted URL: $($Uri.GetLeftPart([UriPartial]::Path).TrimEnd('/'))",
        "- Author or owner: $Owner", "- Imported commit: $SourceCommit", "- Imported path: $UrlSkillPath", "- License: preserved in LICENSE"
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

  $Links = @(Get-OceansSkillItemsNoFollow -SkillPath $PreparedSkill | Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 })
  if ($Links.Count -gt 0) { throw "Candidate contains unsupported symlinks: $SkillName" }
  $Risks = @(Get-OceansSkillRiskNotes -SkillPath $PreparedSkill)
  if ($Risks.Count -gt 0 -and -not $AllowRisk) { throw "risk-blocked: $SkillName`n$($Risks -join [Environment]::NewLine)" }
  $CandidateContentSha256 = Get-OceansSkillContentSha256 -SkillPath $PreparedSkill

  $RecordPath = Get-OceansCatalogRecordPath -CatalogRoot $CatalogRoot -SkillName $SkillName
  if ((Test-Path -LiteralPath $RecordPath -PathType Leaf) -and -not $ReplaceExisting) {
    $ExistingRecord = Get-OceansCatalogRecord -Path $RecordPath
    throw "Skill already exists in catalog state $([string]$ExistingRecord['status']): $SkillName. Use -ReplaceExisting for an intentional candidate update."
  }

  if ($DryRun) {
    Write-Host "candidate-plan-skill: $SkillName"
    Write-Host "candidate-plan-repository: $PackageRepository"
    Write-Host "candidate-plan-source: $UpstreamRepository@$SourceCommit"
    Write-Host "candidate-plan-content-sha256: $CandidateContentSha256"
    Write-Host "candidate-plan-files: $($IncludedFiles.Count)"
    Write-Host "candidate-plan-bytes: $TotalBytes"
    exit 0
  }

  Enter-OceansCatalogLock -CatalogRoot $CatalogRoot -SkillName $SkillName
  $LockHeld = $true
  $RecordPath = Get-OceansCatalogRecordPath -CatalogRoot $CatalogRoot -SkillName $SkillName
  $Existing = Test-Path -LiteralPath $RecordPath -PathType Leaf
  if ($Existing) {
    if (-not $ReplaceExisting) { throw "Skill was added concurrently: $SkillName" }
    $ExistingRecord = Get-OceansCatalogRecord -Path $RecordPath
    $CurrentStatus = [string]$ExistingRecord["status"]
    if ($CurrentStatus -notin @("active", "pending-review")) { throw "Restore or unblock $SkillName before queuing an update from $CurrentStatus." }
    if ([string]$ExistingRecord["package_repository"] -cne $PackageRepository) { throw "Existing skill belongs to $([string]$ExistingRecord['package_repository']); refusing cross-repository migration." }
    $CurrentUpstreamRepository = [string]$ExistingRecord["upstream_repository"]
    if ($CurrentUpstreamRepository -and $CurrentUpstreamRepository -cne $UpstreamRepository -and -not $AllowSourceChange) {
      throw "Upstream repository changed from $CurrentUpstreamRepository to $UpstreamRepository. Use -AllowSourceChange only after an explicit provenance review."
    }
  } else {
    $CurrentStatus = "pending-review"
    $ExistingRecord = @{}
  }

  $ReviewPath = Get-OceansCatalogReviewPath -CatalogRoot $CatalogRoot -PackageRepository $PackageRepository -SkillName $SkillName
  $BackupPath = Join-Path $TempRoot "review-backup"
  if (Test-Path -LiteralPath $ReviewPath -PathType Container) {
    New-Item -ItemType Directory -Force -Path $BackupPath | Out-Null
    Get-ChildItem -LiteralPath $ReviewPath -Force | Copy-Item -Destination $BackupPath -Recurse -Force
  }
  $StagingPath = New-OceansStagingDirectory -TargetPath $ReviewPath
  Get-ChildItem -LiteralPath $PreparedSkill -Force | Copy-Item -Destination $StagingPath -Recurse -Force
  Complete-OceansDirectoryTransaction -StagingPath $StagingPath -TargetPath $ReviewPath

  try {
    Write-OceansCatalogRecord `
      -CatalogRoot $CatalogRoot -SkillName $SkillName -Status $CurrentStatus -PackageRepository $PackageRepository `
      -UpstreamRepository ([string]$ExistingRecord["upstream_repository"]) `
      -UpstreamPath ([string]$ExistingRecord["upstream_path"]) `
      -UpstreamRef ([string]$ExistingRecord["upstream_ref"]) `
      -UpstreamCommit ([string]$ExistingRecord["upstream_commit"]) `
      -ContentSha256 ([string]$ExistingRecord["content_sha256"]) `
      -CandidateUpstreamRepository $UpstreamRepository -CandidateUpstreamPath $UrlSkillPath `
      -CandidateUpstreamRef $ResolvedSourceRef -CandidateUpstreamCommit $SourceCommit `
      -CandidateContentSha256 $CandidateContentSha256 `
      -Replacement ([string]$ExistingRecord["replacement"]) -StatusReason ([string]$ExistingRecord["status_reason"]) `
      -TransitionNote "queued candidate $SourceCommit with content $CandidateContentSha256" | Out-Null
  } catch {
    if (Test-Path -LiteralPath $BackupPath -PathType Container) {
      $RestoreStage = New-OceansStagingDirectory -TargetPath $ReviewPath
      Get-ChildItem -LiteralPath $BackupPath -Force | Copy-Item -Destination $RestoreStage -Recurse -Force
      Complete-OceansDirectoryTransaction -StagingPath $RestoreStage -TargetPath $ReviewPath
    } elseif (Test-Path -LiteralPath $ReviewPath) {
      Remove-Item -LiteralPath $ReviewPath -Recurse -Force
    }
    throw "Catalog candidate registration failed and was rolled back: $SkillName. $($_.Exception.Message)"
  }

  Write-Host "candidate-added: $SkillName"
  Write-Host "catalog-state: $CurrentStatus"
  Write-Host "candidate-commit: $SourceCommit"
  Write-Host "candidate-content-sha256: $CandidateContentSha256"
  if ($Existing) { Write-Host "active-package-preserved: $SkillName" }
  Write-Host "next: review catalog/review-queue/$PackageRepository/$SkillName, then run .\oceans.ps1 catalog -Action activate -Skill $SkillName"
} finally {
  if ($LockHeld) { Exit-OceansCatalogLock }
  if ($null -eq $OriginalGitLfsSkipSmudge) { Remove-Item Env:\GIT_LFS_SKIP_SMUDGE -ErrorAction SilentlyContinue }
  else { $env:GIT_LFS_SKIP_SMUDGE = $OriginalGitLfsSkipSmudge }
  if (Test-Path -LiteralPath $TempRoot) { Remove-Item -LiteralPath $TempRoot -Recurse -Force }
}
