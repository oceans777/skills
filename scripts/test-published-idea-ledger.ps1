$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
. (Join-Path $RepoRoot "scripts\skill-content-hash.ps1")
$CanonicalTemp = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $env:TEMP).Path)
$TestRoot = Join-Path $CanonicalTemp ("oceans-published-idea-ledger-" + [Guid]::NewGuid().ToString("N"))

function Assert-PathExists([string] $Path) {
  if (-not (Test-Path -LiteralPath $Path)) { throw "Expected path to exist: $Path" }
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
      -not (Split-Path -Leaf $ResolvedRoot).StartsWith("oceans-published-idea-ledger-")) {
    throw "Unsafe cleanup target: $ResolvedRoot"
  }
  Remove-Item -LiteralPath $ResolvedRoot -Recurse -Force
}

try {
  $PublishedSkill = Join-Path $RepoRoot "repos\oceans-skills\skills\idea-ledger"
  $ContentSha256 = Get-OceansSkillContentSha256 -SkillPath $PublishedSkill
  Write-Host "idea-ledger-content-sha256=$ContentSha256"
  Assert-FileContains (Join-Path $RepoRoot "catalog\skills\idea-ledger.skill") "content_sha256=$ContentSha256"

  New-Item -ItemType Directory -Force -Path $TestRoot | Out-Null
  $env:CODEX_HOME = Join-Path $TestRoot "codex"
  $env:AGENTS_HOME = Join-Path $TestRoot "agents"
  $env:CLAUDE_HOME = Join-Path $TestRoot "claude"
  $env:OPENCLAW_HOME = Join-Path $TestRoot "openclaw"
  $env:HERMES_HOME = Join-Path $TestRoot "hermes"
  $env:HOME = Join-Path $TestRoot "home"
  $env:PYTHONIOENCODING = "utf-8"
  $env:PYTHONUTF8 = "1"

  $RuntimeHomes = @(
    $env:CODEX_HOME,
    $env:AGENTS_HOME,
    $env:CLAUDE_HOME,
    $env:OPENCLAW_HOME,
    $env:HERMES_HOME
  )
  foreach ($RuntimeHome in $RuntimeHomes) {
    New-Item -ItemType Directory -Force -Path (Join-Path $RuntimeHome "skills") | Out-Null
  }

  $InstallText = (& (Join-Path $RepoRoot "scripts\install-skills.ps1") -AllExistingRuntimes *>&1 | Out-String)
  if ($InstallText.Contains("legacy package without catalog content SHA-256: idea-ledger")) {
    throw "idea-ledger was installed without a catalog content fingerprint"
  }

  $Targets = @(
    [PSCustomObject]@{ Runtime = "codex"; Root = Join-Path $env:CODEX_HOME "skills" },
    [PSCustomObject]@{ Runtime = "agents"; Root = Join-Path $env:AGENTS_HOME "skills" },
    [PSCustomObject]@{ Runtime = "claude"; Root = Join-Path $env:CLAUDE_HOME "skills" },
    [PSCustomObject]@{ Runtime = "openclaw"; Root = Join-Path $env:OPENCLAW_HOME "skills" },
    [PSCustomObject]@{ Runtime = "hermes"; Root = Join-Path $env:HERMES_HOME "skills" }
  )

  foreach ($Target in $Targets) {
    $Skill = Join-Path $Target.Root "idea-ledger"
    $Marker = Join-Path $Skill ".oceans-skill-source"
    $Cli = Join-Path $Skill "scripts\idea_ledger.py"
    Assert-PathExists (Join-Path $Skill "SKILL.md")
    Assert-PathExists (Join-Path $Skill "LICENSE")
    Assert-PathExists $Cli
    Assert-FileContains (Join-Path $Skill "SKILL.md") "disable-model-invocation: true"
    Assert-FileContains $Marker "source_repository=oceans-skills"
    Assert-FileContains $Marker "runtime=$($Target.Runtime)"
    $Version = (& python $Cli --version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $Version -ne "2.1.0") {
      throw "Unexpected idea-ledger version in $($Target.Runtime): $Version"
    }
  }

  $ProjectRoot = Join-Path $TestRoot "project"
  New-Item -ItemType Directory -Force -Path $ProjectRoot | Out-Null
  $CodexCli = Join-Path $env:CODEX_HOME "skills\idea-ledger\scripts\idea_ledger.py"
  & python $CodexCli init --root $ProjectRoot | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "idea-ledger init failed" }
  & python $CodexCli validate --root $ProjectRoot | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "idea-ledger validate failed" }
  & python $CodexCli status --root $ProjectRoot --json | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "idea-ledger status failed" }
  Assert-PathExists (Join-Path $ProjectRoot ".idea-ledger\config.json")

  Write-Host $InstallText
  Write-Host "Published idea-ledger install and runtime verification passed."
} finally {
  Remove-TestRoot
}
