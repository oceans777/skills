$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptRoot
$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "oceans-catalog-test-$([Guid]::NewGuid().ToString('N'))"
$First = Join-Path $TestRoot "oceans\skills"
$Community = Join-Path $TestRoot "community\skills"
$Catalog = Join-Path $TestRoot "catalog"
$Install = Join-Path $TestRoot "install"

function Write-Utf8NoBom([string]$Path, [string[]]$Lines) {
  [System.IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
  [System.IO.File]::WriteAllLines($Path, $Lines, (New-Object System.Text.UTF8Encoding($false)))
}
function Write-TestSkill([string]$Root, [string]$Name) {
  Write-Utf8NoBom (Join-Path $Root "$Name\SKILL.md") @("---", "name: $Name", "description: Catalog test skill.", "---")
}

try {
  foreach ($State in @("active", "pending-review", "deprecated", "archived", "blocked")) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Catalog $State) | Out-Null
  }
  Write-TestSkill $First "active-skill"
  Write-TestSkill $First "archived-skill"
  Write-TestSkill $Community "pending-skill"
  Write-Utf8NoBom (Join-Path $Community "pending-skill\UPSTREAM.md") @("upstream")
  Write-Utf8NoBom (Join-Path $Community "pending-skill\PATCHES.md") @("patches")
  Write-Utf8NoBom (Join-Path $Community "pending-skill\LICENSE") @("license")

  . (Join-Path $RepoRoot "scripts\skill-catalog.ps1")
  $Commit = "0123456789012345678901234567890123456789"
  Write-OceansCatalogRecord -CatalogRoot $Catalog -State active -SkillName active-skill -Repository oceans-skills -SourceUrl https://github.com/example/oceans -SourcePath skills/active-skill -SourceRef main -SourceCommit $Commit | Out-Null
  Write-OceansCatalogRecord -CatalogRoot $Catalog -State archived -SkillName archived-skill -Repository oceans-skills -SourceUrl https://github.com/example/oceans -SourcePath skills/archived-skill -SourceRef main -SourceCommit $Commit -Reason retired | Out-Null
  Write-OceansCatalogRecord -CatalogRoot $Catalog -State pending-review -SkillName pending-skill -Repository community-skills -SourceUrl https://github.com/example/community -SourcePath skills/pending-skill -SourceRef main -SourceCommit $Commit | Out-Null

  & (Join-Path $RepoRoot "scripts\validate-skills.ps1") -FirstPartySkillsRoot $First -CommunitySkillsRoot $Community -CatalogRoot $Catalog | Out-Null
  $Output = (& (Join-Path $RepoRoot "scripts\install-skills.ps1") -InstallRoot $Install -FirstPartySkillsRoot $First -CommunitySkillsRoot $Community -CatalogRoot $Catalog | Out-String)
  if (-not (Test-Path -LiteralPath (Join-Path $Install "active-skill\SKILL.md") -PathType Leaf)) { throw "Active skill was not installed." }
  if (Test-Path -LiteralPath (Join-Path $Install "archived-skill")) { throw "Archived skill must not be installed." }
  if (Test-Path -LiteralPath (Join-Path $Install "pending-skill")) { throw "Pending skill must not be installed." }
  if ($Output -notmatch 'Skipped archived skill: archived-skill') { throw "Archive skip was not reported." }
  if ($Output -notmatch 'Skipped pending-review skill: pending-skill') { throw "Pending skip was not reported." }

  & (Join-Path $RepoRoot "scripts\catalog-skill.ps1") restore -CatalogRoot $Catalog -Skill archived-skill | Out-Null
  if (-not (Test-Path -LiteralPath (Join-Path $Catalog "active\archived-skill.skill") -PathType Leaf)) { throw "Restore failed." }
  & (Join-Path $RepoRoot "scripts\catalog-skill.ps1") archive -CatalogRoot $Catalog -Skill archived-skill -Reason "retired again" | Out-Null
  if (-not (Test-Path -LiteralPath (Join-Path $Catalog "archived\archived-skill.skill") -PathType Leaf)) { throw "Archive failed." }

  Write-Host "PowerShell skill catalog test passed."
} finally {
  if (Test-Path -LiteralPath $TestRoot) { Remove-Item -LiteralPath $TestRoot -Recurse -Force }
}
