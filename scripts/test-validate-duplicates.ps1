$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$TestRoot = Join-Path $env:TEMP ("oceans-validate-test-" + [Guid]::NewGuid().ToString("N"))

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

function Remove-TestRoot {
  if (-not (Test-Path -LiteralPath $TestRoot)) {
    return
  }

  $ResolvedRoot = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $TestRoot).Path)
  $ResolvedTemp = [System.IO.Path]::GetFullPath($env:TEMP)
  if (-not $ResolvedTemp.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
    $ResolvedTemp += [System.IO.Path]::DirectorySeparatorChar
  }

  $LeafName = Split-Path -Leaf $ResolvedRoot
  if (-not $ResolvedRoot.StartsWith($ResolvedTemp, [StringComparison]::OrdinalIgnoreCase) -or
      -not $LeafName.StartsWith("oceans-validate-test-", [StringComparison]::Ordinal)) {
    throw "Unsafe cleanup target: $ResolvedRoot"
  }

  Remove-Item -LiteralPath $ResolvedRoot -Recurse -Force
}

try {
  $FirstPartyRoot = Join-Path $TestRoot "oceans-skills"
  $CommunityRoot = Join-Path $TestRoot "community-skills"

  New-Item -ItemType Directory -Force -Path (Join-Path $FirstPartyRoot "duplicate-skill") | Out-Null
  Set-Content -LiteralPath (Join-Path $FirstPartyRoot "duplicate-skill\SKILL.md") -Value "---`nname: duplicate-skill`ndescription: First party.`n---`n" -Encoding UTF8

  New-Item -ItemType Directory -Force -Path (Join-Path $CommunityRoot "duplicate-skill") | Out-Null
  Set-Content -LiteralPath (Join-Path $CommunityRoot "duplicate-skill\SKILL.md") -Value "---`nname: duplicate-skill`ndescription: Community.`n---`n" -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $CommunityRoot "duplicate-skill\UPSTREAM.md") -Value "upstream" -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $CommunityRoot "duplicate-skill\PATCHES.md") -Value "patches" -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $CommunityRoot "duplicate-skill\LICENSE") -Value "license" -Encoding UTF8

  $Succeeded = $true
  $Output = ""
  try {
    $Output = & "$RepoRoot\scripts\validate-skills.ps1" -FirstPartySkillsRoot $FirstPartyRoot -CommunitySkillsRoot $CommunityRoot *>&1 | Out-String
  } catch {
    $Succeeded = $false
    $Output = ($_ | Out-String) + "`n" + ($Output | Out-String)
  }

  if ($Succeeded) {
    throw "Expected duplicate validation to fail."
  }

  Assert-Contains -Text $Output -Expected "Duplicate skill name across repositories: duplicate-skill"
  Write-Host "PowerShell validate duplicate test passed."
} finally {
  Remove-TestRoot
}
