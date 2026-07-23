$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptRoot
$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "oceans-url-intake-test-$([Guid]::NewGuid().ToString('N'))"
$Upstream = Join-Path $TestRoot "upstream"
$FirstRepo = Join-Path $TestRoot "oceans"
$CommunityRepo = Join-Path $TestRoot "community"
$Catalog = Join-Path $TestRoot "catalog"
$Install = Join-Path $TestRoot "install"

function Invoke-Git([string[]]$Arguments) {
  $Output = & git @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed.`n$($Output | Out-String)" }
}
function Init-Repo([string]$Path) {
  New-Item -ItemType Directory -Force -Path $Path | Out-Null
  Invoke-Git @("init", "-q", $Path)
  Invoke-Git @("-C", $Path, "checkout", "-q", "-B", "main")
  Invoke-Git @("-C", $Path, "config", "user.email", "test@example.invalid")
  Invoke-Git @("-C", $Path, "config", "user.name", "Test")
  Invoke-Git @("-C", $Path, "config", "core.autocrlf", "false")
}
function Write-Utf8NoBom([string]$Path, [string[]]$Lines) {
  [System.IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
  [System.IO.File]::WriteAllLines($Path, $Lines, (New-Object System.Text.UTF8Encoding($false)))
}

try {
  Init-Repo $Upstream
  Write-Utf8NoBom (Join-Path $Upstream "skills\sample-import\SKILL.md") @("---", "name: sample-import", "description: Imported fixture skill.", "---")
  Write-Utf8NoBom (Join-Path $Upstream "LICENSE") @("MIT fixture license")
  Invoke-Git @("-C", $Upstream, "add", ".")
  Invoke-Git @("-C", $Upstream, "commit", "-q", "-m", "initial")

  Init-Repo $FirstRepo
  Write-Utf8NoBom (Join-Path $FirstRepo "skills\.gitkeep") @()
  Invoke-Git @("-C", $FirstRepo, "add", ".")
  Invoke-Git @("-C", $FirstRepo, "commit", "-q", "-m", "initial")

  Init-Repo $CommunityRepo
  Write-Utf8NoBom (Join-Path $CommunityRepo "skills\.gitkeep") @()
  Invoke-Git @("-C", $CommunityRepo, "add", ".")
  Invoke-Git @("-C", $CommunityRepo, "commit", "-q", "-m", "initial")

  foreach ($State in @("active", "pending-review", "deprecated", "archived", "blocked")) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Catalog $State) | Out-Null
  }

  $Output = (& (Join-Path $RepoRoot "scripts\add-skill-from-url.ps1") `
    -Url "https://github.com/example/upstream/tree/main/skills/sample-import" `
    -LocalRepository $Upstream -Target community `
    -FirstPartySkillsRoot (Join-Path $FirstRepo "skills") `
    -CommunitySkillsRoot (Join-Path $CommunityRepo "skills") `
    -CatalogRoot $Catalog | Out-String)
  if ($Output -notmatch 'catalog-state: pending-review') { throw "Intake did not create pending review state." }
  foreach ($Required in @("SKILL.md", "UPSTREAM.md", "PATCHES.md", "LICENSE")) {
    if (-not (Test-Path -LiteralPath (Join-Path $CommunityRepo "skills\sample-import\$Required") -PathType Leaf)) { throw "Missing staged file: $Required" }
  }
  if (-not (Test-Path -LiteralPath (Join-Path $Catalog "pending-review\sample-import.skill") -PathType Leaf)) { throw "Missing pending catalog record." }

  & (Join-Path $RepoRoot "scripts\validate-skills.ps1") -FirstPartySkillsRoot (Join-Path $FirstRepo "skills") -CommunitySkillsRoot (Join-Path $CommunityRepo "skills") -CatalogRoot $Catalog | Out-Null
  $InstallOutput = (& (Join-Path $RepoRoot "scripts\install-skills.ps1") -InstallRoot $Install -FirstPartySkillsRoot (Join-Path $FirstRepo "skills") -CommunitySkillsRoot (Join-Path $CommunityRepo "skills") -CatalogRoot $Catalog | Out-String)
  if (Test-Path -LiteralPath (Join-Path $Install "sample-import")) { throw "Pending imported skill must not install." }
  if ($InstallOutput -notmatch 'Skipped pending-review skill: sample-import') { throw "Pending intake skip was not reported." }

  & (Join-Path $RepoRoot "scripts\catalog-skill.ps1") activate -CatalogRoot $Catalog -Skill sample-import | Out-Null
  & (Join-Path $RepoRoot "scripts\install-skills.ps1") -InstallRoot $Install -FirstPartySkillsRoot (Join-Path $FirstRepo "skills") -CommunitySkillsRoot (Join-Path $CommunityRepo "skills") -CatalogRoot $Catalog | Out-Null
  if (-not (Test-Path -LiteralPath (Join-Path $Install "sample-import\SKILL.md") -PathType Leaf)) { throw "Activated imported skill was not installed." }

  Write-Host "PowerShell URL intake test passed."
} finally {
  if (Test-Path -LiteralPath $TestRoot) { Remove-Item -LiteralPath $TestRoot -Recurse -Force }
}
