$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptRoot
$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "oceans-catalog-test-$([Guid]::NewGuid().ToString('N'))"
$First = Join-Path $TestRoot "oceans\skills"
$Community = Join-Path $TestRoot "community\skills"
$Catalog = Join-Path $TestRoot "catalog"
$Install = Join-Path $TestRoot "runtime\skills"
$CommitA = "0123456789012345678901234567890123456789"
$CommitB = "abcdefabcdefabcdefabcdefabcdefabcdefabcd"

function Fail([string] $Message) { throw $Message }
function Assert-Contains([string] $Text, [string] $Expected) { if (-not $Text.Contains($Expected)) { Fail "Expected output to contain: $Expected" } }
function Assert-FileContains([string] $Path, [string] $Expected) { if (-not (Get-Content -LiteralPath $Path -Raw).Contains($Expected)) { Fail "Expected $Path to contain: $Expected" } }
function Write-Skill([string] $Root, [string] $Name, [string] $Version) {
  $Path = Join-Path $Root $Name
  New-Item -ItemType Directory -Force -Path $Path | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $Path "SKILL.md"), "---`nname: $Name`ndescription: Catalog lifecycle fixture.`n---`nversion=$Version`n", (New-Object System.Text.UTF8Encoding($false)))
  return $Path
}

try {
  New-Item -ItemType Directory -Force -Path $First, $Community, (Join-Path $Catalog "skills"), (Join-Path $Catalog "review-queue\oceans-skills"), (Join-Path $Catalog "review-queue\community-skills"), $Install | Out-Null
  . (Join-Path $RepoRoot "scripts\skill-publish-rules.ps1")
  . (Join-Path $RepoRoot "scripts\skill-catalog.ps1")
  foreach ($Fixture in @(
      @{ Name = "active-skill"; Status = "active"; Version = "old"; Reason = ""; Replacement = "" },
      @{ Name = "archived-skill"; Status = "archived"; Version = "archived"; Reason = "retired"; Replacement = "active-skill" },
      @{ Name = "blocked-skill"; Status = "blocked"; Version = "blocked"; Reason = "security-incident"; Replacement = "" },
      @{ Name = "deprecated-skill"; Status = "deprecated"; Version = "deprecated"; Reason = "superseded"; Replacement = "active-skill" }
    )) {
    $FixturePath = Write-Skill $First $Fixture.Name $Fixture.Version
    $FixtureDigest = Get-OceansSkillContentSha256 -SkillPath $FixturePath
    Write-OceansCatalogRecord -CatalogRoot $Catalog -SkillName $Fixture.Name -Status $Fixture.Status -PackageRepository "oceans-skills" `
      -UpstreamRepository "https://github.com/example/oceans" -UpstreamPath "skills/$($Fixture.Name)" -UpstreamRef "main" -UpstreamCommit $CommitA `
      -ContentSha256 $FixtureDigest -Replacement $Fixture.Replacement -StatusReason $Fixture.Reason -TransitionNote "fixture $($Fixture.Status)" | Out-Null
  }

  $InstalledArchive = Join-Path $Install "archived-skill"
  New-Item -ItemType Directory -Force -Path $InstalledArchive | Out-Null
  Set-Content (Join-Path $InstalledArchive "SKILL.md") "managed-archive" -Encoding UTF8
  Set-Content (Join-Path $InstalledArchive ".oceans-skill-source") "source_repository=oceans-skills" -Encoding UTF8
  $InstalledBlocked = Join-Path $Install "blocked-skill"
  New-Item -ItemType Directory -Force -Path $InstalledBlocked | Out-Null
  Set-Content (Join-Path $InstalledBlocked "SKILL.md") "managed-blocked-copy" -Encoding UTF8
  Set-Content (Join-Path $InstalledBlocked ".oceans-skill-source") "source_repository=oceans-skills" -Encoding UTF8
  $InstalledDeprecated = Join-Path $Install "deprecated-skill"
  New-Item -ItemType Directory -Force -Path $InstalledDeprecated | Out-Null
  Set-Content (Join-Path $InstalledDeprecated "SKILL.md") "installed-deprecated-version" -Encoding UTF8
  Set-Content (Join-Path $InstalledDeprecated ".oceans-skill-source") "source_repository=oceans-skills" -Encoding UTF8

  & (Join-Path $RepoRoot "scripts\validate-skills.ps1") -FirstPartySkillsRoot $First -CommunitySkillsRoot $Community -CatalogRoot $Catalog | Out-Null
  $Output = (& (Join-Path $RepoRoot "scripts\install-skills.ps1") -InstallRoot $Install -FirstPartySkillsRoot $First -CommunitySkillsRoot $Community -CatalogRoot $Catalog *>&1 | Out-String)
  if (-not (Test-Path (Join-Path $Install "active-skill\SKILL.md"))) { Fail "Active skill was not installed." }
  if (Test-Path $InstalledArchive) { Fail "Managed archived copy remained active." }
  if (Test-Path $InstalledBlocked) { Fail "Managed blocked copy remained active." }
  $DisabledArchive = Join-Path $TestRoot "runtime\.oceans-disabled\skills\archived\archived-skill\SKILL.md"
  $DisabledBlocked = Join-Path $TestRoot "runtime\.oceans-disabled\skills\blocked\blocked-skill\SKILL.md"
  if (-not (Test-Path $DisabledArchive)) { Fail "Managed archived copy was not preserved." }
  if (-not (Test-Path $DisabledBlocked)) { Fail "Managed blocked copy was not preserved." }
  Assert-Contains $Output "Disabled managed archived skill: archived-skill"
  Assert-Contains $Output "Disabled managed blocked skill: blocked-skill"
  Assert-Contains $Output "Retained deprecated managed skill without updating: deprecated-skill"
  Assert-FileContains (Join-Path $InstalledDeprecated "SKILL.md") "installed-deprecated-version"

  & (Join-Path $RepoRoot "scripts\catalog-skill.ps1") restore -CatalogRoot $Catalog -FirstPartySkillsRoot $First -CommunitySkillsRoot $Community -InstallRoot $Install -Skill archived-skill | Out-Null
  $RecordPath = Get-OceansCatalogRecordPath -CatalogRoot $Catalog -SkillName "archived-skill"
  $Record = Get-OceansCatalogRecord -Path $RecordPath
  if ($Record.status -ne "active" -or $Record.status_reason -or $Record.replacement) { Fail "Restore kept stale lifecycle metadata." }
  Assert-FileContains (Join-Path $Install "archived-skill\SKILL.md") "version=archived"

  & (Join-Path $RepoRoot "scripts\catalog-skill.ps1") block -CatalogRoot $Catalog -FirstPartySkillsRoot $First -CommunitySkillsRoot $Community -InstallRoot $Install -Skill archived-skill -Reason reblocked | Out-Null
  if (Test-Path (Join-Path $Install "archived-skill")) { Fail "Block did not immediately disable the managed runtime copy." }
  try { & (Join-Path $RepoRoot "scripts\catalog-skill.ps1") restore -CatalogRoot $Catalog -Skill archived-skill | Out-Null; Fail "Blocked skill was restored through ordinary restore." } catch { }
  try { & (Join-Path $RepoRoot "scripts\catalog-skill.ps1") unblock -CatalogRoot $Catalog -Skill archived-skill | Out-Null; Fail "Unblock succeeded without repair reason." } catch { }
  & (Join-Path $RepoRoot "scripts\catalog-skill.ps1") unblock -CatalogRoot $Catalog -FirstPartySkillsRoot $First -CommunitySkillsRoot $Community -InstallRoot $Install -Skill archived-skill -Reason remediated | Out-Null
  Assert-FileContains (Join-Path $Install "archived-skill\SKILL.md") "version=archived"

  Remove-Item (Join-Path $Install "archived-skill\.oceans-skill-source") -Force
  try {
    & (Join-Path $RepoRoot "scripts\catalog-skill.ps1") block -CatalogRoot $Catalog -FirstPartySkillsRoot $First -CommunitySkillsRoot $Community -InstallRoot $Install -Skill archived-skill -Reason second-incident | Out-Null
    Fail "Block incorrectly reported success for an unmanaged local copy."
  } catch {
    if ($_ -notmatch "runtime reconciliation failed" -and $_ -notmatch "blocked-unmanaged-conflict") { throw }
  }
  Assert-FileContains (Join-Path $Install "archived-skill\SKILL.md") "version=archived"
  $Record = Get-OceansCatalogRecord -Path $RecordPath
  if ($Record.status -ne "blocked") { Fail "Security state did not remain blocked after unmanaged runtime conflict." }

  $ReviewRoot = Join-Path $Catalog "review-queue\oceans-skills"
  $CandidatePath = Write-Skill $ReviewRoot "active-skill" "candidate"
  $CandidateDigest = Get-OceansSkillContentSha256 -SkillPath $CandidatePath
  $ActiveRecordPath = Get-OceansCatalogRecordPath -CatalogRoot $Catalog -SkillName "active-skill"
  $ActiveRecord = Get-OceansCatalogRecord -Path $ActiveRecordPath
  Write-OceansCatalogRecord -CatalogRoot $Catalog -SkillName "active-skill" -Status "active" -PackageRepository "oceans-skills" `
    -UpstreamRepository "https://github.com/example/oceans" -UpstreamPath "skills/active-skill" -UpstreamRef main -UpstreamCommit $CommitA `
    -ContentSha256 ([string]$ActiveRecord["content_sha256"]) `
    -CandidateUpstreamRepository "https://github.com/example/upstream" -CandidateUpstreamPath skill -CandidateUpstreamRef main -CandidateUpstreamCommit $CommitB `
    -CandidateContentSha256 $CandidateDigest -TransitionNote "queued candidate" | Out-Null
  & (Join-Path $RepoRoot "scripts\install-skills.ps1") -InstallRoot $Install -FirstPartySkillsRoot $First -CommunitySkillsRoot $Community -CatalogRoot $Catalog | Out-Null
  Assert-FileContains (Join-Path $Install "active-skill\SKILL.md") "version=old"

  Add-Content (Join-Path $CandidatePath "SKILL.md") "tampered-after-review" -Encoding UTF8
  try {
    & (Join-Path $RepoRoot "scripts\catalog-skill.ps1") activate -CatalogRoot $Catalog -FirstPartySkillsRoot $First -CommunitySkillsRoot $Community -Skill active-skill | Out-Null
    Fail "Tampered candidate was activated."
  } catch {
    if ($_ -notmatch "content changed" -and $_ -notmatch "SHA-256") { throw }
  }
  Write-Skill $ReviewRoot "active-skill" "candidate" | Out-Null

  & (Join-Path $RepoRoot "scripts\catalog-skill.ps1") activate -CatalogRoot $Catalog -FirstPartySkillsRoot $First -CommunitySkillsRoot $Community -Skill active-skill | Out-Null
  Assert-FileContains (Join-Path $First "active-skill\SKILL.md") "version=candidate"
  if (Test-Path (Join-Path $ReviewRoot "active-skill")) { Fail "Activated candidate remained in review queue." }
  $Record = Get-OceansCatalogRecord -Path $ActiveRecordPath
  if ($Record.upstream_commit -ne $CommitB -or $Record.candidate_upstream_commit) { Fail "Candidate provenance promotion failed." }
  if ($Record.content_sha256 -ne $CandidateDigest -or $Record.candidate_content_sha256) { Fail "Candidate content fingerprint promotion failed." }
  & (Join-Path $RepoRoot "scripts\install-skills.ps1") -InstallRoot $Install -FirstPartySkillsRoot $First -CommunitySkillsRoot $Community -CatalogRoot $Catalog | Out-Null
  Assert-FileContains (Join-Path $Install "active-skill\SKILL.md") "version=candidate"

  $PendingPath = Write-Skill $ReviewRoot "pending-skill" "candidate"
  $PendingDigest = Get-OceansSkillContentSha256 -SkillPath $PendingPath
  Write-OceansCatalogRecord -CatalogRoot $Catalog -SkillName "pending-skill" -Status "pending-review" -PackageRepository "oceans-skills" `
    -CandidateUpstreamRepository "https://github.com/example/upstream" -CandidateUpstreamPath skill -CandidateUpstreamRef main -CandidateUpstreamCommit $CommitB `
    -CandidateContentSha256 $PendingDigest -TransitionNote "new candidate" | Out-Null
  & (Join-Path $RepoRoot "scripts\catalog-skill.ps1") reject -CatalogRoot $Catalog -Skill pending-skill | Out-Null
  if (Test-Path (Get-OceansCatalogRecordPath -CatalogRoot $Catalog -SkillName "pending-skill")) { Fail "Rejected new skill record remains." }
  if (Test-Path (Join-Path $ReviewRoot "pending-skill")) { Fail "Rejected new candidate remains." }

  $RecordPath = $ActiveRecordPath
  Copy-Item $RecordPath (Join-Path $TestRoot "record-backup")
  Add-Content $RecordPath "unknown_field=value" -Encoding UTF8
  try { & (Join-Path $RepoRoot "scripts\validate-skills.ps1") -FirstPartySkillsRoot $First -CommunitySkillsRoot $Community -CatalogRoot $Catalog | Out-Null; Fail "Unknown catalog field passed validation." } catch { if ($_ -notmatch "Validation failed") { throw } }
  Copy-Item (Join-Path $TestRoot "record-backup") $RecordPath -Force
  (Get-Content -LiteralPath $RecordPath) -replace '^upstream_commit=.*$', 'upstream_commit=abc123' | Set-Content -LiteralPath $RecordPath -Encoding UTF8
  try { & (Join-Path $RepoRoot "scripts\validate-skills.ps1") -FirstPartySkillsRoot $First -CommunitySkillsRoot $Community -CatalogRoot $Catalog | Out-Null; Fail "Short commit hash passed validation." } catch { if ($_ -notmatch "Validation failed") { throw } }
  Copy-Item (Join-Path $TestRoot "record-backup") $RecordPath -Force
  New-Item -ItemType Directory -Force -Path (Join-Path $Catalog ".locks\active-skill.lock") | Out-Null
  try { & (Join-Path $RepoRoot "scripts\catalog-skill.ps1") deprecate -CatalogRoot $Catalog -Skill active-skill -Reason locked | Out-Null; Fail "Concurrent mutation ignored lock." } catch { }
  Remove-Item (Join-Path $Catalog ".locks\active-skill.lock") -Recurse -Force
  Write-Host "PowerShell skill catalog test passed."
} finally { if (Test-Path $TestRoot) { Remove-Item $TestRoot -Recurse -Force } }
