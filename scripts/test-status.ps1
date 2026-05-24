$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$ScriptPath = Join-Path $RepoRoot "scripts\status.ps1"
$WrapperPath = Join-Path $RepoRoot "oceans.ps1"
$SandboxRoot = Join-Path $env:TEMP ("oceans-status-test-" + [Guid]::NewGuid().ToString("N"))

function Assert-Contains {
  param(
    [Parameter(Mandatory = $true)][string] $Text,
    [Parameter(Mandatory = $true)][string] $Expected
  )

  if (-not $Text.Contains($Expected)) {
    throw "Expected output to contain: $Expected`nActual output:`n$Text"
  }
}

function Assert-NotContains {
  param(
    [Parameter(Mandatory = $true)][string] $Text,
    [Parameter(Mandatory = $true)][string] $Unexpected
  )

  if ($Text.Contains($Unexpected)) {
    throw "Expected output not to contain: $Unexpected`nActual output:`n$Text"
  }
}

function Invoke-Status {
  param([string[]] $Arguments = @())

  $Output = & powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments *>&1 | Out-String
  if ($LASTEXITCODE -ne 0) {
    throw "status.ps1 failed. Output:`n$Output"
  }
  $Output
}

function Invoke-WrapperStatus {
  param([string[]] $Arguments = @())

  $Output = & powershell -NoProfile -ExecutionPolicy Bypass -File $WrapperPath status @Arguments *>&1 | Out-String
  if ($LASTEXITCODE -ne 0) {
    throw "oceans.ps1 status failed. Output:`n$Output"
  }
  $Output
}

$OldCodexHome = $env:CODEX_HOME
$OldAgentsHome = $env:AGENTS_HOME
$OldClaudeHome = $env:CLAUDE_HOME
$OldOpenClawHome = $env:OPENCLAW_HOME
$OldHermesHome = $env:HERMES_HOME

try {
  $CodexHome = Join-Path $SandboxRoot "codex-home"
  $AgentsHome = Join-Path $SandboxRoot "agents-home"
  $ClaudeHome = Join-Path $SandboxRoot "claude-home"
  $OpenClawHome = Join-Path $SandboxRoot "openclaw-home"
  $HermesHome = Join-Path $SandboxRoot "hermes-home"

  $CodexSkill = Join-Path $CodexHome "skills\codex-managed"
  $ClaudeSkill = Join-Path $ClaudeHome "skills\claude-managed"
  $ClaudeUnmanaged = Join-Path $ClaudeHome "skills\claude-private"
  New-Item -ItemType Directory -Force -Path $CodexSkill, $ClaudeSkill, $ClaudeUnmanaged | Out-Null
  Set-Content -LiteralPath (Join-Path $CodexSkill ".oceans-skill-source") -Value "source_repository=oceans-skills" -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $ClaudeSkill ".oceans-skill-source") -Value "source_repository=community-skills" -Encoding UTF8

  $env:CODEX_HOME = $CodexHome
  $env:AGENTS_HOME = $AgentsHome
  $env:CLAUDE_HOME = $ClaudeHome
  $env:OPENCLAW_HOME = $OpenClawHome
  $env:HERMES_HOME = $HermesHome

  $Output = Invoke-Status
  Assert-Contains -Text $Output -Expected "Runtime skill roots:"
  Assert-Contains -Text $Output -Expected "runtime: codex"
  Assert-Contains -Text $Output -Expected "path: $(Join-Path $CodexHome "skills")"
  Assert-Contains -Text $Output -Expected "runtime: claude"
  Assert-Contains -Text $Output -Expected "path: $(Join-Path $ClaudeHome "skills")"
  Assert-Contains -Text $Output -Expected "runtime: agents"
  Assert-Contains -Text $Output -Expected "status: missing"
  Assert-Contains -Text $Output -Expected "managed_oceans_skills: 1"

  $Output = Invoke-Status -Arguments @("-Runtime", "claude")
  Assert-Contains -Text $Output -Expected "runtime: claude"
  Assert-Contains -Text $Output -Expected "path: $(Join-Path $ClaudeHome "skills")"
  Assert-NotContains -Text $Output -Unexpected "path: $(Join-Path $CodexHome "skills")"

  $Output = Invoke-Status -Arguments @("-AllExistingRuntimes")
  Assert-Contains -Text $Output -Expected "runtime: codex"
  Assert-Contains -Text $Output -Expected "runtime: claude"
  Assert-NotContains -Text $Output -Unexpected "path: $(Join-Path $AgentsHome "skills")"

  $Output = Invoke-WrapperStatus -Arguments @("-Runtime", "claude")
  Assert-Contains -Text $Output -Expected "runtime: claude"
  Assert-Contains -Text $Output -Expected "path: $(Join-Path $ClaudeHome "skills")"
  Assert-NotContains -Text $Output -Unexpected "path: $(Join-Path $CodexHome "skills")"

  Write-Host "PowerShell status test passed."
} finally {
  if ($null -eq $OldCodexHome) { Remove-Item Env:\CODEX_HOME -ErrorAction SilentlyContinue } else { $env:CODEX_HOME = $OldCodexHome }
  if ($null -eq $OldAgentsHome) { Remove-Item Env:\AGENTS_HOME -ErrorAction SilentlyContinue } else { $env:AGENTS_HOME = $OldAgentsHome }
  if ($null -eq $OldClaudeHome) { Remove-Item Env:\CLAUDE_HOME -ErrorAction SilentlyContinue } else { $env:CLAUDE_HOME = $OldClaudeHome }
  if ($null -eq $OldOpenClawHome) { Remove-Item Env:\OPENCLAW_HOME -ErrorAction SilentlyContinue } else { $env:OPENCLAW_HOME = $OldOpenClawHome }
  if ($null -eq $OldHermesHome) { Remove-Item Env:\HERMES_HOME -ErrorAction SilentlyContinue } else { $env:HERMES_HOME = $OldHermesHome }

  if (Test-Path -LiteralPath $SandboxRoot) {
    Remove-Item -LiteralPath $SandboxRoot -Recurse -Force
  }
}
