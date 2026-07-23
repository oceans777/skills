param(
  [string] $InstallRoot,
  [ValidateSet("codex", "agents", "claude", "openclaw", "hermes", "custom")]
  [string] $Runtime = "codex",
  [switch] $AllExistingRuntimes,
  [string] $FirstPartySkillsRoot,
  [string] $CommunitySkillsRoot,
  [string] $CatalogRoot,
  [switch] $WithoutCatalog,
  [switch] $ReconcileOnly,
  [string] $TargetSkill,
  [switch] $LifecycleReconcile,
  [switch] $BestEffortRoots
)

$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptRoot
$RequestedInstallRoot = $InstallRoot
$RequestedRuntime = $Runtime
$CustomSourceRoots = $PSBoundParameters.ContainsKey("FirstPartySkillsRoot") -or $PSBoundParameters.ContainsKey("CommunitySkillsRoot")
$CatalogExplicit = $PSBoundParameters.ContainsKey("CatalogRoot")
. (Join-Path $ScriptRoot "skill-roots.ps1") -DefineOnly
. (Join-Path $ScriptRoot "directory-transaction.ps1")
. (Join-Path $ScriptRoot "skill-publish-rules.ps1")
. (Join-Path $ScriptRoot "skill-catalog.ps1")
$InstallRoot = $RequestedInstallRoot
$Runtime = $RequestedRuntime

if (-not $FirstPartySkillsRoot) { $FirstPartySkillsRoot = Join-Path $RepoRoot "repos\oceans-skills\skills" }
if (-not $CommunitySkillsRoot) { $CommunitySkillsRoot = Join-Path $RepoRoot "repos\community-skills\skills" }
if (-not $CatalogRoot) { $CatalogRoot = Join-Path $RepoRoot "catalog" }
if ($CustomSourceRoots -and -not $CatalogExplicit -and -not $WithoutCatalog) {
  throw "Custom skill roots require -CatalogRoot. Use -WithoutCatalog only for an intentional legacy fixture."
}
if ($WithoutCatalog -and $CatalogExplicit) { throw "-WithoutCatalog cannot be combined with -CatalogRoot." }
if ($ReconcileOnly -and $WithoutCatalog) { throw "-ReconcileOnly requires lifecycle catalog governance." }
if ($LifecycleReconcile -and $WithoutCatalog) { throw "-LifecycleReconcile requires lifecycle catalog governance." }
if ($TargetSkill -and -not (Test-OceansCatalogSkillName -Name $TargetSkill)) { throw "Invalid target skill name: $TargetSkill" }
$CatalogEnabled = -not $WithoutCatalog

if (-not $LifecycleReconcile) {
  $ValidationArguments = @{
    FirstPartySkillsRoot = $FirstPartySkillsRoot
    CommunitySkillsRoot = $CommunitySkillsRoot
  }
  if ($CatalogEnabled) { $ValidationArguments.CatalogRoot = $CatalogRoot } else { $ValidationArguments.WithoutCatalog = $true }
  try {
    & (Join-Path $ScriptRoot "validate-skills.ps1") @ValidationArguments | Out-Null
  } catch {
    throw "Refusing to install from an invalid or unsafe skill repository. $($_.Exception.Message)"
  }
} elseif ($TargetSkill) {
  $TargetRecordPath = Get-OceansCatalogRecordPath -CatalogRoot $CatalogRoot -SkillName $TargetSkill
  if (-not (Test-Path -LiteralPath $TargetRecordPath -PathType Leaf)) {
    throw "Missing catalog record for lifecycle reconciliation: $TargetSkill"
  }
  $TargetState = Get-OceansCatalogStateForSkill -CatalogRoot $CatalogRoot -SkillName $TargetSkill
  if (-not $TargetState) { throw "Invalid catalog state for lifecycle reconciliation: $TargetSkill" }
}

$Sources = @(
  [PSCustomObject]@{ Repository = "oceans-skills"; Path = $FirstPartySkillsRoot },
  [PSCustomObject]@{ Repository = "community-skills"; Path = $CommunitySkillsRoot }
)

if ($InstallRoot) {
  $InstallTargets = @(Get-OceansRuntimeRoot -Runtime "custom" -Path $InstallRoot -Operation "install" -Create)
} elseif ($AllExistingRuntimes) {
  $InstallTargets = @(Get-OceansExistingSkillRoots)
} else {
  $InstallTargets = @(Get-OceansRuntimeRoot -Runtime $Runtime -Operation "install" -Create)
}
if ($InstallTargets.Count -eq 0) {
  if ($ReconcileOnly) { Write-Host "runtime-reconcile: no-existing-roots"; exit 0 }
  throw "No existing runtime skill roots found for install."
}
foreach ($InstallTarget in $InstallTargets) {
  Register-OceansSkillRoot -Runtime $InstallTarget.Runtime -Path $InstallTarget.Path
}

function Get-MarkerValue {
  param([string] $MarkerPath, [string] $Key)
  $Line = Get-Content -LiteralPath $MarkerPath -ErrorAction SilentlyContinue |
    Where-Object { $_ -like "$Key=*" } | Select-Object -First 1
  if (-not $Line) { return "" }
  return $Line.Substring($Key.Length + 1)
}

function Test-KnownOceansSource {
  param([string] $Repository)
  return $Repository -in @("oceans-skills", "community-skills")
}

function Test-ManagedMarker {
  param(
    [Parameter(Mandatory = $true)][string] $MarkerPath,
    [Parameter(Mandatory = $true)][string] $ExpectedSkill,
    [Parameter(Mandatory = $true)][string] $ExpectedRoot
  )
  if (-not (Test-Path -LiteralPath $MarkerPath -PathType Leaf)) { return $false }
  $MarkerItem = Get-Item -LiteralPath $MarkerPath -Force
  if (($MarkerItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
  $SourceRepository = Get-MarkerValue -MarkerPath $MarkerPath -Key "source_repository"
  if (-not (Test-KnownOceansSource -Repository $SourceRepository)) { return $false }
  $MarkerSkill = Get-MarkerValue -MarkerPath $MarkerPath -Key "skill_name"
  $MarkerRoot = Get-MarkerValue -MarkerPath $MarkerPath -Key "install_root"
  if ($MarkerSkill -and $MarkerSkill -cne $ExpectedSkill) { return $false }
  $Comparer = Get-OceansPathComparer
  if ($MarkerRoot -and -not $Comparer.Equals($MarkerRoot, $ExpectedRoot)) { return $false }
  return $true
}

function Get-CatalogStatus {
  param([string] $SkillName)
  if (-not $CatalogEnabled) { return "active" }
  $Status = Get-OceansCatalogStateForSkill -CatalogRoot $CatalogRoot -SkillName $SkillName
  if (-not $Status) { throw "Missing catalog record: $SkillName" }
  return $Status
}

function Assert-NotReparseDirectory {
  param([Parameter(Mandatory = $true)][string] $Path)
  if (-not (Test-Path -LiteralPath $Path)) { return }
  $Item = Get-Item -LiteralPath $Path -Force
  if (-not $Item.PSIsContainer -or ($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Refusing unsafe directory: $Path"
  }
}

function Get-ManagedDisabledRoot {
  param([Parameter(Mandatory = $true)][string] $ResolvedInstallRoot)
  $Parent = Split-Path -Parent $ResolvedInstallRoot
  $InstallLeaf = Split-Path -Leaf $ResolvedInstallRoot
  $DisabledBase = Join-Path $Parent ".oceans-disabled"
  Assert-NotReparseDirectory -Path $DisabledBase
  $DisabledRoot = Join-Path $DisabledBase $InstallLeaf
  Assert-NotReparseDirectory -Path $DisabledRoot
  return $DisabledRoot
}

function Disable-ManagedSkill {
  param(
    [Parameter(Mandatory = $true)][string] $SourcePath,
    [Parameter(Mandatory = $true)][string] $DisabledRoot,
    [Parameter(Mandatory = $true)][string] $State,
    [Parameter(Mandatory = $true)][string] $SkillName
  )
  $SourceItem = Get-Item -LiteralPath $SourcePath -Force
  if (($SourceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing to disable symlinked managed skill: $SkillName" }
  Assert-NotReparseDirectory -Path $DisabledRoot
  $StateRoot = Join-Path $DisabledRoot $State
  Assert-NotReparseDirectory -Path $StateRoot
  $Destination = Join-Path $StateRoot $SkillName
  $StagingPath = New-OceansStagingDirectory -TargetPath $Destination
  try {
    Get-ChildItem -LiteralPath $SourcePath -Force | Copy-Item -Destination $StagingPath -Recurse -Force
    Complete-OceansDirectoryTransaction -StagingPath $StagingPath -TargetPath $Destination
    Remove-Item -LiteralPath $SourcePath -Recurse -Force
  } catch {
    if (Test-Path -LiteralPath $StagingPath) { Remove-Item -LiteralPath $StagingPath -Recurse -Force }
    throw "Failed to preserve and disable managed $State skill: $SkillName. $($_.Exception.Message)"
  }
  Write-Host "Disabled managed $State skill: $SkillName"
  Write-Host "Preserved at: $Destination"
}

function Remove-DisabledCopies {
  param([string] $DisabledRoot, [string] $SkillName)
  foreach ($State in @("pending-review", "deprecated", "archived", "blocked")) {
    $Path = Join-Path (Join-Path $DisabledRoot $State) $SkillName
    if (Test-Path -LiteralPath $Path -PathType Container) {
      $Item = Get-Item -LiteralPath $Path -Force
      if (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) { Remove-Item -LiteralPath $Path -Recurse -Force }
    }
  }
}

function Reconcile-ManagedSkills {
  param([Parameter(Mandatory = $true)][string] $ResolvedInstallRoot)
  if (-not $CatalogEnabled) { return }
  $DisabledRoot = Get-ManagedDisabledRoot -ResolvedInstallRoot $ResolvedInstallRoot
  $Errors = New-Object System.Collections.Generic.List[string]
  $InstalledDirectories = if ($TargetSkill) {
    $TargetPath = Join-Path $ResolvedInstallRoot $TargetSkill
    if (Test-Path -LiteralPath $TargetPath -PathType Container) { @(Get-Item -LiteralPath $TargetPath -Force) } else { @() }
  } else {
    @(Get-ChildItem -LiteralPath $ResolvedInstallRoot -Directory -Force)
  }

  foreach ($InstalledDirectory in $InstalledDirectories) {
    try {
      $Status = Get-OceansCatalogStateForSkill -CatalogRoot $CatalogRoot -SkillName $InstalledDirectory.Name
      if (-not $Status) {
        if ($TargetSkill) { $Errors.Add("Missing or invalid catalog state during reconciliation: $($InstalledDirectory.Name)") }
        continue
      }

      $IsReparsePoint = (($InstalledDirectory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
      $Marker = Join-Path $InstalledDirectory.FullName ".oceans-skill-source"
      $IsManaged = (-not $IsReparsePoint) -and (Test-ManagedMarker -MarkerPath $Marker -ExpectedSkill $InstalledDirectory.Name -ExpectedRoot $ResolvedInstallRoot)

      if ($Status -eq "blocked" -and -not $IsManaged) {
        $Errors.Add("Blocked skill has an unmanaged local copy that cannot be disabled automatically: $($InstalledDirectory.FullName)")
        continue
      }
      if (-not $IsManaged) { continue }

      switch ($Status) {
        { $_ -in @("archived", "blocked", "pending-review") } {
          Disable-ManagedSkill -SourcePath $InstalledDirectory.FullName -DisabledRoot $DisabledRoot -State $Status -SkillName $InstalledDirectory.Name
        }
        "deprecated" { Write-Host "Retained deprecated managed skill without updating: $($InstalledDirectory.Name)" }
      }
    } catch {
      $Errors.Add($_.Exception.Message)
    }
  }

  if ($Errors.Count -gt 0) {
    throw "runtime-reconcile-conflict:`n$($Errors -join [Environment]::NewLine)"
  }
}

function Report-PendingCatalogRecords {
  if (-not $CatalogEnabled) { return }
  if ($LifecycleReconcile -and -not $TargetSkill) { return }
  if ($TargetSkill) {
    $RecordPath = Get-OceansCatalogRecordPath -CatalogRoot $CatalogRoot -SkillName $TargetSkill
    if (Test-Path -LiteralPath $RecordPath -PathType Leaf) {
      $Record = Get-OceansCatalogRecord -Path $RecordPath
      if ([string]$Record["status"] -eq "pending-review") { Write-Host "Skipped pending-review skill: $TargetSkill" }
    }
    return
  }

  $SkillsDirectory = Join-Path $CatalogRoot "skills"
  if (-not (Test-Path -LiteralPath $SkillsDirectory -PathType Container)) { return }
  foreach ($RecordFile in @(Get-ChildItem -LiteralPath $SkillsDirectory -Filter '*.skill' -File | Sort-Object Name)) {
    $Record = Get-OceansCatalogRecord -Path $RecordFile.FullName
    if ([string]$Record["status"] -eq "pending-review") {
      Write-Host "Skipped pending-review skill: $([string]$Record['name'])"
    }
  }
}

function Test-CatalogAllowsInstall {
  param([string] $RepositoryName, [string] $SkillName)
  if (-not $CatalogEnabled) { return $true }
  $Status = Get-CatalogStatus -SkillName $SkillName
  $RecordPath = Get-OceansCatalogRecordPath -CatalogRoot $CatalogRoot -SkillName $SkillName
  $Record = Get-OceansCatalogRecord -Path $RecordPath
  if ([string]$Record["package_repository"] -cne $RepositoryName) {
    throw "Catalog repository mismatch for ${SkillName}: $([string]$Record['package_repository'])"
  }
  if ($Status -ne "active") {
    Write-Host "Skipped $Status skill: $SkillName"
    return $false
  }
  return $true
}

function Get-VerifiedSourceContentSha256 {
  param([string] $SkillPath, [string] $SkillName)
  $Actual = Get-OceansSkillContentSha256 -SkillPath $SkillPath
  $Expected = ""
  if ($CatalogEnabled) {
    $RecordPath = Get-OceansCatalogRecordPath -CatalogRoot $CatalogRoot -SkillName $SkillName
    $Record = Get-OceansCatalogRecord -Path $RecordPath
    $Expected = [string]$Record["content_sha256"]
  }
  if ($Expected) {
    if (-not (Test-OceansSha256 -Value $Expected)) { throw "Invalid published content SHA-256 for $SkillName" }
    if ($Actual -cne $Expected) { throw "Published package content SHA-256 mismatch for $SkillName. Expected $Expected, got $Actual" }
  } elseif ($LifecycleReconcile) {
    throw "Lifecycle reconciliation requires a published content SHA-256: $SkillName"
  } else {
    Write-Warning "Installing legacy package without catalog content SHA-256: $SkillName"
  }
  return $Actual
}

function Restore-RuntimeTarget {
  param(
    [Parameter(Mandatory = $true)][string] $TargetPath,
    [Parameter(Mandatory = $true)][string] $BackupPath,
    [Parameter(Mandatory = $true)][bool] $HadTarget
  )
  if ($HadTarget) {
    $RestoreStage = New-OceansStagingDirectory -TargetPath $TargetPath
    Get-ChildItem -LiteralPath $BackupPath -Force | Copy-Item -Destination $RestoreStage -Recurse -Force
    Complete-OceansDirectoryTransaction -StagingPath $RestoreStage -TargetPath $TargetPath
  } elseif (Test-Path -LiteralPath $TargetPath) {
    Remove-Item -LiteralPath $TargetPath -Recurse -Force
  }
}

function Install-OceansSkill {
  param(
    [Parameter(Mandatory = $true)] $Source,
    [Parameter(Mandatory = $true)] $SkillDirectory,
    [Parameter(Mandatory = $true)] $InstallTarget,
    [Parameter(Mandatory = $true)][string] $ResolvedInstallRoot
  )

  $SkillName = $SkillDirectory.Name
  if (-not (Test-CatalogAllowsInstall -RepositoryName $Source.Repository -SkillName $SkillName)) { return }
  $VerifiedContentSha256 = Get-VerifiedSourceContentSha256 -SkillPath $SkillDirectory.FullName -SkillName $SkillName
  $DisabledRoot = Get-ManagedDisabledRoot -ResolvedInstallRoot $ResolvedInstallRoot
  $RootPrefix = $ResolvedInstallRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  $Target = Join-Path $ResolvedInstallRoot $SkillName
  $ResolvedTarget = [System.IO.Path]::GetFullPath($Target)
  if (-not $ResolvedTarget.StartsWith($RootPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Refusing to install outside install root: $ResolvedTarget" }

  $IsUpdate = $false
  if (Test-Path -LiteralPath $Target) {
    $TargetItem = Get-Item -LiteralPath $Target -Force
    $Marker = Join-Path $Target ".oceans-skill-source"
    if (($TargetItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
        -not (Test-ManagedMarker -MarkerPath $Marker -ExpectedSkill $SkillName -ExpectedRoot $ResolvedInstallRoot)) {
      Write-Host "duplicate-local-wins: $SkillName"
      if ($LifecycleReconcile) { throw "Lifecycle restore cannot replace unmanaged local copy: $Target" }
      return
    }
    $ExistingSource = Get-MarkerValue -MarkerPath $Marker -Key "source_repository"
    if ($ExistingSource -ne $Source.Repository) {
      Write-Host "duplicate-managed-source-mismatch: $SkillName"
      if ($LifecycleReconcile) { throw "Lifecycle restore found a managed source mismatch: $Target" }
      return
    }
    $IsUpdate = $true
  }

  $BackupRoot = Join-Path ([System.IO.Path]::GetTempPath()) "oceans-runtime-backup-$([Guid]::NewGuid().ToString('N'))"
  $BackupPath = Join-Path $BackupRoot "package"
  $HadTarget = Test-Path -LiteralPath $Target -PathType Container
  New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null
  if ($HadTarget) {
    New-Item -ItemType Directory -Force -Path $BackupPath | Out-Null
    Get-ChildItem -LiteralPath $Target -Force | Copy-Item -Destination $BackupPath -Recurse -Force
  }

  $StagingPath = New-OceansStagingDirectory -TargetPath $Target
  $Committed = $false
  try {
    Get-ChildItem -LiteralPath $SkillDirectory.FullName -Force | Copy-Item -Destination $StagingPath -Recurse -Force
    Remove-OceansExcludedPaths -RootPath $StagingPath
    Set-OceansCanonicalSkillPermissions -SkillPath $StagingPath
    $StagedContentSha256 = Get-OceansSkillContentSha256 -SkillPath $StagingPath
    if ($StagedContentSha256 -cne $VerifiedContentSha256) { throw "Runtime staging content SHA-256 mismatch for $SkillName" }

    $MarkerPath = Join-Path $StagingPath ".oceans-skill-source"
    $CatalogUpdatedAt = ""
    if ($CatalogEnabled) {
      $RecordPath = Get-OceansCatalogRecordPath -CatalogRoot $CatalogRoot -SkillName $SkillName
      $Record = Get-OceansCatalogRecord -Path $RecordPath
      $CatalogUpdatedAt = [string]$Record["updated_at"]
    }
    $MarkerContent = @(
      "source_repository=$($Source.Repository)",
      "source_path=$($SkillDirectory.FullName)",
      "skill_name=$SkillName",
      "content_sha256=$StagedContentSha256",
      "runtime=$($InstallTarget.Runtime)",
      "install_root=$ResolvedInstallRoot",
      "catalog_status=active",
      "catalog_updated_at=$CatalogUpdatedAt"
    )
    [System.IO.File]::WriteAllLines($MarkerPath, $MarkerContent, (New-Object System.Text.UTF8Encoding($false)))
    Complete-OceansDirectoryTransaction -StagingPath $StagingPath -TargetPath $Target
    $Committed = $true

    $FinalContentSha256 = Get-OceansSkillContentSha256 -SkillPath $Target
    if ($FinalContentSha256 -cne $VerifiedContentSha256) {
      Restore-RuntimeTarget -TargetPath $Target -BackupPath $BackupPath -HadTarget $HadTarget
      $Committed = $false
      throw "Runtime content SHA-256 mismatch after commit for $SkillName; previous copy was restored."
    }
  } catch {
    if ($Committed) {
      try {
        Restore-RuntimeTarget -TargetPath $Target -BackupPath $BackupPath -HadTarget $HadTarget
        $Committed = $false
      } catch {
        throw "CRITICAL: failed to restore runtime copy after installation failure: $Target. $($_.Exception.Message)"
      }
    }
    if (Test-Path -LiteralPath $StagingPath) { Remove-Item -LiteralPath $StagingPath -Recurse -Force }
    throw "Failed to install $SkillName; existing installation was preserved or restored. $($_.Exception.Message)"
  } finally {
    if (Test-Path -LiteralPath $BackupRoot) { Remove-Item -LiteralPath $BackupRoot -Recurse -Force }
  }

  Remove-DisabledCopies -DisabledRoot $DisabledRoot -SkillName $SkillName
  if ($IsUpdate) { Write-Host "Updated managed oceans777 skill: $SkillName" }
  else { Write-Host "Installed skill: $SkillName" }
}

function Install-OceansSkillsFromSource {
  param(
    [Parameter(Mandatory = $true)] $Source,
    [Parameter(Mandatory = $true)] $InstallTarget,
    [Parameter(Mandatory = $true)][string] $ResolvedInstallRoot
  )
  if (-not (Test-Path -LiteralPath $Source.Path -PathType Container)) {
    Write-Host "Skipping missing source: $($Source.Path)"
    return
  }

  $SkillDirectories = if ($TargetSkill) {
    $TargetPath = Join-Path $Source.Path $TargetSkill
    if (Test-Path -LiteralPath $TargetPath -PathType Container) { @(Get-Item -LiteralPath $TargetPath -Force) } else { @() }
  } else {
    @(Get-ChildItem -LiteralPath $Source.Path -Directory)
  }

  foreach ($SkillDirectory in $SkillDirectories) {
    $SkillName = $SkillDirectory.Name
    if (-not (Test-OceansSkillName -Name $SkillName)) { throw "Invalid skill folder name in $($Source.Repository): $SkillName" }
    Install-OceansSkill -Source $Source -SkillDirectory $SkillDirectory -InstallTarget $InstallTarget -ResolvedInstallRoot $ResolvedInstallRoot
  }
}

$Failures = New-Object System.Collections.Generic.List[string]
foreach ($InstallTarget in $InstallTargets) {
  try {
    $InstallRootItem = New-Item -ItemType Directory -Force -Path $InstallTarget.Path
    if (($InstallRootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Install root must not be a reparse point: $($InstallTarget.Path)" }
    $ResolvedInstallRoot = [System.IO.Path]::GetFullPath($InstallRootItem.FullName)

    Reconcile-ManagedSkills -ResolvedInstallRoot $ResolvedInstallRoot
    Report-PendingCatalogRecords
    if (-not $ReconcileOnly) {
      foreach ($Source in $Sources) {
        Install-OceansSkillsFromSource -Source $Source -InstallTarget $InstallTarget -ResolvedInstallRoot $ResolvedInstallRoot
      }
      Write-Host "Install root: $ResolvedInstallRoot"
    } else {
      Write-Host "Reconciled lifecycle state for install root: $ResolvedInstallRoot"
    }
  } catch {
    $Failures.Add("$($InstallTarget.Path): $($_.Exception.Message)")
    if (-not $BestEffortRoots) { throw }
  }
}

if ($Failures.Count -gt 0) {
  throw "One or more runtime roots could not be reconciled:`n$($Failures -join [Environment]::NewLine)"
}
