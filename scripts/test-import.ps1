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

  Write-Host "PowerShell import test passed."
} finally {
  Remove-SandboxRoot
}
