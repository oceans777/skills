$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$SandboxRoot = Join-Path $env:TEMP ("oceans-import-test-" + [Guid]::NewGuid().ToString("N"))
$LocalSkillsRoot = Join-Path $SandboxRoot "local-skills"
$FirstPartyRoot = Join-Path $SandboxRoot "repo\oceans-skills\skills"
$CommunityRoot = Join-Path $SandboxRoot "repo\community-skills\skills"
$RepoSkillName = "my-skill"

function Assert-Contains {
  param(
    [Parameter(Mandatory = $true)]
    [string] $Text,

    [Parameter(Mandatory = $true)]
    [string] $Expected
  )

  if (-not $Text.Contains($Expected)) {
    throw "Expected output to contain: $Expected"
  }
}

function Assert-NotContains {
  param(
    [Parameter(Mandatory = $true)]
    [string] $Text,

    [Parameter(Mandatory = $true)]
    [string] $Unexpected
  )

  if ($Text.Contains($Unexpected)) {
    throw "Expected output not to contain: $Unexpected`nActual output:`n$Text"
  }
}

function Remove-SandboxRoot {
  if (-not (Test-Path -LiteralPath $SandboxRoot)) {
    return
  }

  $ResolvedRoot = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $SandboxRoot).Path)
  $ResolvedTemp = [System.IO.Path]::GetFullPath($env:TEMP)
  if (-not $ResolvedTemp.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
    $ResolvedTemp += [System.IO.Path]::DirectorySeparatorChar
  }

  $LeafName = Split-Path -Leaf $ResolvedRoot
  if (-not $ResolvedRoot.StartsWith($ResolvedTemp, [StringComparison]::OrdinalIgnoreCase) -or
      -not $LeafName.StartsWith("oceans-import-test-", [StringComparison]::Ordinal)) {
    throw "Unsafe cleanup target: $ResolvedRoot"
  }

  Remove-Item -LiteralPath $ResolvedRoot -Recurse -Force
}

try {
  New-Item -ItemType Directory -Force -Path $LocalSkillsRoot | Out-Null
  New-Item -ItemType Directory -Force -Path $FirstPartyRoot | Out-Null
  New-Item -ItemType Directory -Force -Path $CommunityRoot | Out-Null

  $RepoSkillPath = Join-Path $FirstPartyRoot $RepoSkillName
  New-Item -ItemType Directory -Force -Path $RepoSkillPath | Out-Null
  Set-Content -LiteralPath (Join-Path $RepoSkillPath "SKILL.md") -Value "---`nname: my-skill`ndescription: Repository version.`n---`n" -Encoding UTF8

  New-Item -ItemType Directory -Force -Path (Join-Path $LocalSkillsRoot "my-skill") | Out-Null
  Set-Content -LiteralPath (Join-Path $LocalSkillsRoot "my-skill\SKILL.md") -Value "---`nname: my-skill`ndescription: Test skill.`n---`n" -Encoding UTF8

  New-Item -ItemType Directory -Force -Path (Join-Path $LocalSkillsRoot "risky-skill") | Out-Null
  Set-Content -LiteralPath (Join-Path $LocalSkillsRoot "risky-skill\SKILL.md") -Value "---`nname: risky-skill`ndescription: Uses /Users/example/private-notes.`n---`napi_key: test-value`n" -Encoding UTF8

  New-Item -ItemType Directory -Force -Path (Join-Path $LocalSkillsRoot "no-skill") | Out-Null
  Set-Content -LiteralPath (Join-Path $LocalSkillsRoot "no-skill\README.md") -Value "Missing SKILL.md" -Encoding UTF8

  New-Item -ItemType Directory -Force -Path (Join-Path $LocalSkillsRoot ".system") | Out-Null
  Set-Content -LiteralPath (Join-Path $LocalSkillsRoot ".system\SKILL.md") -Value "---`nname: system`ndescription: System skill.`n---`n" -Encoding UTF8

  $Output = & "$RepoRoot\scripts\import-skills.ps1" `
    -SourceRoot $LocalSkillsRoot `
    -FirstPartySkillsRoot $FirstPartyRoot `
    -CommunitySkillsRoot $CommunityRoot *>&1 | Out-String

  Assert-Contains -Text $Output -Expected "No files were copied."
  Assert-Contains -Text $Output -Expected "my-skill"
  Assert-Contains -Text $Output -Expected "duplicate-local-wins"
  Assert-Contains -Text $Output -Expected "repository_match: oceans-skills"
  Assert-Contains -Text $Output -Expected "action: keep local skill; repository version will not overwrite it"
  Assert-Contains -Text $Output -Expected "risky-skill"
  Assert-Contains -Text $Output -Expected "risk: secret-like text"
  Assert-Contains -Text $Output -Expected "risk: local absolute path"
  Assert-Contains -Text $Output -Expected "no-skill"
  Assert-Contains -Text $Output -Expected "missing-skill-md"
  Assert-Contains -Text $Output -Expected ".system"
  Assert-Contains -Text $Output -Expected "skip-system"

  $LicenseRoot = Join-Path $SandboxRoot "license-local-skills"
  $LicenseSkill = Join-Path $LicenseRoot "missing-license-skill"
  New-Item -ItemType Directory -Force -Path $LicenseSkill | Out-Null
  Set-Content -LiteralPath (Join-Path $LicenseSkill "SKILL.md") -Value "---`nname: missing-license-skill`ndescription: Missing license reference.`nlicense: Complete terms in LICENSE.txt`n---`n" -Encoding UTF8
  $LicenseOutput = & "$RepoRoot\scripts\import-skills.ps1" `
    -SourceRoot $LicenseRoot `
    -FirstPartySkillsRoot $FirstPartyRoot `
    -CommunitySkillsRoot $CommunityRoot *>&1 | Out-String
  Assert-Contains -Text $LicenseOutput -Expected "missing-license-skill"
  Assert-Contains -Text $LicenseOutput -Expected "risk: missing referenced license file"

  $BenignRoot = Join-Path $SandboxRoot "benign-local-skills"
  $BenignSkill = Join-Path $BenignRoot "benign-route-skill"
  New-Item -ItemType Directory -Force -Path (Join-Path $BenignSkill "data\__pycache__") | Out-Null
  Set-Content -LiteralPath (Join-Path $BenignSkill "SKILL.md") -Value "---`nname: benign-route-skill`ndescription: Benign route path.`n---`napp/api/users/route.ts`n/homework/project`n" -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $BenignSkill "data\__pycache__\cache.pyc") -Value "C:\Users\example\cache-only" -Encoding UTF8
  $BenignOutput = & "$RepoRoot\scripts\import-skills.ps1" `
    -SourceRoot $BenignRoot `
    -FirstPartySkillsRoot $FirstPartyRoot `
    -CommunitySkillsRoot $CommunityRoot *>&1 | Out-String
  Assert-Contains -Text $BenignOutput -Expected "benign-route-skill"
  Assert-Contains -Text $BenignOutput -Expected "risk: none detected"
  Assert-NotContains -Text $BenignOutput -Unexpected "risk: local absolute path"

  $CodexHome = Join-Path $SandboxRoot "codex-home"
  $AgentsHome = Join-Path $SandboxRoot "agents-home"
  $ClaudeHome = Join-Path $SandboxRoot "claude-home"
  foreach ($Root in @($CodexHome, $AgentsHome, $ClaudeHome)) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Root "skills") | Out-Null
  }

  New-Item -ItemType Directory -Force -Path (Join-Path $CodexHome "skills\codex-only-skill") | Out-Null
  Set-Content -LiteralPath (Join-Path $CodexHome "skills\codex-only-skill\SKILL.md") -Value "---`nname: codex-only-skill`ndescription: Codex only.`n---`n" -Encoding UTF8

  New-Item -ItemType Directory -Force -Path (Join-Path $AgentsHome "skills\shared-runtime-skill") | Out-Null
  Set-Content -LiteralPath (Join-Path $AgentsHome "skills\shared-runtime-skill\SKILL.md") -Value "---`nname: shared-runtime-skill`ndescription: Agents copy.`n---`n" -Encoding UTF8

  New-Item -ItemType Directory -Force -Path (Join-Path $ClaudeHome "skills\shared-runtime-skill") | Out-Null
  Set-Content -LiteralPath (Join-Path $ClaudeHome "skills\shared-runtime-skill\SKILL.md") -Value "---`nname: shared-runtime-skill`ndescription: Claude copy.`n---`n" -Encoding UTF8

  $OldCodexHome = $env:CODEX_HOME
  $OldAgentsHome = $env:AGENTS_HOME
  $OldClaudeHome = $env:CLAUDE_HOME
  try {
    $env:CODEX_HOME = $CodexHome
    $env:AGENTS_HOME = $AgentsHome
    $env:CLAUDE_HOME = $ClaudeHome
    $Output = & "$RepoRoot\scripts\import-skills.ps1" `
      -FirstPartySkillsRoot $FirstPartyRoot `
      -CommunitySkillsRoot $CommunityRoot *>&1 | Out-String
  } finally {
    if ($null -eq $OldCodexHome) { Remove-Item Env:\CODEX_HOME -ErrorAction SilentlyContinue } else { $env:CODEX_HOME = $OldCodexHome }
    if ($null -eq $OldAgentsHome) { Remove-Item Env:\AGENTS_HOME -ErrorAction SilentlyContinue } else { $env:AGENTS_HOME = $OldAgentsHome }
    if ($null -eq $OldClaudeHome) { Remove-Item Env:\CLAUDE_HOME -ErrorAction SilentlyContinue } else { $env:CLAUDE_HOME = $OldClaudeHome }
  }

  Assert-Contains -Text $Output -Expected "Source roots:"
  Assert-Contains -Text $Output -Expected "runtime: codex"
  Assert-Contains -Text $Output -Expected "runtime: agents"
  Assert-Contains -Text $Output -Expected "runtime: claude"
  Assert-Contains -Text $Output -Expected "source_root: $(Join-Path $CodexHome "skills")"
  Assert-Contains -Text $Output -Expected "source_path:"
  Assert-Contains -Text $Output -Expected "shared-runtime-skill"
  Assert-Contains -Text $Output -Expected "status: duplicate-local-runtime"
  Assert-Contains -Text $Output -Expected "local_runtime_match: agents, claude"

  Write-Host "PowerShell import test passed."
} finally {
  Remove-SandboxRoot
}
