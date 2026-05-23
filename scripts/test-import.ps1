$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$TestRoot = Join-Path $env:TEMP ("oceans-import-test-" + [Guid]::NewGuid().ToString("N"))
$RepoSkillRoot = Join-Path $RepoRoot "repos\oceans-skills\skills"
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

try {
  $RepoSkillPath = Join-Path $RepoSkillRoot $RepoSkillName
  if (Test-Path -LiteralPath $RepoSkillPath) {
    Remove-Item -LiteralPath $RepoSkillPath -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $RepoSkillPath | Out-Null
  Set-Content -LiteralPath (Join-Path $RepoSkillPath "SKILL.md") -Value "---`nname: my-skill`ndescription: Repository version.`n---`n" -Encoding UTF8

  New-Item -ItemType Directory -Force -Path $TestRoot | Out-Null

  New-Item -ItemType Directory -Force -Path (Join-Path $TestRoot "my-skill") | Out-Null
  Set-Content -LiteralPath (Join-Path $TestRoot "my-skill\SKILL.md") -Value "---`nname: my-skill`ndescription: Test skill.`n---`n" -Encoding UTF8

  New-Item -ItemType Directory -Force -Path (Join-Path $TestRoot "risky-skill") | Out-Null
  Set-Content -LiteralPath (Join-Path $TestRoot "risky-skill\SKILL.md") -Value "---`nname: risky-skill`ndescription: Uses /Users/example/private-notes.`n---`napi_key: test-value`n" -Encoding UTF8

  New-Item -ItemType Directory -Force -Path (Join-Path $TestRoot "no-skill") | Out-Null
  Set-Content -LiteralPath (Join-Path $TestRoot "no-skill\README.md") -Value "Missing SKILL.md" -Encoding UTF8

  New-Item -ItemType Directory -Force -Path (Join-Path $TestRoot ".system") | Out-Null
  Set-Content -LiteralPath (Join-Path $TestRoot ".system\SKILL.md") -Value "---`nname: system`ndescription: System skill.`n---`n" -Encoding UTF8

  $Output = & "$RepoRoot\scripts\import-skills.ps1" -SourceRoot $TestRoot *>&1 | Out-String

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

  Write-Host "PowerShell import test passed."
} finally {
  $RepoSkillPath = Join-Path $RepoSkillRoot $RepoSkillName
  if (Test-Path -LiteralPath $RepoSkillPath) {
    Remove-Item -LiteralPath $RepoSkillPath -Recurse -Force
  }
  if (Test-Path -LiteralPath $TestRoot) {
    Remove-Item -LiteralPath $TestRoot -Recurse -Force
  }
}
