param(
  [Parameter(Position = 0)]
  [ValidateSet("list", "activate", "reject", "cancel-review", "restore", "unblock", "deprecate", "archive", "block")]
  [string] $Action = "list",
  [string] $Skill,
  [string] $Reason,
  [string] $Replacement,
  [string] $CatalogRoot,
  [string] $FirstPartySkillsRoot,
  [string] $CommunitySkillsRoot,
  [string] $InstallRoot,
  [switch] $SkipRuntimeReconcile
)

$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptRoot
. (Join-Path $ScriptRoot "skill-publish-rules.ps1")
. (Join-Path $ScriptRoot "skill-catalog.ps1")
. (Join-Path $ScriptRoot "directory-transaction.ps1")
. (Join-Path $ScriptRoot "skill-roots.ps1") -DefineOnly

if (-not $CatalogRoot) { $CatalogRoot = Join-Path $RepoRoot "catalog" }
if (-not $FirstPartySkillsRoot) { $FirstPartySkillsRoot = Join-Path $RepoRoot "repos\oceans-skills\skills" }
if (-not $CommunitySkillsRoot) { $CommunitySkillsRoot = Join-Path $RepoRoot "repos\community-skills\skills" }
$TempRoot = $null
$LockHeld = $false

function Require-Skill {
  if ([string]::IsNullOrWhiteSpace($Skill)) { throw "-Skill is required." }
  if (-not (Test-OceansCatalogSkillName -Name $Skill)) { throw "Invalid skill name: $Skill" }
}

function Load-Record {
  $script:RecordPath = Get-OceansCatalogRecordPath -CatalogRoot $CatalogRoot -SkillName $Skill
  if (-not (Test-Path -LiteralPath $script:RecordPath -PathType Leaf)) { throw "catalog-skill-not-found: $Skill" }
  $script:Record = Get-OceansCatalogRecord -Path $script:RecordPath
  $script:Status = [string]$script:Record["status"]
  $script:PackageRepository = [string]$script:Record["package_repository"]
  $script:CandidateCommit = [string]$script:Record["candidate_upstream_commit"]
}

function Enter-SkillLock {
  Enter-OceansCatalogLock -CatalogRoot $CatalogRoot -SkillName $Skill
  $script:LockHeld = $true
}

function Invoke-RuntimeReconciliation {
  param([Parameter(Mandatory = $true)][string] $TargetStatus)
  if ($SkipRuntimeReconcile) {
    Write-Host "runtime-reconcile: explicitly-skipped"
    return
  }

  $Arguments = @{
    FirstPartySkillsRoot = $FirstPartySkillsRoot
    CommunitySkillsRoot = $CommunitySkillsRoot
    CatalogRoot = $CatalogRoot
  }
  if ($InstallRoot) {
    $Arguments.InstallRoot = $InstallRoot
  } else {
    $ExistingRoots = @(Get-OceansExistingSkillRoots)
    if ($ExistingRoots.Count -eq 0) {
      Write-Host "runtime-reconcile: no-existing-roots"
      return
    }
    $Arguments.AllExistingRuntimes = $true
  }
  if ($TargetStatus -ne "active") { $Arguments.ReconcileOnly = $true }

  try {
    & (Join-Path $ScriptRoot "install-skills.ps1") @Arguments
  } catch {
    throw "Lifecycle state was committed, but runtime reconciliation failed. $($_.Exception.Message)"
  }
}

function Assert-CandidateValid {
  param([Parameter(Mandatory = $true)][string] $CandidateRoot)
  if (-not (Test-Path -LiteralPath $CandidateRoot -PathType Container)) { throw "Candidate review content is missing: $Skill" }
  $CandidateItem = Get-Item -LiteralPath $CandidateRoot -Force
  if (($CandidateItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Candidate review content is unsafe: $Skill" }
  if (-not (Test-Path -LiteralPath (Join-Path $CandidateRoot "SKILL.md") -PathType Leaf)) { throw "Candidate is missing SKILL.md: $Skill" }
  $MetadataIssues = @(Get-OceansSkillMetadataIssues -SkillPath $CandidateRoot -ExpectedName $Skill)
  if ($MetadataIssues.Count -gt 0) { throw "Invalid candidate metadata: $Skill`n$($MetadataIssues -join [Environment]::NewLine)" }
  $PathIssues = @(Get-OceansSkillPathIssues -SkillPath $CandidateRoot)
  if ($PathIssues.Count -gt 0) { throw "Unsafe candidate path: $Skill`n$($PathIssues -join [Environment]::NewLine)" }
  $Links = @(Get-OceansSkillItemsNoFollow -SkillPath $CandidateRoot | Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 })
  if ($Links.Count -gt 0) { throw "Candidate contains unsupported symlinks: $Skill" }
  $Risks = @(Get-OceansSkillRiskNotes -SkillPath $CandidateRoot)
  if ($Risks.Count -gt 0) { throw "Candidate risk validation failed: $Skill`n$($Risks -join [Environment]::NewLine)" }
  if ($script:PackageRepository -eq "community-skills") {
    foreach ($Required in @("UPSTREAM.md", "PATCHES.md", "LICENSE")) {
      $RequiredPath = Join-Path $CandidateRoot $Required
      if (-not (Test-Path -LiteralPath $RequiredPath -PathType Leaf) -or (Get-Item -LiteralPath $RequiredPath).Length -eq 0) {
        throw "Candidate is missing ${Required}: $Skill"
      }
    }
  }
}

function Restore-PackageFromBackup {
  param(
    [Parameter(Mandatory = $true)][string] $TargetPath,
    [Parameter(Mandatory = $true)][string] $BackupPath
  )
  if (Test-Path -LiteralPath $BackupPath -PathType Container) {
    $RestoreStage = New-OceansStagingDirectory -TargetPath $TargetPath
    Get-ChildItem -LiteralPath $BackupPath -Force | Copy-Item -Destination $RestoreStage -Recurse -Force
    Complete-OceansDirectoryTransaction -StagingPath $RestoreStage -TargetPath $TargetPath
  } elseif (Test-Path -LiteralPath $TargetPath) {
    Remove-Item -LiteralPath $TargetPath -Recurse -Force
  }
}

function Remove-ReviewHoldBestEffort {
  param([Parameter(Mandatory = $true)][string] $ReviewHold)
  if (-not (Test-Path -LiteralPath $ReviewHold)) { return }
  try {
    Remove-Item -LiteralPath $ReviewHold -Recurse -Force
  } catch {
    Write-Warning "Committed lifecycle state is valid, but temporary review hold could not be removed: $ReviewHold"
  }
}

function Promote-Candidate {
  Load-Record
  if ($script:Status -notin @("pending-review", "active")) { throw "catalog-transition-not-allowed: $($script:Status) -> active" }
  if ([string]::IsNullOrWhiteSpace($script:CandidateCommit)) { throw "catalog-candidate-not-found: $Skill" }
  $ReviewPath = Get-OceansCatalogReviewPath -CatalogRoot $CatalogRoot -PackageRepository $script:PackageRepository -SkillName $Skill
  Assert-CandidateValid -CandidateRoot $ReviewPath
  $TargetRoot = if ($script:PackageRepository -eq "oceans-skills") { $FirstPartySkillsRoot } else { $CommunitySkillsRoot }
  $TargetPath = Join-Path $TargetRoot $Skill
  if ($script:Status -eq "pending-review" -and (Test-Path -LiteralPath $TargetPath)) { throw "Pending new skill already exists in package repository: $Skill" }

  $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "oceans-catalog-promote-$([Guid]::NewGuid().ToString('N'))"
  New-Item -ItemType Directory -Force -Path $script:TempRoot | Out-Null
  $BackupPath = Join-Path $script:TempRoot "package-backup"
  if (Test-Path -LiteralPath $TargetPath -PathType Container) {
    New-Item -ItemType Directory -Force -Path $BackupPath | Out-Null
    Get-ChildItem -LiteralPath $TargetPath -Force | Copy-Item -Destination $BackupPath -Recurse -Force
  }
  $ReviewHold = Join-Path (Split-Path -Parent $ReviewPath) ".$Skill.promoting.$PID"
  if (Test-Path -LiteralPath $ReviewHold) { throw "Candidate promotion hold already exists: $ReviewHold" }
  Move-Item -LiteralPath $ReviewPath -Destination $ReviewHold

  try {
    $StagingPath = New-OceansStagingDirectory -TargetPath $TargetPath
    Get-ChildItem -LiteralPath $ReviewHold -Force | Copy-Item -Destination $StagingPath -Recurse -Force
    Remove-OceansExcludedPaths -RootPath $StagingPath
    Complete-OceansDirectoryTransaction -StagingPath $StagingPath -TargetPath $TargetPath

    Write-OceansCatalogRecord `
      -CatalogRoot $CatalogRoot -SkillName $Skill -Status "active" -PackageRepository $script:PackageRepository `
      -UpstreamRepository ([string]$script:Record["candidate_upstream_repository"]) `
      -UpstreamPath ([string]$script:Record["candidate_upstream_path"]) `
      -UpstreamRef ([string]$script:Record["candidate_upstream_ref"]) `
      -UpstreamCommit ([string]$script:Record["candidate_upstream_commit"]) `
      -TransitionNote "activated reviewed candidate $($script:CandidateCommit)" | Out-Null
  } catch {
    try { Restore-PackageFromBackup -TargetPath $TargetPath -BackupPath $BackupPath } catch { Write-Warning "CRITICAL: failed to restore package after activation failure: $Skill" }
    if (Test-Path -LiteralPath $ReviewHold -PathType Container) { Move-Item -LiteralPath $ReviewHold -Destination $ReviewPath }
    throw "Candidate activation failed and was rolled back: $Skill. $($_.Exception.Message)"
  }

  # Package and catalog are the commit point. Hold cleanup cannot roll them back.
  Remove-ReviewHoldBestEffort -ReviewHold $ReviewHold
  Write-Host "catalog-state: active"
  Write-Host "skill: $Skill"
  Write-Host "activated-commit: $($script:CandidateCommit)"
}

function Reject-Candidate {
  Load-Record
  if ([string]::IsNullOrWhiteSpace($script:CandidateCommit)) { throw "catalog-candidate-not-found: $Skill" }
  $ReviewPath = Get-OceansCatalogReviewPath -CatalogRoot $CatalogRoot -PackageRepository $script:PackageRepository -SkillName $Skill
  if (-not (Test-Path -LiteralPath $ReviewPath -PathType Container)) { throw "Candidate review content is missing: $Skill" }
  $ReviewHold = Join-Path (Split-Path -Parent $ReviewPath) ".$Skill.rejecting.$PID"
  Move-Item -LiteralPath $ReviewPath -Destination $ReviewHold
  try {
    if ($script:Status -eq "pending-review") {
      Remove-Item -LiteralPath $script:RecordPath -Force
      Write-Host "catalog-record-removed: $Skill"
    } else {
      Write-OceansCatalogRecord `
        -CatalogRoot $CatalogRoot -SkillName $Skill -Status $script:Status -PackageRepository $script:PackageRepository `
        -UpstreamRepository ([string]$script:Record["upstream_repository"]) `
        -UpstreamPath ([string]$script:Record["upstream_path"]) `
        -UpstreamRef ([string]$script:Record["upstream_ref"]) `
        -UpstreamCommit ([string]$script:Record["upstream_commit"]) `
        -Replacement ([string]$script:Record["replacement"]) `
        -StatusReason ([string]$script:Record["status_reason"]) `
        -TransitionNote "rejected candidate $($script:CandidateCommit)" | Out-Null
      Write-Host "catalog-state: $($script:Status)"
    }
  } catch {
    if (Test-Path -LiteralPath $ReviewHold -PathType Container) { Move-Item -LiteralPath $ReviewHold -Destination $ReviewPath }
    throw "Candidate rejection failed and was rolled back: $Skill. $($_.Exception.Message)"
  }

  # Record state is the commit point. Cleanup failure leaves only a removable hold.
  Remove-ReviewHoldBestEffort -ReviewHold $ReviewHold
  Write-Host "catalog-candidate-rejected: $Skill"
}

function Set-LifecycleStatus {
  param(
    [Parameter(Mandatory = $true)][string] $TargetStatus,
    [Parameter(Mandatory = $true)][string] $TransitionKind
  )
  Load-Record
  if (-not [string]::IsNullOrWhiteSpace($script:CandidateCommit)) { throw "Resolve the pending candidate before changing lifecycle status: $Skill" }
  $Allowed = @(
    "restore:deprecated", "restore:archived", "unblock:blocked", "deprecate:active",
    "archive:active", "archive:deprecated", "block:active", "block:deprecated", "block:archived"
  )
  if ($Allowed -notcontains "$TransitionKind`:$($script:Status)") { throw "catalog-transition-not-allowed: $($script:Status) -> $TargetStatus" }

  $NewReplacement = if ($Replacement) { $Replacement } else { [string]$script:Record["replacement"] }
  $StatusReason = ""
  $TransitionNote = $TransitionKind
  if ($TargetStatus -in @("deprecated", "archived", "blocked")) {
    if ([string]::IsNullOrWhiteSpace($Reason)) { throw "-Reason is required for $TransitionKind." }
    $StatusReason = $Reason
    $TransitionNote = $Reason
  } else {
    $NewReplacement = ""
    if ($Reason) { $TransitionNote = $Reason }
  }

  Write-OceansCatalogRecord `
    -CatalogRoot $CatalogRoot -SkillName $Skill -Status $TargetStatus -PackageRepository $script:PackageRepository `
    -UpstreamRepository ([string]$script:Record["upstream_repository"]) `
    -UpstreamPath ([string]$script:Record["upstream_path"]) `
    -UpstreamRef ([string]$script:Record["upstream_ref"]) `
    -UpstreamCommit ([string]$script:Record["upstream_commit"]) `
    -Replacement $NewReplacement -StatusReason $StatusReason -TransitionNote $TransitionNote | Out-Null

  Invoke-RuntimeReconciliation -TargetStatus $TargetStatus
  Write-Host "catalog-state: $TargetStatus"
  Write-Host "skill: $Skill"
}

try {
  if ($Action -eq "list") {
    Write-Output "status|repository|name|candidate|replacement|reason"
    $SkillsDirectory = Join-Path $CatalogRoot "skills"
    if (Test-Path -LiteralPath $SkillsDirectory -PathType Container) {
      foreach ($RecordFile in @(Get-ChildItem -LiteralPath $SkillsDirectory -Filter '*.skill' -File | Sort-Object Name)) {
        $CatalogRecord = Get-OceansCatalogRecord -Path $RecordFile.FullName
        $Candidate = if ([string]::IsNullOrWhiteSpace([string]$CatalogRecord["candidate_upstream_commit"])) { "no" } else { "yes" }
        Write-Output "$([string]$CatalogRecord['status'])|$([string]$CatalogRecord['package_repository'])|$([string]$CatalogRecord['name'])|$Candidate|$([string]$CatalogRecord['replacement'])|$([string]$CatalogRecord['status_reason'])"
      }
    }
    exit 0
  }

  Require-Skill
  Enter-SkillLock
  switch ($Action) {
    "activate" { Promote-Candidate }
    { $_ -in @("reject", "cancel-review") } { Reject-Candidate }
    "restore" { Set-LifecycleStatus -TargetStatus "active" -TransitionKind "restore" }
    "unblock" {
      if ([string]::IsNullOrWhiteSpace($Reason)) { throw "-Reason is required for unblock." }
      Set-LifecycleStatus -TargetStatus "active" -TransitionKind "unblock"
    }
    "deprecate" { Set-LifecycleStatus -TargetStatus "deprecated" -TransitionKind "deprecate" }
    "archive" { Set-LifecycleStatus -TargetStatus "archived" -TransitionKind "archive" }
    "block" { Set-LifecycleStatus -TargetStatus "blocked" -TransitionKind "block" }
  }
} finally {
  if ($LockHeld) { Exit-OceansCatalogLock }
  if ($TempRoot -and (Test-Path -LiteralPath $TempRoot)) { Remove-Item -LiteralPath $TempRoot -Recurse -Force }
}
