$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$CanonicalTemp = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $env:TEMP).Path)
$TestRoot = Join-Path $CanonicalTemp ("oceans-validate-test-" + [Guid]::NewGuid().ToString("N"))
$FirstPartyRoot = Join-Path $TestRoot "oceans-skills"
$CommunityRoot = Join-Path $TestRoot "community-skills"

function Assert-Contains([string] $Text, [string] $Expected) { if (-not $Text.Contains($Expected)) { throw "Expected output to contain: $Expected" } }
function Assert-NotContains([string] $Text, [string] $Unexpected) { if ($Text.Contains($Unexpected)) { throw "Expected output not to contain: $Unexpected" } }
function Write-Skill([string] $Root, [string] $Folder, [string] $Name, [string] $Description) {
  $Path = Join-Path $Root $Folder
  New-Item -ItemType Directory -Force -Path $Path | Out-Null
  Set-Content -LiteralPath (Join-Path $Path "SKILL.md") -Value "---`nname: $Name`ndescription: $Description`n---`n" -Encoding UTF8
  return $Path
}
function Invoke-Validate {
  $Previous = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $Output = & pwsh -NoProfile -File "$RepoRoot\scripts\validate-skills.ps1" -FirstPartySkillsRoot $FirstPartyRoot -CommunitySkillsRoot $CommunityRoot -WithoutCatalog *>&1 | Out-String
    $Code = $LASTEXITCODE
  } finally { $ErrorActionPreference = $Previous }
  return [PSCustomObject]@{ ExitCode = $Code; Output = $Output }
}
function Expect-Failure([string] $Message) { $script:Result = Invoke-Validate; if ($script:Result.ExitCode -eq 0) { throw $Message } }
function Remove-TestRoot {
  if (-not (Test-Path -LiteralPath $TestRoot)) { return }
  $ResolvedRoot = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $TestRoot).Path)
  $Prefix = $CanonicalTemp.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  if (-not $ResolvedRoot.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase) -or -not (Split-Path -Leaf $ResolvedRoot).StartsWith("oceans-validate-test-")) { throw "Unsafe cleanup target: $ResolvedRoot" }
  Remove-Item -LiteralPath $ResolvedRoot -Recurse -Force
}

try {
  New-Item -ItemType Directory -Force -Path $FirstPartyRoot, $CommunityRoot | Out-Null
  Write-Skill $FirstPartyRoot "duplicate-skill" "duplicate-skill" "First party." | Out-Null
  $CommunityDuplicate = Write-Skill $CommunityRoot "duplicate-skill" "duplicate-skill" "Community."
  Set-Content (Join-Path $CommunityDuplicate "UPSTREAM.md") "upstream" -Encoding UTF8
  Set-Content (Join-Path $CommunityDuplicate "PATCHES.md") "patches" -Encoding UTF8
  Set-Content (Join-Path $CommunityDuplicate "LICENSE") "license" -Encoding UTF8
  Expect-Failure "Expected duplicate validation to fail."
  Assert-Contains $Result.Output "Duplicate skill name across repositories: duplicate-skill"

  $Empty = Write-Skill $CommunityRoot "empty-attribution-skill" "empty-attribution-skill" "Empty attribution."
  Set-Content (Join-Path $Empty "UPSTREAM.md") "" -Encoding UTF8
  Set-Content (Join-Path $Empty "PATCHES.md") "   " -Encoding UTF8
  Set-Content (Join-Path $Empty "LICENSE") "" -Encoding UTF8
  Expect-Failure "Expected empty attribution validation to fail."
  Assert-Contains $Result.Output "Missing or empty UPSTREAM.md in community-skills: empty-attribution-skill"
  Assert-Contains $Result.Output "Missing or empty PATCHES.md in community-skills: empty-attribution-skill"
  Assert-Contains $Result.Output "Missing or empty LICENSE in community-skills: empty-attribution-skill"

  $MissingLicense = Join-Path $FirstPartyRoot "missing-license-reference"
  New-Item -ItemType Directory -Force -Path $MissingLicense | Out-Null
  Set-Content (Join-Path $MissingLicense "SKILL.md") "---`nname: missing-license-reference`ndescription: Missing license reference.`nlicense: Complete terms in LICENSE.txt`n---`n" -Encoding UTF8
  Expect-Failure "Expected missing license reference to fail."
  Assert-Contains $Result.Output "Missing referenced license file in oceans-skills: missing-license-reference"

  Write-Skill $FirstPartyRoot "metadata-mismatch" "different-name" "Name mismatch." | Out-Null
  Expect-Failure "Expected metadata mismatch to fail."
  Assert-Contains $Result.Output "risk: skill name does not match folder name"
  $BadFolder = Join-Path $FirstPartyRoot "bad folder"
  New-Item -ItemType Directory -Force -Path $BadFolder | Out-Null
  Set-Content (Join-Path $BadFolder "README.md") "missing" -Encoding UTF8
  Expect-Failure "Expected invalid folder to fail."
  Assert-Contains $Result.Output "risk: invalid skill folder name"

  $Secret = Write-Skill $FirstPartyRoot "secret-risk" "secret-risk" "Risk scan fixture."
  Add-Content (Join-Path $Secret "SKILL.md") "api_key=sk-example-not-a-real-secret" -Encoding UTF8
  Expect-Failure "Expected secret-like content to fail."
  Assert-Contains $Result.Output "secret-risk: risk: secret-like text"

  $ValidUtf8 = Write-Skill $FirstPartyRoot "valid-utf8" "valid-utf8" "Valid UTF-8 fixture."
  Add-Content (Join-Path $ValidUtf8 "SKILL.md") "中文内容应当通过严格 UTF-8 检查。" -Encoding UTF8
  $Result = Invoke-Validate
  Assert-NotContains $Result.Output "valid-utf8: risk: binary or unreadable file"

  $InvalidUtf8 = Join-Path $FirstPartyRoot "invalid-utf8"
  New-Item -ItemType Directory -Force -Path $InvalidUtf8 | Out-Null
  [System.IO.File]::WriteAllBytes((Join-Path $InvalidUtf8 "SKILL.md"), [byte[]](0xFF, 0xFE, 0x00))
  Expect-Failure "Expected invalid UTF-8 to fail."
  Assert-Contains $Result.Output "invalid-utf8: risk: binary or unreadable file"

  $Unterminated = Join-Path $FirstPartyRoot "unterminated-frontmatter"
  New-Item -ItemType Directory -Force -Path $Unterminated | Out-Null
  Set-Content (Join-Path $Unterminated "SKILL.md") "---`nname: unterminated-frontmatter`ndescription: This frontmatter never closes.`n" -Encoding UTF8
  Expect-Failure "Expected unterminated frontmatter to fail."
  Assert-Contains $Result.Output "risk: missing or unterminated skill frontmatter"

  $DuplicateKey = Join-Path $FirstPartyRoot "duplicate-key"
  New-Item -ItemType Directory -Force -Path $DuplicateKey | Out-Null
  Set-Content (Join-Path $DuplicateKey "SKILL.md") "---`nname: duplicate-key`nname: shadow-name`ndescription: Duplicate key fixture.`n---`n" -Encoding UTF8
  Expect-Failure "Expected duplicate frontmatter key to fail."
  Assert-Contains $Result.Output "risk: duplicate frontmatter key: name"

  $Block = Join-Path $FirstPartyRoot "block-description"
  New-Item -ItemType Directory -Force -Path $Block | Out-Null
  Set-Content (Join-Path $Block "SKILL.md") "---`nname: block-description`ndescription: |`n  Valid multiline description.`n---`n" -Encoding UTF8
  $Result = Invoke-Validate
  Assert-NotContains $Result.Output "Invalid skill metadata in oceans-skills: block-description"
  Write-Host "PowerShell validate duplicate test passed."
} finally { Remove-TestRoot }
