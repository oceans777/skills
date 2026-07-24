$ErrorActionPreference = "Stop"

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptRoot
$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "oceans-runtime-reconcile-test-$([Guid]::NewGuid().ToString('N'))"
$First = Join-Path $TestRoot "oceans\skills"
$Community = Join-Path $TestRoot "community\skills"
$Catalog = Join-Path $TestRoot "catalog"
$RootA = Join-Path $TestRoot "runtime-a\skills"
$RootB = Join-Path $TestRoot "runtime-b\skills"
$RootC = Join-Path $TestRoot "runtime-c\skills"
$CommitA = "0123456789012345678901234567890123456789"

$OldEnvironment = @{
  OCEANS_RUNTIME_ROOTS_FILE = $env:OCEANS_RUNTIME_ROOTS_FILE
  CODEX_HOME = $env:CODEX_HOME
  AGENTS_HOME = $env:AGENTS_HOME
  CLAUDE_HOME = $env:CLAUDE_HOME
  OPENCLAW_HOME = $env:OPENCLAW_HOME
  HERMES_HOME = $env:HERMES_HOME
}
$env:OCEANS_RUNTIME_ROOTS_FILE = Join-Path $TestRoot "runtime-roots"
$env:CODEX_HOME = Join-Path $TestRoot "missing-codex"
$env:AGENTS_HOME = Join-Path $TestRoot "missing-agents"
$env:CLAUDE_HOME = Join-Path $TestRoot "missing-claude"
$env:OPENCLAW_HOME = Join-Path $TestRoot "missing-openclaw"
$env:HERMES_HOME = Join-Path $TestRoot "missing-hermes"

function Write-Utf8NoBom {
  param([string] $Path, [string[]] $Lines)
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
  [System.IO.File]::WriteAllLines($Path, $Lines, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-Skill {
  param([string] $Root, [string] $Name, [string] $Version)
  Write-Utf8NoBom -Path (Join-Path (Join-Path $Root $Name) "SKILL.md") -Lines @(
    "---",
    "name: $Name",
    "description: Runtime reconciliation fixture.",
    "---",
    "version=$Version"
  )
}

function Assert-FileContains {
  param([string] $Path, [string] $Expected)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing file: $Path" }
  if (-not (Get-Content -LiteralPath $Path -Raw).Contains($Expected)) { throw "Expected $Path to contain: $Expected" }
}

try {
  New-Item -ItemType Directory -Force -Path `
    $First, $Community, (Join-Path $Catalog "skills"), `
    (Join-Path $Catalog "review-queue\oceans-skills"), `
    (Join-Path $Catalog "review-queue\community-skills"), `
    $RootA, $RootB | Out-Null

  . (Join-Path $RepoRoot "scripts\skill-publish-rules.ps1")
  . (Join-Path $RepoRoot "scripts\skill-catalog.ps1")

  Write-Skill -Root $First -Name "danger-skill" -Version "safe"
  Write-Skill -Root $First -Name "unrelated-skill" -Version "stable"

  foreach ($SkillName in @("danger-skill", "unrelated-skill")) {
    $Digest = Get-OceansSkillContentSha256 -SkillPath (Join-Path $First $SkillName)
    Write-OceansCatalogRecord `
      -CatalogRoot $Catalog -SkillName $SkillName -Status "active" -PackageRepository "oceans-skills" `
      -UpstreamRepository "https://github.com/example/oceans" -UpstreamPath "skills/$SkillName" `
      -UpstreamRef "main" -UpstreamCommit $CommitA -ContentSha256 $Digest `
      -TransitionNote "fixture active" | Out-Null
  }

  & (Join-Path $RepoRoot "scripts\install-skills.ps1") `
    -InstallRoot $RootA -FirstPartySkillsRoot $First -CommunitySkillsRoot $Community -CatalogRoot $Catalog | Out-Null
  & (Join-Path $RepoRoot "scripts\install-skills.ps1") `
    -InstallRoot $RootB -FirstPartySkillsRoot $First -CommunitySkillsRoot $Community -CatalogRoot $Catalog | Out-Null

  $RegistryLines = @(Get-Content -LiteralPath $env:OCEANS_RUNTIME_ROOTS_FILE)
  if ($RegistryLines.Count -ne 2) { throw "Custom runtime roots were not persisted." }
  Assert-FileContains -Path (Join-Path $RootA "danger-skill\.oceans-skill-source") -Expected "content_sha256="
  Assert-FileContains -Path (Join-Path $RootA "danger-skill\.oceans-skill-source") -Expected "skill_name=danger-skill"

  Remove-Item -LiteralPath (Join-Path $RootA "danger-skill\.oceans-skill-source") -Force
  $UnrelatedRecord = Join-Path $Catalog "skills\unrelated-skill.skill"
  $UnrelatedBackup = Join-Path $TestRoot "unrelated-record"
  Copy-Item -LiteralPath $UnrelatedRecord -Destination $UnrelatedBackup
  Add-Content -LiteralPath $UnrelatedRecord -Value "unknown_field=value" -Encoding UTF8

  $BlockFailed = $false
  try {
    & (Join-Path $RepoRoot "scripts\catalog-skill.ps1") block `
      -CatalogRoot $Catalog -FirstPartySkillsRoot $First -CommunitySkillsRoot $Community `
      -Skill "danger-skill" -Reason "security-incident" | Out-Null
  } catch {
    $BlockFailed = $true
    Write-Utf8NoBom -Path (Join-Path $TestRoot "block-error") -Lines @($_.Exception.Message)
  }
  if (-not $BlockFailed) { throw "Block incorrectly reported complete success despite an unmanaged runtime conflict." }

  $DangerRecord = Get-OceansCatalogRecord -Path (Join-Path $Catalog "skills\danger-skill.skill")
  if ([string]$DangerRecord["status"] -ne "blocked") { throw "Block state was not committed." }
  if (-not (Test-Path -LiteralPath (Join-Path $RootA "danger-skill\SKILL.md") -PathType Leaf)) { throw "Unmanaged conflicting copy was removed." }
  if (Test-Path -LiteralPath (Join-Path $RootB "danger-skill")) { throw "A later managed runtime root was not reconciled after an earlier conflict." }
  $DisabledB = Join-Path $TestRoot "runtime-b\.oceans-disabled\skills\blocked\danger-skill\SKILL.md"
  if (-not (Test-Path -LiteralPath $DisabledB -PathType Leaf)) { throw "Managed blocked copy was not preserved." }
  Assert-FileContains -Path (Join-Path $TestRoot "block-error") -Expected "one or more runtime roots were not reconciled"

  Remove-Item -LiteralPath (Join-Path $RootA "danger-skill") -Recurse -Force
  Copy-Item -LiteralPath $UnrelatedBackup -Destination $UnrelatedRecord -Force
  & (Join-Path $RepoRoot "scripts\catalog-skill.ps1") unblock `
    -CatalogRoot $Catalog -FirstPartySkillsRoot $First -CommunitySkillsRoot $Community `
    -Skill "danger-skill" -Reason "remediated" | Out-Null
  Assert-FileContains -Path (Join-Path $RootA "danger-skill\SKILL.md") -Expected "version=safe"
  Assert-FileContains -Path (Join-Path $RootB "danger-skill\SKILL.md") -Expected "version=safe"

  Add-Content -LiteralPath (Join-Path $First "danger-skill\SKILL.md") -Value "tampered-source" -Encoding UTF8
  $TamperFailed = $false
  try {
    & (Join-Path $RepoRoot "scripts\install-skills.ps1") `
      -InstallRoot $RootC -FirstPartySkillsRoot $First -CommunitySkillsRoot $Community -CatalogRoot $Catalog `
      -TargetSkill "danger-skill" -LifecycleReconcile | Out-Null
  } catch {
    $TamperFailed = $true
    Write-Utf8NoBom -Path (Join-Path $TestRoot "tamper-error") -Lines @($_.Exception.Message)
  }
  if (-not $TamperFailed) { throw "Runtime installation accepted a source package that no longer matched the catalog fingerprint." }
  if (Test-Path -LiteralPath (Join-Path $RootC "danger-skill")) { throw "Tampered source was installed." }
  Assert-FileContains -Path (Join-Path $TestRoot "tamper-error") -Expected "Published package content SHA-256 mismatch"

  Write-Host "PowerShell runtime reconciliation test passed."
} finally {
  foreach ($Name in $OldEnvironment.Keys) {
    $OldValue = $OldEnvironment[$Name]
    if ($null -eq $OldValue) { Remove-Item "Env:\$Name" -ErrorAction SilentlyContinue }
    else { Set-Item "Env:\$Name" $OldValue }
  }
  if (Test-Path -LiteralPath $TestRoot) { Remove-Item -LiteralPath $TestRoot -Recurse -Force }
}
