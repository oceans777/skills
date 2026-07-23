$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptRoot
$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "oceans-url-intake-test-$([Guid]::NewGuid().ToString('N'))"
$Upstream = Join-Path $TestRoot "upstream"
$OtherUpstream = Join-Path $TestRoot "other-upstream"
$FirstRepo = Join-Path $TestRoot "oceans"
$CommunityRepo = Join-Path $TestRoot "community"
$Catalog = Join-Path $TestRoot "catalog"
$Install = Join-Path $TestRoot "runtime\skills"
$OldTestMode = $env:OCEANS_TEST_MODE

function Invoke-Git([string[]] $Arguments) { $Output = & git @Arguments 2>&1; if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed.`n$($Output | Out-String)" } }
function Init-Repo([string] $Path) {
  New-Item -ItemType Directory -Force -Path $Path | Out-Null
  Invoke-Git @("init", "-q", $Path); Invoke-Git @("-C", $Path, "checkout", "-q", "-B", "main")
  Invoke-Git @("-C", $Path, "config", "user.email", "test@example.invalid"); Invoke-Git @("-C", $Path, "config", "user.name", "Test"); Invoke-Git @("-C", $Path, "config", "core.autocrlf", "false")
}
function Write-Utf8([string] $Path, [string[]] $Lines) { [System.IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null; [System.IO.File]::WriteAllLines($Path, $Lines, (New-Object System.Text.UTF8Encoding($false))) }
function Write-UpstreamSkill([string] $Repo, [string] $Version) {
  Write-Utf8 (Join-Path $Repo "skills\sample-import\SKILL.md") @("---", "name: sample-import", "description: Imported fixture skill.", "---", "version=$Version")
  Write-Utf8 (Join-Path $Repo "skills\sample-import\helper.txt") @("helper")
  Write-Utf8 (Join-Path $Repo "LICENSE") @("MIT fixture license")
}
function Assert-Contains([string] $Text, [string] $Expected) { if (-not $Text.Contains($Expected)) { throw "Expected output to contain: $Expected" } }
function Assert-FileContains([string] $Path, [string] $Expected) { if (-not (Get-Content $Path -Raw).Contains($Expected)) { throw "Expected $Path to contain: $Expected" } }
function Expect-Failure([scriptblock] $Operation, [string] $Message) { try { & $Operation; throw $Message } catch { if ($_.Exception.Message -eq $Message) { throw } } }

try {
  $env:OCEANS_TEST_MODE = "1"
  Init-Repo $Upstream; Write-UpstreamSkill $Upstream "one"; Invoke-Git @("-C", $Upstream, "add", "."); Invoke-Git @("-C", $Upstream, "commit", "-q", "-m", "initial")
  Invoke-Git @("-C", $Upstream, "checkout", "-q", "-b", "feature/skill")
  Add-Content (Join-Path $Upstream "skills\sample-import\helper.txt") "branch-marker" -Encoding UTF8
  Invoke-Git @("-C", $Upstream, "add", "."); Invoke-Git @("-C", $Upstream, "commit", "-q", "-m", "branch")
  Init-Repo $OtherUpstream; Write-UpstreamSkill $OtherUpstream "foreign"; Invoke-Git @("-C", $OtherUpstream, "add", "."); Invoke-Git @("-C", $OtherUpstream, "commit", "-q", "-m", "initial")
  Init-Repo $FirstRepo; New-Item -ItemType Directory -Force -Path (Join-Path $FirstRepo "skills") | Out-Null; Write-Utf8 (Join-Path $FirstRepo "skills\.gitkeep") @(); Invoke-Git @("-C", $FirstRepo, "add", "."); Invoke-Git @("-C", $FirstRepo, "commit", "-q", "-m", "initial")
  Init-Repo $CommunityRepo; New-Item -ItemType Directory -Force -Path (Join-Path $CommunityRepo "skills") | Out-Null; Write-Utf8 (Join-Path $CommunityRepo "skills\.gitkeep") @(); Invoke-Git @("-C", $CommunityRepo, "add", "."); Invoke-Git @("-C", $CommunityRepo, "commit", "-q", "-m", "initial")
  New-Item -ItemType Directory -Force -Path (Join-Path $Catalog "skills"), (Join-Path $Catalog "review-queue\oceans-skills"), (Join-Path $Catalog "review-queue\community-skills"), $Install | Out-Null

  $Output = (& (Join-Path $RepoRoot "scripts\add-skill-from-url.ps1") -Url "https://github.com/example/upstream/tree/feature/skill/skills/sample-import" -LocalRepository $Upstream -Target community -CatalogRoot $Catalog *>&1 | Out-String)
  Assert-Contains $Output "catalog-state: pending-review"
  Assert-Contains $Output "candidate-added: sample-import"
  if (Test-Path (Join-Path $CommunityRepo "skills\sample-import")) { throw "Intake wrote directly into active package repository." }
  $Review = Join-Path $Catalog "review-queue\community-skills\sample-import"
  foreach ($Required in @("SKILL.md", "UPSTREAM.md", "PATCHES.md", "LICENSE")) { if (-not (Test-Path (Join-Path $Review $Required))) { throw "Missing candidate file: $Required" } }
  Assert-FileContains (Join-Path $Review "SKILL.md") "version=one"
  Assert-FileContains (Join-Path $Catalog "skills\sample-import.skill") "candidate_upstream_ref=feature/skill"

  & (Join-Path $RepoRoot "scripts\validate-skills.ps1") -FirstPartySkillsRoot (Join-Path $FirstRepo "skills") -CommunitySkillsRoot (Join-Path $CommunityRepo "skills") -CatalogRoot $Catalog | Out-Null
  $InstallOutput = (& (Join-Path $RepoRoot "scripts\install-skills.ps1") -InstallRoot $Install -FirstPartySkillsRoot (Join-Path $FirstRepo "skills") -CommunitySkillsRoot (Join-Path $CommunityRepo "skills") -CatalogRoot $Catalog *>&1 | Out-String)
  if (Test-Path (Join-Path $Install "sample-import")) { throw "Pending new candidate was installed." }
  Assert-Contains $InstallOutput "Skipped pending-review skill: sample-import"

  & (Join-Path $RepoRoot "scripts\catalog-skill.ps1") activate -CatalogRoot $Catalog -FirstPartySkillsRoot (Join-Path $FirstRepo "skills") -CommunitySkillsRoot (Join-Path $CommunityRepo "skills") -Skill sample-import | Out-Null
  if (-not (Test-Path (Join-Path $CommunityRepo "skills\sample-import\SKILL.md"))) { throw "Approved candidate was not promoted." }
  & (Join-Path $RepoRoot "scripts\install-skills.ps1") -InstallRoot $Install -FirstPartySkillsRoot (Join-Path $FirstRepo "skills") -CommunitySkillsRoot (Join-Path $CommunityRepo "skills") -CatalogRoot $Catalog | Out-Null
  Assert-FileContains (Join-Path $Install "sample-import\SKILL.md") "version=one"

  Add-Content (Join-Path $Upstream "skills\sample-import\SKILL.md") "version=two" -Encoding UTF8
  Invoke-Git @("-C", $Upstream, "add", "."); Invoke-Git @("-C", $Upstream, "commit", "-q", "-m", "update")
  $Output = (& (Join-Path $RepoRoot "scripts\add-skill-from-url.ps1") -Url "https://github.com/example/upstream/tree/feature/skill/skills/sample-import" -LocalRepository $Upstream -Target community -CatalogRoot $Catalog -ReplaceExisting *>&1 | Out-String)
  Assert-Contains $Output "catalog-state: active"
  Assert-Contains $Output "active-package-preserved: sample-import"
  Assert-FileContains (Join-Path $CommunityRepo "skills\sample-import\SKILL.md") "version=one"
  & (Join-Path $RepoRoot "scripts\catalog-skill.ps1") reject -CatalogRoot $Catalog -Skill sample-import | Out-Null
  if (Test-Path $Review) { throw "Rejected update candidate remains." }

  Expect-Failure { & (Join-Path $RepoRoot "scripts\add-skill-from-url.ps1") -Url "https://github.com/other/upstream/tree/main/skills/sample-import" -LocalRepository $OtherUpstream -Target community -CatalogRoot $Catalog -ReplaceExisting | Out-Null } "Source repository change was accepted without explicit approval."
  Expect-Failure { & (Join-Path $RepoRoot "scripts\add-skill-from-url.ps1") -Url "https://github.com/example/upstream" -LocalRepository $Upstream -SkillPath "../escape" -Target community -CatalogRoot $Catalog | Out-Null } "Path traversal was accepted."
  $OldBudget = $env:OCEANS_INTAKE_MAX_FILES
  try {
    $env:OCEANS_INTAKE_MAX_FILES = "1"
    Expect-Failure { & (Join-Path $RepoRoot "scripts\add-skill-from-url.ps1") -Url "https://github.com/example/upstream/tree/feature/skill/skills/sample-import" -LocalRepository $Upstream -Target community -CatalogRoot $Catalog -ReplaceExisting | Out-Null } "File budget overflow was accepted."
  } finally { if ($null -eq $OldBudget) { Remove-Item Env:\OCEANS_INTAKE_MAX_FILES -ErrorAction SilentlyContinue } else { $env:OCEANS_INTAKE_MAX_FILES = $OldBudget } }
  Write-Host "PowerShell URL intake test passed."
} finally {
  if ($null -eq $OldTestMode) { Remove-Item Env:\OCEANS_TEST_MODE -ErrorAction SilentlyContinue } else { $env:OCEANS_TEST_MODE = $OldTestMode }
  if (Test-Path $TestRoot) { Remove-Item $TestRoot -Recurse -Force }
}
