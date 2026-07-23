param(
  [string] $InstallRoot,
  [ValidateSet("codex", "agents", "claude", "openclaw", "hermes", "custom")]
  [string] $Runtime = "codex",
  [switch] $AllExistingRuntimes,
  [string] $FirstPartySkillsRoot,
  [string] $CommunitySkillsRoot,
  [string] $CatalogRoot
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
$CatalogEnabled = -not ($CustomSourceRoots -and -not $CatalogExplicit)

try {
  $ValidationArguments = @{
    FirstPartySkillsRoot = $FirstPartySkillsRoot
    CommunitySkillsRoot = $CommunitySkillsRoot
  }
  if ($CatalogEnabled) { $ValidationArguments.CatalogRoot = $CatalogRoot }
  & (Join-Path $ScriptRoot "validate-skills.ps1") @ValidationArguments | Out-Null
} catch {
  throw "Refusing to install from an invalid or unsafe skill repository. $($_.Exception.Message)"
}

$Sources = @(
  @{ Repository = "oceans-skills"; Path = $FirstPartySkillsRoot },
  @{ Repository = "community-skills"; Path = $CommunitySkillsRoot }
)

if ($InstallRoot) {
  $InstallTargets = @(Get-OceansRuntimeRoot -Runtime "custom" -Path $InstallRoot -Operation "install" -Create)
} elseif ($AllExistingRuntimes) {
  $InstallTargets = @(Get-OceansExistingSkillRoots)
} else {
  $InstallTargets = @(Get-OceansRuntimeRoot -Runtime $Runtime -Operation "install" -Create)
}
if ($InstallTargets.Count -eq 0) { throw "No existing runtime skill roots found for install." }

function Get-SourceRepository {
  param([string] $MarkerPath)
  $Line = Get-Content -LiteralPath $MarkerPath -ErrorAction SilentlyContinue |
    Where-Object { $_ -like "source_repository=*" } | Select-Object -First 1
  if (-not $Line) { return "unknown" }
  return $Line.Substring("source_repository=".Length)
}

function Test-KnownOceansSource {
  param([string] $Repository)
  return $Repository -eq "oceans-skills" -or $Repository -eq "community-skills"
}

function Test-CatalogAllowsInstall {
  param([string] $RepositoryName, [string] $SkillName)
  if (-not $CatalogEnabled) { return $true }
  try {
    $State = Get-OceansCatalogStateForSkill -CatalogRoot $CatalogRoot -SkillName $SkillName
  } catch {
    throw "Skill exists in multiple catalog states: $SkillName"
  }
  if (-not $State) { throw "Missing catalog record: $SkillName" }
  $RecordPath = Get-OceansCatalogRecordPath -CatalogRoot $CatalogRoot -State $State -SkillName $SkillName
  $Record = Get-OceansCatalogRecord -Path $RecordPath
  if ([string]$Record["repository"] -cne $RepositoryName) {
    throw "Catalog repository mismatch for ${SkillName}: $([string]$Record['repository'])"
  }
  if ($State -ne "active") {
    Write-Host "Skipped $State skill: $SkillName"
    return $false
  }
  return $true
}

function Install-OceansSkillsToRoot {
  param([Parameter(Mandatory = $true)] $InstallTarget)

  $InstallRootItem = New-Item -ItemType Directory -Force -Path $InstallTarget.Path
  $ResolvedInstallRoot = [System.IO.Path]::GetFullPath($InstallRootItem.FullName)
  if (-not $ResolvedInstallRoot.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
    $ResolvedInstallRoot += [System.IO.Path]::DirectorySeparatorChar
  }

  foreach ($Source in $Sources) {
    if (-not (Test-Path $Source.Path)) { Write-Host "Skipping missing source: $($Source.Path)"; continue }

    foreach ($SkillDirectory in @(Get-ChildItem -Path $Source.Path -Directory)) {
      $SkillName = $SkillDirectory.Name
      if (-not (Test-OceansSkillName -Name $SkillName)) { throw "Invalid skill folder name in $($Source.Repository): $SkillName" }
      if (-not (Test-CatalogAllowsInstall -RepositoryName $Source.Repository -SkillName $SkillName)) { continue }

      $Target = Join-Path $InstallTarget.Path $SkillName
      $ResolvedTarget = [System.IO.Path]::GetFullPath($Target)
      if (-not $ResolvedTarget.StartsWith($ResolvedInstallRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to install outside install root: $ResolvedTarget"
      }

      $ShouldInstall = $true
      $IsUpdate = $false
      if (Test-Path -LiteralPath $Target) {
        $TargetItem = Get-Item -LiteralPath $Target -Force
        if (($TargetItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
          Write-Host "duplicate-local-wins: $SkillName"
          $ShouldInstall = $false
        }
        $Marker = Join-Path $Target ".oceans-skill-source"
        if ($ShouldInstall -and -not (Test-Path -LiteralPath $Marker)) {
          Write-Host "duplicate-local-wins: $SkillName"
          $ShouldInstall = $false
        } elseif ($ShouldInstall) {
          $ExistingSource = Get-SourceRepository -MarkerPath $Marker
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
          $CopiedMarker = Join-Path $StagingPath ".oceans-skill-source"
          if (Test-Path -LiteralPath $CopiedMarker) { Remove-Item -LiteralPath $CopiedMarker -Force }
          $MarkerContent = @(
            "source_repository=$($Source.Repository)", "source_path=$($SkillDirectory.FullName)",
            "runtime=$($InstallTarget.Runtime)", "install_root=$($InstallTarget.Path)"
          )
          [System.IO.File]::WriteAllLines($CopiedMarker, $MarkerContent, (New-Object System.Text.UTF8Encoding($false)))
          Complete-OceansDirectoryTransaction -StagingPath $StagingPath -TargetPath $Target
        } catch {
          if (Test-Path -LiteralPath $StagingPath) { Remove-Item -LiteralPath $StagingPath -Recurse -Force }
          throw "Failed to install $SkillName; existing installation was preserved or restored. $($_.Exception.Message)"
        }
        if ($IsUpdate) { Write-Host "Updated managed oceans777 skill: $SkillName" }
        else { Write-Host "Installed skill: $SkillName" }
      }
    }
  }
  Write-Host "Install root: $($InstallTarget.Path)"
}

foreach ($InstallTarget in $InstallTargets) { Install-OceansSkillsToRoot -InstallTarget $InstallTarget }
