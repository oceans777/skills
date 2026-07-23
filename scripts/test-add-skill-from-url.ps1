$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptRoot
$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "oceans-url-intake-test-$([Guid]::NewGuid().ToString('N'))"
$Upstream = Join-Path $TestRoot "upstream"
$FirstRepo = Join-Path $TestRoot "oceans"
$CommunityRepo = Join-Path $TestRoot "community"
$Catalog = Join-Path $TestRoot "catalog"
$Install = Join-Path $TestRoot "install"

function Invoke-Git {
  param([Parameter(Mandatory = $true)][string[]] $Arguments)
  $Output = & git @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "git $($Arguments -join ' ') failed.`n$($Output | Out-String)"
  }
}

function Init-Repo {
  param([Parameter(Mandatory = $true)][string] $Path)
  New-Item -ItemType Directory -Force -Path $Path | Out-Null
  Invoke-Git -Arguments @("init", "-q", $Path)
  Invoke-Git -Arguments @("-C", $Path, "checkout", "-q", "-B", "main")
  Invoke-Git -Arguments @("-C", $Path, "config", "user.email", "test@example.invalid")
  Invoke-Git -Arguments @("-C", $Path, "config", "user.name", "Test")
  Invoke-Git -Arguments @("-C", $Path, "config", "core.autocrlf", "false")
}

function Write-Utf8NoBom {
  param(
    [Parameter(Mandatory = $true)][string] $Path,
    [Parameter(Mandatory = $true)][string[]] $Lines
  )
  [System.IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
  [System.IO.File]::WriteAllLines($Path, $Lines, (New-Object System.Text.UTF8Encoding($false)))
}

try {
  Init-Repo -Path $Upstream
  Write-Utf8NoBom -Path (Join-Path $Upstream "skills\sample-import\SKILL.md") -Lines @(
    "---",
    "name: sample-import",
    "description: Imported fixture skill.",
    "---"
  )
  Write-Utf8NoBom -Path (Join-Path $Upstream "LICENSE") -Lines @("MIT fixture license")
  Invoke-Git -Arguments @("-C", $Upstream, "add", ".")
  Invoke-Git -Arguments @("-C", $Upstream, "commit", "-q", "-m", "initial")

  Init-Repo -Path $FirstRepo
  $FirstSkillsRoot = Join-Path $FirstRepo "skills"
  New-Item -ItemType Directory -Force -Path $FirstSkillsRoot | Out-Null
  New-Item -ItemType File -Force -Path (Join-Path $FirstSkillsRoot ".gitkeep") | Out-Null
  Invoke-Git -Arguments @("-C", $FirstRepo, "add", ".")
  Invoke-Git -Arguments @("-C", $FirstRepo, "commit", "-q", "-m", "initial")

  Init-Repo -Path $CommunityRepo
  $CommunitySkillsRoot = Join-Path $CommunityRepo "skills"
  New-Item -ItemType Directory -Force -Path $CommunitySkillsRoot | Out-Null
  New-Item -ItemType File -Force -Path (Join-Path $CommunitySkillsRoot ".gitkeep") | Out-Null
  Invoke-Git -Arguments @("-C", $CommunityRepo, "add", ".")
  Invoke-Git -Arguments @("-C", $CommunityRepo, "commit", "-q", "-m", "initial")

  foreach ($State in @("active", "pending-review", "deprecated", "archived", "blocked")) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Catalog $State) | Out-Null
  }

  $Output = (& (Join-Path $RepoRoot "scripts\add-skill-from-url.ps1") `
    -Url "https://github.com/example/upstream/tree/main/skills/sample-import" `
    -LocalRepository $Upstream `
    -Target community `
    -FirstPartySkillsRoot $FirstSkillsRoot `
    -CommunitySkillsRoot $CommunitySkillsRoot `
    -CatalogRoot $Catalog | Out-String)
  if ($Output -notmatch 'catalog-state: pending-review') {
    throw "Intake did not create pending review state."
  }

  foreach ($Required in @("SKILL.md", "UPSTREAM.md", "PATCHES.md", "LICENSE")) {
    $RequiredPath = Join-Path $CommunitySkillsRoot "sample-import\$Required"
    if (-not (Test-Path -LiteralPath $RequiredPath -PathType Leaf)) {
      throw "Missing staged file: $Required"
    }
  }
  if (-not (Test-Path -LiteralPath (Join-Path $Catalog "pending-review\sample-import.skill") -PathType Leaf)) {
    throw "Missing pending catalog record."
  }

  & (Join-Path $RepoRoot "scripts\validate-skills.ps1") `
    -FirstPartySkillsRoot $FirstSkillsRoot `
    -CommunitySkillsRoot $CommunitySkillsRoot `
    -CatalogRoot $Catalog | Out-Null

  $InstallOutput = (& (Join-Path $RepoRoot "scripts\install-skills.ps1") `
    -InstallRoot $Install `
    -FirstPartySkillsRoot $FirstSkillsRoot `
    -CommunitySkillsRoot $CommunitySkillsRoot `
    -CatalogRoot $Catalog | Out-String)
  if (Test-Path -LiteralPath (Join-Path $Install "sample-import")) {
    throw "Pending imported skill must not install."
  }
  if ($InstallOutput -notmatch 'Skipped pending-review skill: sample-import') {
    throw "Pending intake skip was not reported."
  }

  & (Join-Path $RepoRoot "scripts\catalog-skill.ps1") `
    -Action activate `
    -CatalogRoot $Catalog `
    -Skill sample-import | Out-Null

  & (Join-Path $RepoRoot "scripts\install-skills.ps1") `
    -InstallRoot $Install `
    -FirstPartySkillsRoot $FirstSkillsRoot `
    -CommunitySkillsRoot $CommunitySkillsRoot `
    -CatalogRoot $Catalog | Out-Null
  if (-not (Test-Path -LiteralPath (Join-Path $Install "sample-import\SKILL.md") -PathType Leaf)) {
    throw "Activated imported skill was not installed."
  }

  Write-Host "PowerShell URL intake test passed."
} finally {
  if (Test-Path -LiteralPath $TestRoot) {
    Remove-Item -LiteralPath $TestRoot -Recurse -Force
  }
}
