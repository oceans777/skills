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

function Get-PublishDiscoveredSkillNames {
  $Gitmodules = Join-Path $RepoRoot ".gitmodules"
  if (-not (Test-Path -LiteralPath $Gitmodules -PathType Leaf)) { throw "publish-missing-gitmodules" }
  $Output = & git -C $RepoRoot config -f $Gitmodules --get-regexp '^submodule\..*\.path$'
  if ($LASTEXITCODE -ne 0) { throw "publish-missing-gitmodules" }
  $Names = New-Object System.Collections.Generic.List[string]
  foreach ($Line in @($Output)) {
    $Text = [string]$Line
    if ([string]::IsNullOrWhiteSpace($Text)) { continue }
    $Space = $Text.LastIndexOf(' ')
    if ($Space -lt 1) { continue }
    $Path = $Text.Substring($Space + 1).Trim()
    if ($Path -in @("repos/community-skills", "repos/oceans-skills")) { continue }
    if ($Path.StartsWith("repos/") -and -not $Path.Substring(6).Contains("/")) { $Names.Add($Path.Substring(6)) }
  }
  return @($Names)
}

function Publish-DiscoveredSkillRepos {
  $Names = @(Get-PublishDiscoveredSkillNames)
  Assert-OnMain -Repo $RepoRoot -Name "entry"
  Assert-OriginRemote -Repo $RepoRoot -Name "entry"
  Update-OriginMain -Repo $RepoRoot -Name "entry"
  Assert-NotBehindOriginMain -Repo $RepoRoot -Name "entry"
  Assert-OnMain -Repo $CommunityRepo -Name "community-skills"
  Assert-OriginRemote -Repo $CommunityRepo -Name "community-skills"
  Update-OriginMain -Repo $CommunityRepo -Name "community-skills"
  Assert-NotBehindOriginMain -Repo $CommunityRepo -Name "community-skills"
  foreach ($Name in $Names) {
    $Repo = Join-Path $RepoRoot (Join-Path "repos" $Name)
    Assert-OnMain -Repo $Repo -Name $Name
    Assert-OriginRemote -Repo $Repo -Name $Name
    Update-OriginMain -Repo $Repo -Name $Name
    Assert-NotBehindOriginMain -Repo $Repo -Name $Name
  }
  $Allowed = @("catalog", $CommunityRel)
  foreach ($Name in $Names) { $Allowed += "repos/$Name" }
  Assert-RepoCleanOutsidePaths -Repo $RepoRoot -Name "entry" -AllowedRoots $Allowed
  Assert-RepoCleanOutsidePaths -Repo $CommunityRepo -Name "community-skills" -AllowedRoots @("skills")
  Assert-AheadChangesInsidePaths -Repo $RepoRoot -Name "entry" -AllowedRoots $Allowed
  Assert-AheadChangesInsidePaths -Repo $CommunityRepo -Name "community-skills" -AllowedRoots @("skills")
  $ValidationArguments = @{
    FirstPartySkillsRoot = (Join-Path $RepoRoot "repos")
    CommunitySkillsRoot = (Join-Path $CommunityRepo "skills")
    CatalogRoot = $CatalogRoot
  }
  & (Join-Path $ScriptRoot "validate-skills.ps1") @ValidationArguments
  $SkillChanged = $false
  $EntrySkillChanged = $false
  foreach ($Name in $Names) {
    $Repo = Join-Path $RepoRoot (Join-Path "repos" $Name)
    if ((Test-RepoHasChangesUnderPath -Repo $Repo -Path ".") -or (Test-RepoAhead -Repo $Repo)) { $SkillChanged = $true }
    if (Test-RepoHasChangesUnderPath -Repo $RepoRoot -Path "repos/$Name") { $EntrySkillChanged = $true }
  }
  $CommunityChanged = Test-RepoHasChangesUnderPath -Repo $CommunityRepo -Path "skills"
  $EntryChanged = $EntrySkillChanged -or (Test-RepoHasChangesUnderPath -Repo $RepoRoot -Path $CommunityRel) -or (Test-RepoHasChangesUnderPath -Repo $RepoRoot -Path $CatalogPath)
  $CommunityAhead = Test-RepoAhead -Repo $CommunityRepo
  $EntryAhead = Test-RepoAhead -Repo $RepoRoot
  if (-not $SkillChanged -and -not $CommunityChanged -and -not $EntryChanged -and -not $CommunityAhead -and -not $EntryAhead) {
    Write-Host "publish-no-changes"
    exit 0
  }
  if ($DryRun) {
    foreach ($Name in $Names) {
      $Repo = Join-Path $RepoRoot (Join-Path "repos" $Name)
      if (Test-RepoHasChangesUnderPath -Repo $Repo -Path ".") { Write-Host "plan-commit-child: $Name" }
      if ((Test-RepoHasChangesUnderPath -Repo $Repo -Path ".") -or (Test-RepoAhead -Repo $Repo)) { Write-Host "plan-push-child: $Name" }
    }
    if ($CommunityChanged) { Write-Host "plan-commit-child: community-skills" }
    if ($CommunityChanged -or $CommunityAhead) { Write-Host "plan-push-child: community-skills" }
    Write-Host "plan-commit-entry: release: publish skills and catalog"
    Write-Host "plan-push-entry-last: entry"
    exit 0
  }
  foreach ($Name in $Names) {
    $Repo = Join-Path $RepoRoot (Join-Path "repos" $Name)
    if (Test-RepoHasChangesUnderPath -Repo $Repo -Path ".") {
      Invoke-Git -Description "stage $Name" -Arguments @("-C", $Repo, "add", "-A")
      if (Test-StagedChangesUnderPath -Repo $Repo -Path ".") {
        Invoke-Git -Description "commit $Name" -Arguments @("-C", $Repo, "commit", "-m", "skills: publish $Name")
      }
    }
  }
  Prepare-ChildCommit -Repo $CommunityRepo -Name "community-skills" -Message "skills: publish staged community skills"
  & (Join-Path $ScriptRoot "validate-skills.ps1") @ValidationArguments
  Invoke-Git -Description "stage entry catalog" -Arguments @("-C", $RepoRoot, "add", "catalog", $CommunityRel)
  foreach ($Name in $Names) {
    Invoke-Git -Description "stage entry pin $Name" -Arguments @("-C", $RepoRoot, "add", "repos/$Name")
  }
  $EntryNeedsCommit = (Test-RepoHasChangesUnderPath -Repo $RepoRoot -Path "catalog") -or (Test-RepoHasChangesUnderPath -Repo $RepoRoot -Path $CommunityRel)
  foreach ($Name in $Names) {
    if (Test-RepoHasChangesUnderPath -Repo $RepoRoot -Path "repos/$Name") { $EntryNeedsCommit = $true }
  }
  if ($EntryNeedsCommit) {
    Invoke-Git -Description "commit entry release state" -Arguments @("-C", $RepoRoot, "commit", "-m", "release: publish skills and catalog")
  }
  foreach ($Name in $Names) {
    $Repo = Join-Path $RepoRoot (Join-Path "repos" $Name)
    if (Test-RepoAhead -Repo $Repo) {
      Invoke-GitWithRetry -Description "push $Name main" -Arguments @("-C", $Repo, "push", "--quiet", "origin", "main") -DelaySeconds 1
    }
  }
  if (Test-RepoAhead -Repo $CommunityRepo) {
    Invoke-GitWithRetry -Description "push community-skills main" -Arguments @("-C", $CommunityRepo, "push", "--quiet", "origin", "main") -DelaySeconds 1
  }
  if (Test-RepoAhead -Repo $RepoRoot) {
    Invoke-GitWithRetry -Description "push entry main last" -Arguments @("-C", $RepoRoot, "push", "--quiet", "origin", "main") -DelaySeconds 1
  }
}

if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $ScriptRoot }
$RepoRoot = Resolve-AbsolutePath -Path $RepoRoot
if (-not $CommunityRepoPath) { $CommunityRepoPath = "repos/community-skills" }
$CommunityRepo = Resolve-RepoPath -Root $RepoRoot -Path $CommunityRepoPath
$CommunityRel = Get-RelativeGitPath -Root $RepoRoot -Path $CommunityRepo
$CatalogRoot = Join-Path $RepoRoot $CatalogPath
if (-not $PSBoundParameters.ContainsKey("FirstPartyRepoPath") -or [string]::IsNullOrWhiteSpace($FirstPartyRepoPath)) {
  Publish-DiscoveredSkillRepos
  exit 0
}
$FirstPartyRepo = Resolve-RepoPath -Root $RepoRoot -Path $FirstPartyRepoPath
$FirstPartyRel = Get-RelativeGitPath -Root $RepoRoot -Path $FirstPartyRepo

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
