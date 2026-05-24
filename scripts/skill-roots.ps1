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
  $ConfigHome = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { (Join-OceansPath -Parts @($UserHome, ".config")) }
  @(
    [PSCustomObject]@{
      Runtime = "codex"
      EnvName = "CODEX_HOME"
      CandidateRoots = if ($env:CODEX_HOME) { @(Join-Path $env:CODEX_HOME "skills") } else { @((Join-OceansPath -Parts @($UserHome, ".codex", "skills"))) }
    },
    [PSCustomObject]@{
      Runtime = "agents"
      EnvName = "AGENTS_HOME"
      CandidateRoots = if ($env:AGENTS_HOME) { @(Join-Path $env:AGENTS_HOME "skills") } else { @((Join-OceansPath -Parts @($UserHome, ".agents", "skills"))) }
    },
    [PSCustomObject]@{
      Runtime = "claude"
      EnvName = "CLAUDE_HOME"
      CandidateRoots = if ($env:CLAUDE_HOME) { @(Join-Path $env:CLAUDE_HOME "skills") } else { @((Join-OceansPath -Parts @($UserHome, ".claude", "skills"))) }
    },
    [PSCustomObject]@{
      Runtime = "openclaw"
      EnvName = "OPENCLAW_HOME"
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
      EnvName = "HERMES_HOME"
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

function Get-OceansSkillRootCandidates {
  $Roots = New-Object System.Collections.Generic.List[object]

  foreach ($Definition in Get-OceansSkillRuntimeDefinitions) {
    $Seen = New-Object System.Collections.Generic.HashSet[string]
    foreach ($CandidateRoot in $Definition.CandidateRoots) {
      $ResolvedPath = Resolve-OceansRootPath -Path $CandidateRoot
      if (-not $Seen.Add($ResolvedPath)) {
        continue
      }

      $Exists = Test-Path -LiteralPath $ResolvedPath -PathType Container
      $Roots.Add([PSCustomObject]@{
        Runtime = $Definition.Runtime
        Status = if ($Exists) { "exists" } else { "missing" }
        Path = $ResolvedPath
        Reason = if ($Exists) { "runtime skills root exists" } else { "runtime skills root not found" }
      })
    }
  }

  return $Roots
}

function Get-OceansExistingSkillRoots {
  return @(Get-OceansSkillRootCandidates | Where-Object { $_.Status -eq "exists" })
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
    if ($Create) {
      New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
      throw "skill-root-missing: $Path"
    }
    return [PSCustomObject]@{
      Runtime = "custom"
      Status = "exists"
      Path = (Resolve-OceansRootPath -Path $Path)
      Reason = "explicit path"
    }
  }

  if ($Runtime -eq "custom") {
    throw "custom-runtime-requires-path"
  }

  $Candidates = @(Get-OceansSkillRootCandidates | Where-Object { $_.Runtime -eq $Runtime })
  $Existing = @($Candidates | Where-Object { $_.Status -eq "exists" } | Select-Object -First 1)
  if ($Existing.Count -gt 0) {
    return $Existing[0]
  }

  if ($Create) {
    $Root = $Candidates[0]
    New-Item -ItemType Directory -Force -Path $Root.Path | Out-Null
    return [PSCustomObject]@{
      Runtime = $Runtime
      Status = "exists"
      Path = (Resolve-OceansRootPath -Path $Root.Path)
      Reason = "created runtime skills root"
    }
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

if ($DefineOnly) {
  return
}

switch ($Mode) {
  "list" {
    foreach ($Root in Get-OceansSkillRootCandidates) {
      Write-OceansSkillRootRecord -Root $Root
      Write-Host ""
    }
  }
  "scan" {
    if ($SourceRoot) {
      Write-OceansSkillRootRecord -Root (Get-OceansRuntimeRoot -Runtime "custom" -Path $SourceRoot -Operation "scan")
    } else {
      foreach ($Root in Get-OceansExistingSkillRoots) {
        Write-OceansSkillRootRecord -Root $Root
        Write-Host ""
      }
    }
  }
  "stage" {
    Write-OceansSkillRootRecord -Root (Get-OceansRuntimeRoot -Runtime $Runtime -Path $SourceRoot -Operation "stage")
  }
  "install" {
    Write-OceansSkillRootRecord -Root (Get-OceansRuntimeRoot -Runtime $Runtime -Path $InstallRoot -Operation "install" -Create)
  }
  "install-default" {
    Write-OceansSkillRootRecord -Root (Get-OceansRuntimeRoot -Runtime "codex" -Operation "install" -Create)
  }
  "install-all-existing" {
    foreach ($Root in Get-OceansExistingSkillRoots) {
      Write-OceansSkillRootRecord -Root $Root
      Write-Host ""
    }
  }
}
