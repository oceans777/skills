$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$ScriptPath = Join-Path $RepoRoot "scripts\skill-roots.ps1"
$SandboxRoot = Join-Path $env:TEMP ("oceans-roots-test-" + [Guid]::NewGuid().ToString("N"))

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

function Invoke-SkillRoots {
  param(
    [Parameter(Mandatory = $true)][string[]] $Arguments,
    [switch] $ExpectFailure
  )

  $PreviousErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $Output = & powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments *>&1 | Out-String
    $ExitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $PreviousErrorActionPreference
  }

  if ($ExpectFailure) {
    if ($ExitCode -eq 0) {
      throw "Expected skill-roots.ps1 to fail. Output:`n$Output"
    }
  } elseif ($ExitCode -ne 0) {
    throw "Expected skill-roots.ps1 to pass. Exit code: $ExitCode Output:`n$Output"
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
  foreach ($Root in @($CodexHome, $AgentsHome, $ClaudeHome, $OpenClawHome, $HermesHome)) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Root "skills") | Out-Null
  }

  $env:CODEX_HOME = $CodexHome
  $env:AGENTS_HOME = $AgentsHome
  $env:CLAUDE_HOME = $ClaudeHome
  $env:OPENCLAW_HOME = $OpenClawHome
  $env:HERMES_HOME = $HermesHome

  $Output = Invoke-SkillRoots -Arguments @("-Mode", "list")
  Assert-Contains -Text $Output -Expected "runtime: codex"
  Assert-Contains -Text $Output -Expected "runtime: agents"
  Assert-Contains -Text $Output -Expected "runtime: claude"
  Assert-Contains -Text $Output -Expected "runtime: openclaw"
  Assert-Contains -Text $Output -Expected "runtime: hermes"
  Assert-Contains -Text $Output -Expected "status: exists"
  Assert-Contains -Text $Output -Expected "path: $(Join-Path $CodexHome "skills")"

  $Output = Invoke-SkillRoots -Arguments @("-Mode", "install-default")
  Assert-Contains -Text $Output -Expected "runtime: codex"
  Assert-Contains -Text $Output -Expected "path: $(Join-Path $CodexHome "skills")"
  Assert-NotContains -Text $Output -Unexpected "runtime: claude"
  Assert-NotContains -Text $Output -Unexpected "runtime: agents"

  $Output = Invoke-SkillRoots -Arguments @("-Mode", "install-all-existing")
  Assert-Contains -Text $Output -Expected "runtime: codex"
  Assert-Contains -Text $Output -Expected "runtime: agents"
  Assert-Contains -Text $Output -Expected "runtime: claude"
  Assert-Contains -Text $Output -Expected "runtime: openclaw"
  Assert-Contains -Text $Output -Expected "runtime: hermes"

  $Output = Invoke-SkillRoots -Arguments @("-Mode", "stage", "-Runtime", "agents")
  Assert-Contains -Text $Output -Expected "runtime: agents"
  Assert-Contains -Text $Output -Expected "path: $(Join-Path $AgentsHome "skills")"

  $CustomRoot = Join-Path $SandboxRoot "custom-skills"
  New-Item -ItemType Directory -Force -Path $CustomRoot | Out-Null
  $Output = Invoke-SkillRoots -Arguments @("-Mode", "stage", "-SourceRoot", $CustomRoot)
  Assert-Contains -Text $Output -Expected "runtime: custom"
  Assert-Contains -Text $Output -Expected "path: $CustomRoot"

  $Output = Invoke-SkillRoots -Arguments @("-Mode", "install", "-Runtime", "custom") -ExpectFailure
  Assert-Contains -Text $Output -Expected "custom-runtime-requires-path"

  Write-Host "PowerShell skill roots test passed."
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
