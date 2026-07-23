param(
  [switch] $DryRun,
  [string] $RepoRoot,
  [string] $FirstPartyRepoPath,
  [string] $CommunityRepoPath,
  [string] $CatalogPath = "catalog"
)

$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptRoot "common.ps1")

function Resolve-AbsolutePath {
  param([Parameter(Mandatory = $true)][string] $Path)
  if (Test-Path -LiteralPath $Path) { return [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).Path) }
  return [System.IO.Path]::GetFullPath($Path)
}

function Resolve-RepoPath {
  param([string] $Root, [string] $Path)
  if ([System.IO.Path]::IsPathRooted($Path)) { return (Resolve-AbsolutePath -Path $Path) }
  return (Resolve-AbsolutePath -Path (Join-Path $Root $Path))
}

function Get-GitOutput {
  param([string] $Repo, [string[]] $Arguments)
  $Output = & git -C $Repo @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) { throw "git -C $Repo $($Arguments -join ' ') failed.`n$($Output | Out-String)" }
  return ($Output | Out-String).Trim()
}

function Get-RelativeGitPath {
  param([string] $Root, [string] $Path)
  $ResolvedRoot = Resolve-AbsolutePath -Path $Root
  $ResolvedPath = Resolve-AbsolutePath -Path $Path
  if ($ResolvedPath.Equals($ResolvedRoot, [StringComparison]::OrdinalIgnoreCase)) { return "." }
  $Prefix = $ResolvedRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  if (-not $ResolvedPath.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Repository path is outside repo root: $ResolvedPath" }
  return $ResolvedPath.Substring($Prefix.Length).Replace('\', '/')
}

function Assert-OnMain {
  param([string] $Repo, [string] $Name)
  if ((Get-GitOutput -Repo $Repo -Arguments @("rev-parse", "--abbrev-ref", "HEAD")) -ne "main") { throw "publish-not-main: $Name" }
}

function Assert-OriginRemote {
  param([string] $Repo, [string] $Name)
  & git -C $Repo remote get-url origin *> $null
  if ($LASTEXITCODE -ne 0) { throw "publish-missing-origin: $Name" }
}

function Update-OriginMain {
  param([string] $Repo, [string] $Name)
  Invoke-GitWithRetry -Description "fetch origin main for $Name" -Arguments @("-C", $Repo, "fetch", "--quiet", "origin", "main") -DelaySeconds 1
}

function Assert-NotBehindOriginMain {
  param([string] $Repo, [string] $Name)
  & git -C $Repo merge-base --is-ancestor origin/main HEAD *> $null
  if ($LASTEXITCODE -ne 0) { throw "publish-behind-origin-main: $Name" }
}

function Test-AllowedPath {
  param([string] $Path, [string[]] $AllowedRoots)
  $Normalized = $Path.Trim('"').Replace('\', '/')
  foreach ($AllowedRoot in $AllowedRoots) {
    $Allowed = $AllowedRoot.Trim('/').Replace('\', '/')
    if ($Normalized -eq $Allowed -or $Normalized.StartsWith("$Allowed/", [StringComparison]::Ordinal)) { return $true }
  }
  return $false
}

function Assert-RepoCleanOutsidePaths {
  param([string] $Repo, [string] $Name, [string[]] $AllowedRoots)
  $Status = @(& git -C $Repo status --porcelain --untracked-files=all)
  if ($LASTEXITCODE -ne 0) { throw "git status failed for $Name." }
  foreach ($Line in $Status) {
    if (-not $Line) { continue }
    $PathText = $Line.Substring([Math]::Min(3, $Line.Length)).Trim()
    $Paths = if ($PathText -like "* -> *") { @($PathText -split " -> ") } else { @($PathText) }
    foreach ($PathValue in $Paths) {
      if (-not (Test-AllowedPath -Path $PathValue -AllowedRoots $AllowedRoots)) { throw "publish-dirty-outside-allowed-paths: $Name ($PathValue)" }
    }
  }
}

function Test-RepoAhead {
  param([string] $Repo)
  return (Get-GitOutput -Repo $Repo -Arguments @("rev-parse", "HEAD")) -ne (Get-GitOutput -Repo $Repo -Arguments @("rev-parse", "origin/main"))
}

function Assert-AheadChangesInsidePaths {
  param([string] $Repo, [string] $Name, [string[]] $AllowedRoots)
  if (-not (Test-RepoAhead -Repo $Repo)) { return }
  $Paths = @(& git -C $Repo -c core.quotePath=false diff --name-only origin/main..HEAD -- .)
  if ($LASTEXITCODE -ne 0) { throw "git diff origin/main..HEAD failed for $Name." }
  foreach ($PathValue in $Paths) {
    if ($PathValue -and -not (Test-AllowedPath -Path $PathValue -AllowedRoots $AllowedRoots)) { throw "publish-ahead-outside-allowed-paths: $Name ($PathValue)" }
  }
}

function Test-RepoHasChangesUnderPath {
  param([string] $Repo, [string] $Path)
  $Status = @(& git -C $Repo status --porcelain --untracked-files=all -- $Path)
  if ($LASTEXITCODE -ne 0) { throw "git status failed for $Repo." }
  return $Status.Count -gt 0
}

function Test-StagedChangesUnderPath {
  param([string] $Repo, [string] $Path)
  & git -C $Repo diff --cached --quiet -- $Path
  if ($LASTEXITCODE -eq 0) { return $false }
  if ($LASTEXITCODE -eq 1) { return $true }
  throw "git diff --cached failed for $Repo."
}

function Prepare-ChildCommit {
  param([string] $Repo, [string] $Name, [string] $Message)
  if (Test-RepoHasChangesUnderPath -Repo $Repo -Path "skills") {
    Invoke-Git -Description "stage $Name skills" -Arguments @("-C", $Repo, "add", "skills")
    if (Test-StagedChangesUnderPath -Repo $Repo -Path "skills") { Invoke-Git -Description "commit $Name skills" -Arguments @("-C", $Repo, "commit", "-m", $Message) }
  }
}

if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $ScriptRoot }
$RepoRoot = Resolve-AbsolutePath -Path $RepoRoot
if (-not $FirstPartyRepoPath) { $FirstPartyRepoPath = "repos/oceans-skills" }
if (-not $CommunityRepoPath) { $CommunityRepoPath = "repos/community-skills" }
$FirstPartyRepo = Resolve-RepoPath -Root $RepoRoot -Path $FirstPartyRepoPath
$CommunityRepo = Resolve-RepoPath -Root $RepoRoot -Path $CommunityRepoPath
$FirstPartyRel = Get-RelativeGitPath -Root $RepoRoot -Path $FirstPartyRepo
$CommunityRel = Get-RelativeGitPath -Root $RepoRoot -Path $CommunityRepo
$CatalogRoot = Join-Path $RepoRoot $CatalogPath

$Repositories = @(
  [PSCustomObject]@{ Name = "entry"; Repo = $RepoRoot },
  [PSCustomObject]@{ Name = "oceans-skills"; Repo = $FirstPartyRepo },
  [PSCustomObject]@{ Name = "community-skills"; Repo = $CommunityRepo }
)
foreach ($Repository in $Repositories) {
  Assert-OnMain -Repo $Repository.Repo -Name $Repository.Name
  Assert-OriginRemote -Repo $Repository.Repo -Name $Repository.Name
  Update-OriginMain -Repo $Repository.Repo -Name $Repository.Name
  Assert-NotBehindOriginMain -Repo $Repository.Repo -Name $Repository.Name
}

Assert-RepoCleanOutsidePaths -Repo $RepoRoot -Name "entry" -AllowedRoots @($FirstPartyRel, $CommunityRel, $CatalogPath)
Assert-RepoCleanOutsidePaths -Repo $FirstPartyRepo -Name "oceans-skills" -AllowedRoots @("skills")
Assert-RepoCleanOutsidePaths -Repo $CommunityRepo -Name "community-skills" -AllowedRoots @("skills")
Assert-AheadChangesInsidePaths -Repo $RepoRoot -Name "entry" -AllowedRoots @($FirstPartyRel, $CommunityRel, $CatalogPath)
Assert-AheadChangesInsidePaths -Repo $FirstPartyRepo -Name "oceans-skills" -AllowedRoots @("skills")
Assert-AheadChangesInsidePaths -Repo $CommunityRepo -Name "community-skills" -AllowedRoots @("skills")

$ValidationArguments = @{
  FirstPartySkillsRoot = (Join-Path $FirstPartyRepo "skills")
  CommunitySkillsRoot = (Join-Path $CommunityRepo "skills")
  CatalogRoot = $CatalogRoot
}
& (Join-Path $ScriptRoot "validate-skills.ps1") @ValidationArguments

$FirstPartyChanged = Test-RepoHasChangesUnderPath -Repo $FirstPartyRepo -Path "skills"
$CommunityChanged = Test-RepoHasChangesUnderPath -Repo $CommunityRepo -Path "skills"
$EntryChanged = (Test-RepoHasChangesUnderPath -Repo $RepoRoot -Path $FirstPartyRel) -or
  (Test-RepoHasChangesUnderPath -Repo $RepoRoot -Path $CommunityRel) -or
  (Test-RepoHasChangesUnderPath -Repo $RepoRoot -Path $CatalogPath)
$FirstPartyAhead = Test-RepoAhead -Repo $FirstPartyRepo
$CommunityAhead = Test-RepoAhead -Repo $CommunityRepo
$EntryAhead = Test-RepoAhead -Repo $RepoRoot

if (-not $FirstPartyChanged -and -not $CommunityChanged -and -not $EntryChanged -and -not $FirstPartyAhead -and -not $CommunityAhead -and -not $EntryAhead) {
  Write-Host "publish-no-changes"
  exit 0
}

if ($DryRun) {
  if ($FirstPartyChanged) { Write-Host "plan-commit-child: oceans-skills" }
  if ($CommunityChanged) { Write-Host "plan-commit-child: community-skills" }
  if ($FirstPartyChanged -or $FirstPartyAhead) { Write-Host "plan-push-child: oceans-skills" }
  if ($CommunityChanged -or $CommunityAhead) { Write-Host "plan-push-child: community-skills" }
  Write-Host "plan-commit-entry: release: publish skills and catalog"
  Write-Host "plan-push-entry-last: entry"
  exit 0
}

Prepare-ChildCommit -Repo $FirstPartyRepo -Name "oceans-skills" -Message "skills: publish staged first-party skills"
Prepare-ChildCommit -Repo $CommunityRepo -Name "community-skills" -Message "skills: publish staged community skills"
& (Join-Path $ScriptRoot "validate-skills.ps1") @ValidationArguments

Invoke-Git -Description "stage entry release state" -Arguments @("-C", $RepoRoot, "add", $FirstPartyRel, $CommunityRel, $CatalogPath)
if ((Test-StagedChangesUnderPath -Repo $RepoRoot -Path $FirstPartyRel) -or
    (Test-StagedChangesUnderPath -Repo $RepoRoot -Path $CommunityRel) -or
    (Test-StagedChangesUnderPath -Repo $RepoRoot -Path $CatalogPath)) {
  Invoke-Git -Description "commit entry release state" -Arguments @("-C", $RepoRoot, "commit", "-m", "release: publish skills and catalog")
}

# Push child commits first and the single visible entry commit last.
if (Test-RepoAhead -Repo $FirstPartyRepo) {
  Invoke-GitWithRetry -Description "push oceans-skills main" -Arguments @("-C", $FirstPartyRepo, "push", "--quiet", "origin", "main") -DelaySeconds 1
}
if (Test-RepoAhead -Repo $CommunityRepo) {
  Invoke-GitWithRetry -Description "push community-skills main" -Arguments @("-C", $CommunityRepo, "push", "--quiet", "origin", "main") -DelaySeconds 1
}
if (Test-RepoAhead -Repo $RepoRoot) {
  Invoke-GitWithRetry -Description "push entry main last" -Arguments @("-C", $RepoRoot, "push", "--quiet", "origin", "main") -DelaySeconds 1
}
