param(
  [string] $InstallRoot
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

if (-not $InstallRoot) {
  if ($env:CODEX_HOME) {
    $InstallRoot = Join-Path $env:CODEX_HOME "skills"
  } else {
    $InstallRoot = Join-Path $HOME ".codex\skills"
  }
}

$InstallRootItem = New-Item -ItemType Directory -Force -Path $InstallRoot
$ResolvedInstallRoot = [System.IO.Path]::GetFullPath($InstallRootItem.FullName)
if (-not $ResolvedInstallRoot.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
  $ResolvedInstallRoot += [System.IO.Path]::DirectorySeparatorChar
}

$Sources = @(
  @{ Repository = "oceans-skills"; Path = Join-Path $RepoRoot "repos\oceans-skills\skills" },
  @{ Repository = "community-skills"; Path = Join-Path $RepoRoot "repos\community-skills\skills" }
)

function Get-SourceRepository {
  param([string] $MarkerPath)

  $Line = Get-Content -LiteralPath $MarkerPath -ErrorAction SilentlyContinue |
    Where-Object { $_ -like "source_repository=*" } |
    Select-Object -First 1

  if (-not $Line) {
    return "unknown"
  }

  return $Line.Substring("source_repository=".Length)
}

function Test-KnownOceansSource {
  param([string] $Repository)

  return $Repository -eq "oceans-skills" -or $Repository -eq "community-skills"
}

foreach ($Source in $Sources) {
  if (-not (Test-Path $Source.Path)) {
    Write-Host "Skipping missing source: $($Source.Path)"
    continue
  }

  Get-ChildItem -Path $Source.Path -Directory | ForEach-Object {
    $SkillName = $_.Name
    $Target = Join-Path $InstallRoot $SkillName
    $ResolvedTarget = [System.IO.Path]::GetFullPath($Target)

    if (-not $ResolvedTarget.StartsWith($ResolvedInstallRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Refusing to install outside install root: $ResolvedTarget"
    }

    $ShouldInstall = $true
    $IsUpdate = $false
    if (Test-Path -LiteralPath $Target) {
      $Marker = Join-Path $Target ".oceans-skill-source"
      if (-not (Test-Path -LiteralPath $Marker)) {
        Write-Host "duplicate-local-wins: $SkillName"
        $ShouldInstall = $false
      } else {
        $ExistingSource = Get-SourceRepository -MarkerPath $Marker
        if (-not (Test-KnownOceansSource -Repository $ExistingSource)) {
          Write-Host "duplicate-unknown-marker: $SkillName"
          $ShouldInstall = $false
        } else {
          Remove-Item -LiteralPath $Target -Recurse -Force
          $IsUpdate = $true
        }
      }
    }

    if ($ShouldInstall) {
      Copy-Item -LiteralPath $_.FullName -Destination $Target -Recurse

      $MarkerContent = @(
        "source_repository=$($Source.Repository)"
        "source_path=$($_.FullName)"
      )
      Set-Content -LiteralPath (Join-Path $Target ".oceans-skill-source") -Value $MarkerContent -Encoding UTF8
      if ($IsUpdate) {
        Write-Host "Updated managed oceans777 skill: $SkillName"
      } else {
        Write-Host "Installed skill: $SkillName"
      }
    }
  }
}

Write-Host "Install root: $InstallRoot"
