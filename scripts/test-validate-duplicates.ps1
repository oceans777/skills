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

function Invoke-ValidateSkills {
  param(
    [Parameter(Mandatory = $true)]
    [string] $FirstPartyRoot,

    [Parameter(Mandatory = $true)]
    [string] $CommunityRoot
  )

  $PreviousErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $Output = & powershell -NoProfile -ExecutionPolicy Bypass -File "$RepoRoot\scripts\validate-skills.ps1" -FirstPartySkillsRoot $FirstPartyRoot -CommunitySkillsRoot $CommunityRoot *>&1 | Out-String
    $ExitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $PreviousErrorActionPreference
  }

  [PSCustomObject]@{
    ExitCode = $ExitCode
    Output = $Output
  }
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

  $Result = Invoke-ValidateSkills -FirstPartyRoot $FirstPartyRoot -CommunityRoot $CommunityRoot
  if ($Result.ExitCode -eq 0) {
    throw "Expected duplicate validation to fail."
  }

  Assert-Contains -Text $Result.Output -Expected "Duplicate skill name across repositories: duplicate-skill"

  $EmptyCommunitySkill = Join-Path $CommunityRoot "empty-attribution-skill"
  New-Item -ItemType Directory -Force -Path $EmptyCommunitySkill | Out-Null
  Set-Content -LiteralPath (Join-Path $EmptyCommunitySkill "SKILL.md") -Value "---`nname: empty-attribution-skill`ndescription: Empty attribution.`n---`n" -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $EmptyCommunitySkill "UPSTREAM.md") -Value "" -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $EmptyCommunitySkill "PATCHES.md") -Value "   " -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $EmptyCommunitySkill "LICENSE") -Value "" -Encoding UTF8

  $Result = Invoke-ValidateSkills -FirstPartyRoot $FirstPartyRoot -CommunityRoot $CommunityRoot
  if ($Result.ExitCode -eq 0) {
    throw "Expected empty community attribution validation to fail."
  }

  Assert-Contains -Text $Result.Output -Expected "Missing or empty UPSTREAM.md in community-skills: empty-attribution-skill"
  Assert-Contains -Text $Result.Output -Expected "Missing or empty PATCHES.md in community-skills: empty-attribution-skill"
  Assert-Contains -Text $Result.Output -Expected "Missing or empty LICENSE in community-skills: empty-attribution-skill"

  $MissingLicenseRef = Join-Path $FirstPartyRoot "missing-license-reference"
  New-Item -ItemType Directory -Force -Path $MissingLicenseRef | Out-Null
  Set-Content -LiteralPath (Join-Path $MissingLicenseRef "SKILL.md") -Value "---`nname: missing-license-reference`ndescription: Missing license reference.`nlicense: Complete terms in LICENSE.txt`n---`n" -Encoding UTF8
  $Result = Invoke-ValidateSkills -FirstPartyRoot $FirstPartyRoot -CommunityRoot $CommunityRoot
  if ($Result.ExitCode -eq 0) {
    throw "Expected validate to fail for missing referenced license file."
  }
  Assert-Contains -Text $Result.Output -Expected "Missing referenced license file in oceans-skills: missing-license-reference"

  $InvalidMetadata = Join-Path $FirstPartyRoot "metadata-mismatch"
  New-Item -ItemType Directory -Force -Path $InvalidMetadata | Out-Null
  Set-Content -LiteralPath (Join-Path $InvalidMetadata "SKILL.md") -Value "---`nname: different-name`ndescription: Name mismatch.`n---`n" -Encoding UTF8
  $Result = Invoke-ValidateSkills -FirstPartyRoot $FirstPartyRoot -CommunityRoot $CommunityRoot
  if ($Result.ExitCode -eq 0) {
    throw "Expected validate to fail for skill metadata mismatch."
  }
  Assert-Contains -Text $Result.Output -Expected "Invalid skill metadata in oceans-skills: metadata-mismatch: risk: skill name does not match folder name"

  $InvalidFolderMissingSkill = Join-Path $FirstPartyRoot "bad folder"
  New-Item -ItemType Directory -Force -Path $InvalidFolderMissingSkill | Out-Null
  Set-Content -LiteralPath (Join-Path $InvalidFolderMissingSkill "README.md") -Value "Missing SKILL.md." -Encoding UTF8
  $Result = Invoke-ValidateSkills -FirstPartyRoot $FirstPartyRoot -CommunityRoot $CommunityRoot
  if ($Result.ExitCode -eq 0) {
    throw "Expected validate to fail for invalid folder name without SKILL.md."
  }
  Assert-Contains -Text $Result.Output -Expected "Invalid skill metadata in oceans-skills: bad folder: risk: invalid skill folder name"

  Write-Host "PowerShell validate duplicate test passed."
} finally {
  Remove-TestRoot
}
