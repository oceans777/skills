$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$CanonicalTemp = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $env:TEMP).Path)
$TestRoot = Join-Path $CanonicalTemp ("oceans-install-test-" + [Guid]::NewGuid().ToString("N"))
$FirstPartyRoot = Join-Path $TestRoot "first-party\skills"
$CommunityRoot = Join-Path $TestRoot "community\skills"
$SkillNames = @("local-first-test", "managed-update-test", "unknown-marker-test", "source-mismatch-test")

function Assert-Contains([string] $Text, [string] $Expected) { if (-not $Text.Contains($Expected)) { throw "Expected output to contain: $Expected" } }
function Assert-FileContains([string] $Path, [string] $Expected) { if (-not (Get-Content -LiteralPath $Path -Raw).Contains($Expected)) { throw "Expected $Path to contain: $Expected" } }
function Assert-PathExists([string] $Path) { if (-not (Test-Path -LiteralPath $Path)) { throw "Expected path to exist: $Path" } }
function Remove-TestRoot {
  if (-not (Test-Path -LiteralPath $TestRoot)) { return }
  $ResolvedRoot = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $TestRoot).Path)
  $ResolvedTemp = $CanonicalTemp.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  $LeafName = Split-Path -Leaf $ResolvedRoot
  if (-not $ResolvedRoot.StartsWith($ResolvedTemp, [StringComparison]::OrdinalIgnoreCase) -or -not $LeafName.StartsWith("oceans-install-test-", [StringComparison]::Ordinal)) { throw "Unsafe cleanup target: $ResolvedRoot" }
  Remove-Item -LiteralPath $ResolvedRoot -Recurse -Force
}

try {
  New-Item -ItemType Directory -Force -Path $FirstPartyRoot, $CommunityRoot | Out-Null
  foreach ($SkillName in $SkillNames) {
    $SourceSkill = Join-Path $FirstPartyRoot $SkillName
    New-Item -ItemType Directory -Force -Path $SourceSkill | Out-Null
    Set-Content -LiteralPath (Join-Path $SourceSkill "SKILL.md") -Value "---`nname: $SkillName`ndescription: Repository version.`n---`nrepo-version`n" -Encoding UTF8
  }

  $InstallRoot = Join-Path $TestRoot "skills"
  $LocalTarget = Join-Path $InstallRoot "local-first-test"
  New-Item -ItemType Directory -Force -Path $LocalTarget | Out-Null
  Set-Content -LiteralPath (Join-Path $LocalTarget "SKILL.md") -Value "local-version" -Encoding UTF8
  $ManagedTarget = Join-Path $InstallRoot "managed-update-test"
  New-Item -ItemType Directory -Force -Path $ManagedTarget | Out-Null
  Set-Content -LiteralPath (Join-Path $ManagedTarget "SKILL.md") -Value "old-managed-version" -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $ManagedTarget ".oceans-skill-source") -Value @("source_repository=oceans-skills") -Encoding UTF8
  $UnknownTarget = Join-Path $InstallRoot "unknown-marker-test"
  New-Item -ItemType Directory -Force -Path $UnknownTarget | Out-Null
  Set-Content -LiteralPath (Join-Path $UnknownTarget "SKILL.md") -Value "unknown-marker-version" -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $UnknownTarget ".oceans-skill-source") -Value @("source_repository=other-repo") -Encoding UTF8
  $SourceMismatchTarget = Join-Path $InstallRoot "source-mismatch-test"
  New-Item -ItemType Directory -Force -Path $SourceMismatchTarget | Out-Null
  Set-Content -LiteralPath (Join-Path $SourceMismatchTarget "SKILL.md") -Value "community-managed-version" -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $SourceMismatchTarget ".oceans-skill-source") -Value @("source_repository=community-skills") -Encoding UTF8

  $Output = & "$RepoRoot\scripts\install-skills.ps1" -InstallRoot $InstallRoot -FirstPartySkillsRoot $FirstPartyRoot -CommunitySkillsRoot $CommunityRoot -WithoutCatalog *>&1 | Out-String
  Assert-Contains $Output "duplicate-local-wins: local-first-test"
  Assert-Contains $Output "Updated managed oceans777 skill: managed-update-test"
  Assert-Contains $Output "duplicate-local-wins: unknown-marker-test"
  Assert-Contains $Output "duplicate-managed-source-mismatch: source-mismatch-test"
  Assert-FileContains (Join-Path $LocalTarget "SKILL.md") "local-version"
  Assert-FileContains (Join-Path $ManagedTarget "SKILL.md") "repo-version"
  Assert-FileContains (Join-Path $UnknownTarget "SKILL.md") "unknown-marker-version"
  Assert-FileContains (Join-Path $SourceMismatchTarget "SKILL.md") "community-managed-version"
  Assert-FileContains (Join-Path $ManagedTarget ".oceans-skill-source") "install_root=$InstallRoot"

  $ClaudeHome = Join-Path $TestRoot "claude-home"
  $OldClaudeHome = $env:CLAUDE_HOME
  try {
    $env:CLAUDE_HOME = $ClaudeHome
    $Output = & "$RepoRoot\scripts\install-skills.ps1" -Runtime claude -FirstPartySkillsRoot $FirstPartyRoot -CommunitySkillsRoot $CommunityRoot -WithoutCatalog *>&1 | Out-String
  } finally { if ($null -eq $OldClaudeHome) { Remove-Item Env:\CLAUDE_HOME -ErrorAction SilentlyContinue } else { $env:CLAUDE_HOME = $OldClaudeHome } }
  $ClaudeInstallRoot = Join-Path $ClaudeHome "skills"
  Assert-Contains $Output "Install root: $ClaudeInstallRoot"
  Assert-PathExists (Join-Path $ClaudeInstallRoot "managed-update-test\SKILL.md")
  Assert-FileContains (Join-Path $ClaudeInstallRoot "managed-update-test\.oceans-skill-source") "runtime=claude"
  Assert-FileContains (Join-Path $ClaudeInstallRoot "managed-update-test\.oceans-skill-source") "install_root=$ClaudeInstallRoot"

  $CodexHome = Join-Path $TestRoot "codex-home"
  $AgentsHome = Join-Path $TestRoot "agents-home"
  $ClaudeHome = Join-Path $TestRoot "claude-existing-home"
  foreach ($Root in @($CodexHome, $AgentsHome, $ClaudeHome)) { New-Item -ItemType Directory -Force -Path (Join-Path $Root "skills") | Out-Null }
  $OldCodexHome = $env:CODEX_HOME; $OldAgentsHome = $env:AGENTS_HOME; $OldClaudeHome = $env:CLAUDE_HOME
  try {
    $env:CODEX_HOME = $CodexHome; $env:AGENTS_HOME = $AgentsHome; $env:CLAUDE_HOME = $ClaudeHome
    $Output = & "$RepoRoot\scripts\install-skills.ps1" -AllExistingRuntimes -FirstPartySkillsRoot $FirstPartyRoot -CommunitySkillsRoot $CommunityRoot -WithoutCatalog *>&1 | Out-String
  } finally {
    if ($null -eq $OldCodexHome) { Remove-Item Env:\CODEX_HOME -ErrorAction SilentlyContinue } else { $env:CODEX_HOME = $OldCodexHome }
    if ($null -eq $OldAgentsHome) { Remove-Item Env:\AGENTS_HOME -ErrorAction SilentlyContinue } else { $env:AGENTS_HOME = $OldAgentsHome }
    if ($null -eq $OldClaudeHome) { Remove-Item Env:\CLAUDE_HOME -ErrorAction SilentlyContinue } else { $env:CLAUDE_HOME = $OldClaudeHome }
  }
  Assert-Contains $Output "codex-home"
  Assert-Contains $Output "agents-home"
  Assert-Contains $Output "claude-existing-home"
  Assert-PathExists (Join-Path $CodexHome "skills\managed-update-test\SKILL.md")
  Assert-PathExists (Join-Path $AgentsHome "skills\managed-update-test\SKILL.md")
  Assert-PathExists (Join-Path $ClaudeHome "skills\managed-update-test\SKILL.md")
  Write-Host "PowerShell install local-first test passed."
} finally { Remove-TestRoot }
