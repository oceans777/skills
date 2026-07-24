$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "skill-publish-rules.ps1")

$CanonicalTemp = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $env:TEMP).Path)
$TestRoot = Join-Path $CanonicalTemp ("oceans-frontmatter-test-" + [Guid]::NewGuid().ToString("N"))

function Assert-Contains([string] $Text, [string] $Expected) {
  if (-not $Text.Contains($Expected)) { throw "Expected output to contain: $Expected" }
}

function Assert-Empty([object[]] $Items) {
  if (@($Items).Count -ne 0) { throw "Expected no metadata issues, found: $(@($Items) -join '; ')" }
}

function Write-Skill([string] $Name, [string] $Content) {
  $Path = Join-Path $TestRoot $Name
  New-Item -ItemType Directory -Force -Path $Path | Out-Null
  [System.IO.File]::WriteAllText(
    (Join-Path $Path "SKILL.md"),
    $Content,
    (New-Object System.Text.UTF8Encoding($false))
  )
  return $Path
}

function Remove-TestRoot {
  if (-not (Test-Path -LiteralPath $TestRoot)) { return }
  $ResolvedRoot = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $TestRoot).Path)
  $Prefix = $CanonicalTemp.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  if (-not $ResolvedRoot.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase) -or
      -not (Split-Path -Leaf $ResolvedRoot).StartsWith("oceans-frontmatter-test-")) {
    throw "Unsafe cleanup target: $ResolvedRoot"
  }
  Remove-Item -LiteralPath $ResolvedRoot -Recurse -Force
}

try {
  New-Item -ItemType Directory -Force -Path $TestRoot | Out-Null

  $Valid = Write-Skill "explicit-extension" @'
---
name: explicit-extension
description: Valid explicit-invocation runtime metadata.
compatibility: Requires Python 3.10 or later.
argument-hint: "[new|audit] [topic]"
disable-model-invocation: true
user-invocable: true
background: false
when_to_use: Use only after an explicit invocation token.
arguments: "command and topic"
disallowed-tools: Bash
model: inherit
effort: medium
context: fork
agent: general-purpose
hooks:
  Stop: []
paths:
  - docs/**
shell: bash
metadata:
  version: "1.0.0"
---
'@
  Assert-Empty @(Get-OceansSkillMetadataIssues -SkillPath $Valid -ExpectedName "explicit-extension")

  $BadBoolean = Write-Skill "invalid-boolean" @'
---
name: invalid-boolean
description: Invalid boolean fixture.
disable-model-invocation: "true"
---
'@
  Assert-Contains ((Get-OceansSkillMetadataIssues -SkillPath $BadBoolean -ExpectedName "invalid-boolean") -join "`n") "risk: disable-model-invocation must be a boolean"

  $BadCompatibility = Write-Skill "invalid-compatibility" @'
---
name: invalid-compatibility
description: Invalid compatibility fixture.
compatibility: |
  Requires Python.
---
'@
  Assert-Contains ((Get-OceansSkillMetadataIssues -SkillPath $BadCompatibility -ExpectedName "invalid-compatibility") -join "`n") "risk: compatibility must be a non-empty single-line string"

  $BadHint = Write-Skill "invalid-argument-hint" @'
---
name: invalid-argument-hint
description: Invalid argument hint fixture.
argument-hint: |
  first line
  second line
---
'@
  Assert-Contains ((Get-OceansSkillMetadataIssues -SkillPath $BadHint -ExpectedName "invalid-argument-hint") -join "`n") "risk: argument-hint must be a non-empty single-line string"

  $Unknown = Write-Skill "unsupported-extension" @'
---
name: unsupported-extension
description: Unknown extension fixture.
mystery-runtime-field: true
---
'@
  Assert-Contains ((Get-OceansSkillMetadataIssues -SkillPath $Unknown -ExpectedName "unsupported-extension") -join "`n") "risk: unsupported frontmatter key: mystery-runtime-field"

  Write-Host "PowerShell frontmatter extension test passed."
} finally {
  Remove-TestRoot
}
