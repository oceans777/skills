param(
  [string] $InstallRoot,
  [ValidateSet("codex", "agents", "claude", "openclaw", "hermes", "custom")]
  [string] $Runtime = "codex",
  [switch] $AllExistingRuntimes,
  [string] $FirstPartySkillsRoot,
  [string] $CommunitySkillsRoot,
  [string] $CatalogRoot,
  [switch] $WithoutCatalog
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
$CatalogEnabled = -not $WithoutCatalog

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
if ($InstallTargets.Count -eq 0) { throw "No existing runtime skill roots found for install." }

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
  foreach ($InstalledDirectory in @(Get-ChildItem -LiteralPath $ResolvedInstallRoot -Directory -Force)) {
    if (($InstalledDirectory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
    $Marker = Join-Path $InstalledDirectory.FullName ".oceans-skill-source"
    if (-not (Test-Path -LiteralPath $Marker -PathType Leaf)) { continue }
    $SourceRepository = Get-MarkerValue -MarkerPath $Marker -Key "source_repository"
    if (-not (Test-KnownOceansSource -Repository $SourceRepository)) { continue }
    try { $Status = Get-CatalogStatus -SkillName $InstalledDirectory.Name } catch { Write-Warning $_; continue }
    switch ($Status) {
      { $_ -in @("archived", "blocked", "pending-review") } {
        Disable-ManagedSkill -SourcePath $InstalledDirectory.FullName -DisabledRoot $DisabledRoot -State $Status -SkillName $InstalledDirectory.Name
      }
      "deprecated" { Write-Host "Retained deprecated managed skill without updating: $($InstalledDirectory.Name)" }
    }
  }
}

function Report-PendingCatalogRecords {
  if (-not $CatalogEnabled) { return }
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

function Install-OceansSkillsToRoot {
  param([Parameter(Mandatory = $true)] $InstallTarget)

  $InstallRootItem = New-Item -ItemType Directory -Force -Path $InstallTarget.Path
  if (($InstallRootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Install root must not be a reparse point: $($InstallTarget.Path)" }
  $ResolvedInstallRoot = [System.IO.Path]::GetFullPath($InstallRootItem.FullName)
  $RootPrefix = $ResolvedInstallRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  $DisabledRoot = Get-ManagedDisabledRoot -ResolvedInstallRoot $ResolvedInstallRoot

  Reconcile-ManagedSkills -ResolvedInstallRoot $ResolvedInstallRoot
  Report-PendingCatalogRecords
  foreach ($Source in $Sources) {
    if (-not (Test-Path -LiteralPath $Source.Path -PathType Container)) { Write-Host "Skipping missing source: $($Source.Path)"; continue }
    foreach ($SkillDirectory in @(Get-ChildItem -LiteralPath $Source.Path -Directory)) {
      $SkillName = $SkillDirectory.Name
      if (-not (Test-OceansSkillName -Name $SkillName)) { throw "Invalid skill folder name in $($Source.Repository): $SkillName" }
      if (-not (Test-CatalogAllowsInstall -RepositoryName $Source.Repository -SkillName $SkillName)) { continue }

      $Target = Join-Path $ResolvedInstallRoot $SkillName
      $ResolvedTarget = [System.IO.Path]::GetFullPath($Target)
      if (-not $ResolvedTarget.StartsWith($RootPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Refusing to install outside install root: $ResolvedTarget" }

      $ShouldInstall = $true
      $IsUpdate = $false
      if (Test-Path -LiteralPath $Target) {
        $TargetItem = Get-Item -LiteralPath $Target -Force
        if (($TargetItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
          Write-Host "duplicate-local-wins: $SkillName"
          $ShouldInstall = $false
        }
        $Marker = Join-Path $Target ".oceans-skill-source"
        if ($ShouldInstall -and -not (Test-Path -LiteralPath $Marker -PathType Leaf)) {
          Write-Host "duplicate-local-wins: $SkillName"
          $ShouldInstall = $false
        } elseif ($ShouldInstall) {
          $ExistingSource = Get-MarkerValue -MarkerPath $Marker -Key "source_repository"
          if (-not (Test-KnownOceansSource -Repository $ExistingSource)) {
            Write-Host "duplicate-unknown-marker: $SkillName"
            $ShouldInstall = $false
          } elseif ($ExistingSource -ne $Source.Repository) {
            Write-Host "duplicate-managed-source-mismatch: $SkillName"
            $ShouldInstall = $false
          } else { $IsUpdate = $true }
        }
      }

      if ($ShouldInstall) {
        $StagingPath = New-OceansStagingDirectory -TargetPath $Target
        try {
          Get-ChildItem -LiteralPath $SkillDirectory.FullName -Force | Copy-Item -Destination $StagingPath -Recurse -Force
          Remove-OceansExcludedPaths -RootPath $StagingPath
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
            "runtime=$($InstallTarget.Runtime)",
            "install_root=$ResolvedInstallRoot",
            "catalog_status=active",
            "catalog_updated_at=$CatalogUpdatedAt"
          )
          [System.IO.File]::WriteAllLines($MarkerPath, $MarkerContent, (New-Object System.Text.UTF8Encoding($false)))
          Complete-OceansDirectoryTransaction -StagingPath $StagingPath -TargetPath $Target
        } catch {
          if (Test-Path -LiteralPath $StagingPath) { Remove-Item -LiteralPath $StagingPath -Recurse -Force }
          throw "Failed to install $SkillName; existing installation was preserved or restored. $($_.Exception.Message)"
        }
        Remove-DisabledCopies -DisabledRoot $DisabledRoot -SkillName $SkillName
        if ($IsUpdate) { Write-Host "Updated managed oceans777 skill: $SkillName" }
        else { Write-Host "Installed skill: $SkillName" }
      }
    }
  }
  Write-Host "Install root: $ResolvedInstallRoot"
}

foreach ($InstallTarget in $InstallTargets) { Install-OceansSkillsToRoot -InstallTarget $InstallTarget }
