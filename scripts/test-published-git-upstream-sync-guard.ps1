$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
. (Join-Path $RepoRoot "scripts\skill-content-hash.ps1")
$CanonicalTemp = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $env:TEMP).Path)
$TestRoot = Join-Path $CanonicalTemp ("oceans-published-git-upstream-sync-guard-" + [Guid]::NewGuid().ToString("N"))

function Assert-PathExists([string] $Path) {
  if (-not (Test-Path -LiteralPath $Path)) { throw "Expected path to exist: $Path" }
}
function Assert-PathMissing([string] $Path) {
  if (Test-Path -LiteralPath $Path) { throw "Expected path to be absent: $Path" }
}
function Assert-FileContains([string] $Path, [string] $Expected) {
  $Text = Get-Content -LiteralPath $Path -Raw
  if (-not $Text.Contains($Expected)) { throw "Expected $Path to contain: $Expected" }
}
function Remove-TestRoot {
  if (-not (Test-Path -LiteralPath $TestRoot)) { return }
  $ResolvedRoot = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $TestRoot).Path)
  $Prefix = $CanonicalTemp.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  if (-not $ResolvedRoot.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase) -or
      -not (Split-Path -Leaf $ResolvedRoot).StartsWith("oceans-published-git-upstream-sync-guard-")) {
    throw "Unsafe cleanup target: $ResolvedRoot"
  }
  Remove-Item -LiteralPath $ResolvedRoot -Recurse -Force
}

try {
  $SkillName = "fork-skill"
  $PublishedSkill = Join-Path $RepoRoot "repos\$SkillName"
  $CatalogRecord = Join-Path $RepoRoot "catalog\skills\$SkillName.skill"
  $ContentSha256 = Get-OceansSkillContentSha256 -SkillPath $PublishedSkill
  Write-Host "$SkillName-content-sha256=$ContentSha256"
  Assert-FileContains $CatalogRecord "status=active"
  Assert-FileContains $CatalogRecord "content_sha256=$ContentSha256"
  Assert-FileContains (Join-Path $RepoRoot "catalog\skills\git-upstream-sync-guard.skill") "status=archived"
  Assert-FileContains (Join-Path $RepoRoot "catalog\skills\git-upstream-sync-guard.skill") "replacement=fork-skill"
  Assert-FileContains (Join-Path $RepoRoot "catalog\skills\prd-skill.skill") "status=active"
  Assert-FileContains (Join-Path $RepoRoot "catalog\skills\prd-blueprint.skill") "status=archived"
  Assert-FileContains (Join-Path $RepoRoot "catalog\skills\prd-blueprint.skill") "replacement=prd-skill"

  foreach ($Archived in @("agent-operating-system","discuz-x5","experience-triage","idea-ledger","ui-ux-pro-max","git-upstream-sync-guard","prd-blueprint")) {
    Assert-FileContains (Join-Path $RepoRoot "catalog\skills\$Archived.skill") "status=archived"
  }

  New-Item -ItemType Directory -Force -Path $TestRoot | Out-Null
  $env:CODEX_HOME = Join-Path $TestRoot "codex"
  $env:AGENTS_HOME = Join-Path $TestRoot "agents"
  $env:CLAUDE_HOME = Join-Path $TestRoot "claude"
  $env:OPENCLAW_HOME = Join-Path $TestRoot "openclaw"
  $env:HERMES_HOME = Join-Path $TestRoot "hermes"
  $env:HOME = Join-Path $TestRoot "home"
  $env:PYTHONIOENCODING = "utf-8"
  $env:PYTHONUTF8 = "1"

  $Targets = @(
    [PSCustomObject]@{ Runtime = "codex"; Root = Join-Path $env:CODEX_HOME "skills" },
    [PSCustomObject]@{ Runtime = "agents"; Root = Join-Path $env:AGENTS_HOME "skills" },
    [PSCustomObject]@{ Runtime = "claude"; Root = Join-Path $env:CLAUDE_HOME "skills" },
    [PSCustomObject]@{ Runtime = "openclaw"; Root = Join-Path $env:OPENCLAW_HOME "skills" },
    [PSCustomObject]@{ Runtime = "hermes"; Root = Join-Path $env:HERMES_HOME "skills" }
  )
  foreach ($Target in $Targets) {
    New-Item -ItemType Directory -Force -Path $Target.Root | Out-Null
  }

  $InstallText = (& (Join-Path $RepoRoot "scripts\install-skills.ps1") -AllExistingRuntimes *>&1 | Out-String)
  if (-not $InstallText.Contains("Installed skill: $SkillName")) {
    throw "Expected installer to install $SkillName"
  }
  if (-not $InstallText.Contains("Installed skill: prd-skill")) {
    throw "Expected installer to install prd-skill"
  }

  foreach ($Target in $Targets) {
    $Skill = Join-Path $Target.Root $SkillName
    $Marker = Join-Path $Skill ".oceans-skill-source"
    Assert-PathExists (Join-Path $Skill "SKILL.md")
    Assert-PathExists (Join-Path $Skill "README.md")
    Assert-PathExists (Join-Path $Skill "references\operating-contract.md")
    Assert-PathExists (Join-Path $Skill "scripts\init-upstream.ps1")
    Assert-PathExists (Join-Path $Skill "scripts\sync-upstream.ps1")
    Assert-FileContains (Join-Path $Skill "SKILL.md") "name: fork-skill"
    Assert-FileContains (Join-Path $Skill "SKILL.md") "upstream/main"
    Assert-FileContains $Marker "source_repository=fork-skill"
    Assert-FileContains $Marker "runtime=$($Target.Runtime)"
    Assert-PathExists (Join-Path $Target.Root "prd-skill\SKILL.md")
    Assert-FileContains (Join-Path $Target.Root "prd-skill\SKILL.md") "name: prd-skill"
    foreach ($Archived in @("agent-operating-system","discuz-x5","experience-triage","idea-ledger","ui-ux-pro-max","git-upstream-sync-guard","prd-blueprint")) {
      Assert-PathMissing (Join-Path $Target.Root $Archived)
    }
  }

  Write-Host $InstallText
  Write-Host "Published fork-skill install and archive verification passed."
} finally {
  Remove-TestRoot
}
