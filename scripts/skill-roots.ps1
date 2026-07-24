param(
  [ValidateSet("list", "scan", "stage", "install", "install-default", "install-all-existing")]
  [string] $Mode = "list",

  [ValidateSet("codex", "agents", "claude", "openclaw", "hermes", "custom")]
  [string] $Runtime = "codex",

  [string] $SourceRoot,
  [string] $InstallRoot,
  [switch] $DefineOnly
)

$ErrorActionPreference = "Stop"

function Get-OceansHome {
  return [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
}

function Join-OceansPath {
  param([Parameter(Mandatory = $true)][string[]] $Parts)
  $Path = $Parts[0]
  for ($Index = 1; $Index -lt $Parts.Count; $Index++) {
    $Path = Join-Path $Path $Parts[$Index]
  }
  return $Path
}

function Get-OceansSkillRuntimeDefinitions {
  $UserHome = Get-OceansHome
  $ConfigHome = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-OceansPath -Parts @($UserHome, ".config") }
  @(
    [PSCustomObject]@{
      Runtime = "codex"
      CandidateRoots = if ($env:CODEX_HOME) { @(Join-Path $env:CODEX_HOME "skills") } else { @(Join-OceansPath -Parts @($UserHome, ".codex", "skills")) }
    },
    [PSCustomObject]@{
      Runtime = "agents"
      CandidateRoots = if ($env:AGENTS_HOME) { @(Join-Path $env:AGENTS_HOME "skills") } else { @(Join-OceansPath -Parts @($UserHome, ".agents", "skills")) }
    },
    [PSCustomObject]@{
      Runtime = "claude"
      CandidateRoots = if ($env:CLAUDE_HOME) { @(Join-Path $env:CLAUDE_HOME "skills") } else { @(Join-OceansPath -Parts @($UserHome, ".claude", "skills")) }
    },
    [PSCustomObject]@{
      Runtime = "openclaw"
      CandidateRoots = if ($env:OPENCLAW_HOME) {
        @(Join-Path $env:OPENCLAW_HOME "skills")
      } else {
        @(
          (Join-OceansPath -Parts @($UserHome, ".openclaw", "skills")),
          (Join-OceansPath -Parts @($ConfigHome, "openclaw", "skills"))
        )
      }
    },
    [PSCustomObject]@{
      Runtime = "hermes"
      CandidateRoots = if ($env:HERMES_HOME) {
        @(Join-Path $env:HERMES_HOME "skills")
      } else {
        @(
          (Join-OceansPath -Parts @($UserHome, ".hermes", "skills")),
          (Join-OceansPath -Parts @($ConfigHome, "hermes", "skills"))
        )
      }
    }
  )
}

function Resolve-OceansRootPath {
  param([Parameter(Mandatory = $true)][string] $Path)
  if (Test-Path -LiteralPath $Path) {
    return [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).Path)
  }
  return [System.IO.Path]::GetFullPath($Path)
}

function Get-OceansPathComparer {
  if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
    return [System.StringComparer]::OrdinalIgnoreCase
  }
  return [System.StringComparer]::Ordinal
}

function Get-OceansRuntimeRegistryPath {
  if ($env:OCEANS_RUNTIME_ROOTS_FILE) {
    return [System.IO.Path]::GetFullPath($env:OCEANS_RUNTIME_ROOTS_FILE)
  }
  if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
    $StateHome = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path (Get-OceansHome) "AppData\Local" }
  } else {
    $StateHome = if ($env:XDG_STATE_HOME) { $env:XDG_STATE_HOME } else { Join-OceansPath -Parts @((Get-OceansHome), ".local", "state") }
  }
  return Join-OceansPath -Parts @($StateHome, "oceans777-skills", "runtime-roots")
}

function Test-OceansSafeRuntimeRecordValue {
  param([AllowEmptyString()][string] $Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
  return -not ($Value.Contains("|") -or $Value.IndexOfAny([char[]]"`r`n") -ge 0)
}

function Register-OceansSkillRoot {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("codex", "agents", "claude", "openclaw", "hermes", "custom")]
    [string] $Runtime,
    [Parameter(Mandatory = $true)][string] $Path
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Cannot register missing runtime root: $Path" }
  $RootItem = Get-Item -LiteralPath $Path -Force
  if (($RootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Cannot register reparse-point runtime root: $Path" }
  $ResolvedPath = Resolve-OceansRootPath -Path $RootItem.FullName
  if (-not (Test-OceansSafeRuntimeRecordValue -Value $ResolvedPath)) { throw "Runtime root contains unsupported characters: $ResolvedPath" }

  $RegistryPath = Get-OceansRuntimeRegistryPath
  $RegistryParent = Split-Path -Parent $RegistryPath
  New-Item -ItemType Directory -Force -Path $RegistryParent | Out-Null
  $RegistryParentItem = Get-Item -LiteralPath $RegistryParent -Force
  if (($RegistryParentItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Runtime registry parent must not be a reparse point: $RegistryParent" }
  if (Test-Path -LiteralPath $RegistryPath) {
    $RegistryItem = Get-Item -LiteralPath $RegistryPath -Force
    if ($RegistryItem.PSIsContainer -or ($RegistryItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Runtime registry must be a regular file: $RegistryPath"
    }
  }

  $LockPath = "$RegistryPath.lock"
  try {
    New-Item -ItemType Directory -Path $LockPath -ErrorAction Stop | Out-Null
  } catch {
    throw "Another runtime registry update is active: $RegistryPath"
  }

  $TempPath = Join-Path $RegistryParent ".runtime-roots.$([Guid]::NewGuid().ToString('N'))"
  try {
    $Comparer = Get-OceansPathComparer
    $Records = @()
    if (Test-Path -LiteralPath $RegistryPath -PathType Leaf) {
      foreach ($Line in @(Get-Content -LiteralPath $RegistryPath)) {
        if ([string]::IsNullOrWhiteSpace($Line)) { continue }
        $Parts = $Line -split '\|', 3
        if ($Parts.Count -ne 2) { throw "Malformed runtime registry record: $RegistryPath" }
        $ExistingRuntime = $Parts[0]
        $ExistingPath = $Parts[1]
        if ($ExistingRuntime -notin @("codex", "agents", "claude", "openclaw", "hermes", "custom")) { throw "Malformed runtime registry runtime: $ExistingRuntime" }
        if (-not (Test-OceansSafeRuntimeRecordValue -Value $ExistingPath)) { throw "Malformed runtime registry path." }
        if (-not $Comparer.Equals($ExistingPath, $ResolvedPath)) {
          $Records += "$ExistingRuntime|$ExistingPath"
        }
      }
    }
    $Records += "$Runtime|$ResolvedPath"
    [System.IO.File]::WriteAllLines($TempPath, @($Records | Sort-Object -Unique), (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $TempPath -Destination $RegistryPath -Force
  } finally {
    if (Test-Path -LiteralPath $TempPath) { Remove-Item -LiteralPath $TempPath -Force }
    if (Test-Path -LiteralPath $LockPath -PathType Container) { Remove-Item -LiteralPath $LockPath -Recurse -Force }
  }
}

function Get-OceansRegisteredSkillRoots {
  $RegistryPath = Get-OceansRuntimeRegistryPath
  if (-not (Test-Path -LiteralPath $RegistryPath -PathType Leaf)) { return }
  $RegistryItem = Get-Item -LiteralPath $RegistryPath -Force
  if (($RegistryItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Runtime registry must not be a reparse point: $RegistryPath" }

  foreach ($Line in @(Get-Content -LiteralPath $RegistryPath)) {
    if ([string]::IsNullOrWhiteSpace($Line)) { continue }
    $Parts = $Line -split '\|', 3
    if ($Parts.Count -ne 2) { throw "Malformed runtime registry record: $RegistryPath" }
    $RegisteredRuntime = $Parts[0]
    $RegisteredPath = $Parts[1]
    if ($RegisteredRuntime -notin @("codex", "agents", "claude", "openclaw", "hermes", "custom")) { throw "Malformed runtime registry runtime: $RegisteredRuntime" }
    if (-not (Test-OceansSafeRuntimeRecordValue -Value $RegisteredPath)) { throw "Malformed runtime registry path." }
    if (-not (Test-Path -LiteralPath $RegisteredPath -PathType Container)) { continue }
    $Item = Get-Item -LiteralPath $RegisteredPath -Force
    if (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
    Write-Output ([PSCustomObject]@{
      Runtime = $RegisteredRuntime
      Status = "exists"
      Path = (Resolve-OceansRootPath -Path $Item.FullName)
      Reason = "registered runtime skills root"
    })
  }
}

function Get-OceansSkillRootCandidates {
  foreach ($Definition in Get-OceansSkillRuntimeDefinitions) {
    $Seen = [System.Collections.Generic.HashSet[string]]::new((Get-OceansPathComparer))
    foreach ($CandidateRoot in $Definition.CandidateRoots) {
      $ResolvedPath = Resolve-OceansRootPath -Path $CandidateRoot
      if (-not $Seen.Add($ResolvedPath)) { continue }
      $Exists = Test-Path -LiteralPath $ResolvedPath -PathType Container
      Write-Output ([PSCustomObject]@{
        Runtime = $Definition.Runtime
        Status = if ($Exists) { "exists" } else { "missing" }
        Path = $ResolvedPath
        Reason = if ($Exists) { "runtime skills root exists" } else { "runtime skills root not found" }
      })
    }
  }
}

function Get-OceansExistingSkillRoots {
  $Seen = [System.Collections.Generic.HashSet[string]]::new((Get-OceansPathComparer))
  foreach ($Root in @(Get-OceansSkillRootCandidates | Where-Object { $_.Status -eq "exists" })) {
    if ($Seen.Add([string]$Root.Path)) { Write-Output $Root }
  }
  foreach ($Root in @(Get-OceansRegisteredSkillRoots)) {
    if ($Seen.Add([string]$Root.Path)) { Write-Output $Root }
  }
}

function Get-OceansRuntimeRoot {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("codex", "agents", "claude", "openclaw", "hermes", "custom")]
    [string] $Runtime,
    [string] $Path,
    [string] $Operation = "scan",
    [switch] $Create
  )

  if ($Path) {
    if ($Create) { New-Item -ItemType Directory -Force -Path $Path | Out-Null }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "skill-root-missing: $Path" }
    $Item = Get-Item -LiteralPath $Path -Force
    if (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "skill-root-reparse-point: $Path" }
    return [PSCustomObject]@{ Runtime = "custom"; Status = "exists"; Path = (Resolve-OceansRootPath -Path $Path); Reason = "explicit path" }
  }

  if ($Runtime -eq "custom") { throw "custom-runtime-requires-path" }
  $Candidates = @(Get-OceansSkillRootCandidates | Where-Object { $_.Runtime -eq $Runtime })
  $Existing = @($Candidates | Where-Object { $_.Status -eq "exists" } | Select-Object -First 1)
  if ($Existing.Count -gt 0) { return $Existing[0] }

  if ($Create) {
    $Root = $Candidates[0]
    New-Item -ItemType Directory -Force -Path $Root.Path | Out-Null
    return [PSCustomObject]@{ Runtime = $Runtime; Status = "exists"; Path = (Resolve-OceansRootPath -Path $Root.Path); Reason = "created runtime skills root" }
  }
  throw "skill-root-missing: $Runtime"
}

function Write-OceansSkillRootRecord {
  param([Parameter(Mandatory = $true)] $Root)
  Write-Host "runtime: $($Root.Runtime)"
  Write-Host "status: $($Root.Status)"
  Write-Host "path: $($Root.Path)"
  Write-Host "reason: $($Root.Reason)"
}

if ($DefineOnly) { return }

switch ($Mode) {
  "list" {
    foreach ($Root in @(Get-OceansSkillRootCandidates)) { Write-OceansSkillRootRecord -Root $Root; Write-Host "" }
    foreach ($Root in @(Get-OceansRegisteredSkillRoots)) { Write-OceansSkillRootRecord -Root $Root; Write-Host "" }
  }
  "scan" {
    if ($SourceRoot) {
      Write-OceansSkillRootRecord -Root (Get-OceansRuntimeRoot -Runtime "custom" -Path $SourceRoot -Operation "scan")
    } else {
      foreach ($Root in @(Get-OceansExistingSkillRoots)) { Write-OceansSkillRootRecord -Root $Root; Write-Host "" }
    }
  }
  "stage" { Write-OceansSkillRootRecord -Root (Get-OceansRuntimeRoot -Runtime $Runtime -Path $SourceRoot -Operation "stage") }
  "install" { Write-OceansSkillRootRecord -Root (Get-OceansRuntimeRoot -Runtime $Runtime -Path $InstallRoot -Operation "install" -Create) }
  "install-default" { Write-OceansSkillRootRecord -Root (Get-OceansRuntimeRoot -Runtime "codex" -Operation "install" -Create) }
  "install-all-existing" {
    foreach ($Root in @(Get-OceansExistingSkillRoots)) { Write-OceansSkillRootRecord -Root $Root; Write-Host "" }
  }
}
