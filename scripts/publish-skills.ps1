param(
  [switch] $DryRun,
  [string] $RepoRoot,
  [string] $FirstPartyRepoPath,
  [string] $CommunityRepoPath
)

$ErrorActionPreference = "Stop"

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptRoot "common.ps1")

function Resolve-AbsolutePath {
  param([Parameter(Mandatory = $true)][string] $Path)

  if (Test-Path -LiteralPath $Path) {
    return [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).Path)
  }

  return [System.IO.Path]::GetFullPath($Path)
}

function Resolve-RepoPath {
  param(
    [Parameter(Mandatory = $true)][string] $Root,
    [Parameter(Mandatory = $true)][string] $Path
  )

  if ([System.IO.Path]::IsPathRooted($Path)) {
    return (Resolve-AbsolutePath -Path $Path)
  }

  return (Resolve-AbsolutePath -Path (Join-Path $Root $Path))
}

function Get-GitOutput {
  param(
    [Parameter(Mandatory = $true)][string] $Repo,
    [Parameter(Mandatory = $true)][string[]] $Arguments
  )

  $Output = & git -C $Repo @Arguments 2>&1
  $ExitCode = $LASTEXITCODE
  if ($ExitCode -ne 0) {
    throw "git -C $Repo $($Arguments -join ' ') failed with exit code $ExitCode.`n$($Output | Out-String)"
  }

  return ($Output | Out-String).Trim()
}

function Get-RelativeGitPath {
  param(
    [Parameter(Mandatory = $true)][string] $Root,
    [Parameter(Mandatory = $true)][string] $Path
  )

  $ResolvedRoot = Resolve-AbsolutePath -Path $Root
  $ResolvedPath = Resolve-AbsolutePath -Path $Path
  $Comparison = [StringComparison]::OrdinalIgnoreCase

  if ($ResolvedPath.Equals($ResolvedRoot, $Comparison)) {
    return "."
  }

  if (-not $ResolvedRoot.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
    $ResolvedRoot += [System.IO.Path]::DirectorySeparatorChar
  }

  if (-not $ResolvedPath.StartsWith($ResolvedRoot, $Comparison)) {
    throw "Repository path is outside repo root: $ResolvedPath"
  }

  return $ResolvedPath.Substring($ResolvedRoot.Length).Replace("\", "/")
}

function Assert-OnMain {
  param(
    [Parameter(Mandatory = $true)][string] $Repo,
    [Parameter(Mandatory = $true)][string] $Name
  )

  $Branch = Get-GitOutput -Repo $Repo -Arguments @("rev-parse", "--abbrev-ref", "HEAD")
  if ($Branch -ne "main") {
    Write-Host "publish-not-main: $Name"
    exit 1
  }
}

function Assert-OriginRemote {
  param(
    [Parameter(Mandatory = $true)][string] $Repo,
    [Parameter(Mandatory = $true)][string] $Name
  )

  & git -C $Repo remote get-url origin *> $null
  if ($LASTEXITCODE -ne 0) {
    Write-Host "publish-missing-origin: $Name"
    exit 1
  }
}

function Update-OriginMain {
  param(
    [Parameter(Mandatory = $true)][string] $Repo,
    [Parameter(Mandatory = $true)][string] $Name
  )

  Invoke-GitWithRetry `
    -Description "fetch origin main for $Name" `
    -Arguments @("-C", $Repo, "fetch", "--quiet", "origin", "main") `
    -DelaySeconds 1
}

function Assert-NotBehindOriginMain {
  param(
    [Parameter(Mandatory = $true)][string] $Repo,
    [Parameter(Mandatory = $true)][string] $Name
  )

  & git -C $Repo merge-base --is-ancestor origin/main HEAD *> $null
  if ($LASTEXITCODE -ne 0) {
    Write-Host "publish-behind-origin-main: $Name"
    exit 1
  }
}

function Test-AllowedPath {
  param(
    [Parameter(Mandatory = $true)][string] $Path,
    [Parameter(Mandatory = $true)][string[]] $AllowedRoots
  )

  $Normalized = $Path.Trim('"').Replace("\", "/")
  foreach ($AllowedRoot in $AllowedRoots) {
    $Allowed = $AllowedRoot.Trim("/").Replace("\", "/")
    if ($Normalized -eq $Allowed -or $Normalized.StartsWith("$Allowed/", [StringComparison]::Ordinal)) {
      return $true
    }
  }

  return $false
}

function Assert-RepoCleanOutsidePaths {
  param(
    [Parameter(Mandatory = $true)][string] $Repo,
    [Parameter(Mandatory = $true)][string] $Name,
    [Parameter(Mandatory = $true)][string[]] $AllowedRoots
  )

  $Arguments = @("status", "--porcelain", "--untracked-files=all", "--", ".")
  foreach ($AllowedRoot in $AllowedRoots) {
    $NormalizedRoot = $AllowedRoot.Trim("/").Replace("\", "/")
    $Arguments += ":(exclude)$NormalizedRoot"
  }

  $Status = & git -C $Repo @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "git status failed for $Name."
  }

  if ($Status) {
    Write-Host "publish-dirty-outside-allowed-paths: $Name"
    exit 1
  }
}

function Test-RepoHasChangesUnderPath {
  param(
    [Parameter(Mandatory = $true)][string] $Repo,
    [Parameter(Mandatory = $true)][string] $Path
  )

  $Status = & git -C $Repo status --porcelain --untracked-files=all -- $Path
  if ($LASTEXITCODE -ne 0) {
    throw "git status failed for $Repo."
  }

  return ($null -ne $Status -and @($Status).Count -gt 0)
}

function Test-StagedChangesUnderPath {
  param(
    [Parameter(Mandatory = $true)][string] $Repo,
    [Parameter(Mandatory = $true)][string] $Path
  )

  & git -C $Repo diff --cached --quiet -- $Path
  $ExitCode = $LASTEXITCODE
  if ($ExitCode -eq 0) {
    return $false
  }
  if ($ExitCode -eq 1) {
    return $true
  }

  throw "git diff --cached failed for $Repo."
}

function Test-RepoHeadDiffersFromOriginMain {
  param([Parameter(Mandatory = $true)][string] $Repo)

  $Head = Get-GitOutput -Repo $Repo -Arguments @("rev-parse", "HEAD")
  $OriginMain = Get-GitOutput -Repo $Repo -Arguments @("rev-parse", "origin/main")
  return ($Head -ne $OriginMain)
}

function Publish-ChildRepository {
  param(
    [Parameter(Mandatory = $true)][string] $Repo,
    [Parameter(Mandatory = $true)][string] $Name,
    [Parameter(Mandatory = $true)][string] $Message,
    [Parameter(Mandatory = $true)][bool] $HasWorkingTreeChanges,
    [Parameter(Mandatory = $true)][bool] $IsAheadOfOrigin
  )

  if ($DryRun) {
    Write-Host "dry_run: true"
    if ($HasWorkingTreeChanges) {
      Write-Host "plan-commit-child: $Name"
    }
    if ($HasWorkingTreeChanges -or $IsAheadOfOrigin) {
      Write-Host "plan-push-child: $Name"
    }
    return
  }

  if ($HasWorkingTreeChanges) {
    Invoke-Git -Description "stage $Name skills" -Arguments @("-C", $Repo, "add", "skills")
    if (Test-StagedChangesUnderPath -Repo $Repo -Path "skills") {
      Invoke-Git -Description "commit $Name skills" -Arguments @("-C", $Repo, "commit", "-m", $Message)
    }
  }

  if (Test-RepoHeadDiffersFromOriginMain -Repo $Repo) {
    Invoke-GitWithRetry `
      -Description "push $Name main" `
      -Arguments @("-C", $Repo, "push", "--quiet", "origin", "main") `
      -DelaySeconds 1
  }
}

if (-not $RepoRoot) {
  $RepoRoot = Split-Path -Parent $ScriptRoot
}
$RepoRoot = Resolve-AbsolutePath -Path $RepoRoot

if (-not $FirstPartyRepoPath) {
  $FirstPartyRepoPath = "repos/oceans-skills"
}
if (-not $CommunityRepoPath) {
  $CommunityRepoPath = "repos/community-skills"
}

$FirstPartyRepo = Resolve-RepoPath -Root $RepoRoot -Path $FirstPartyRepoPath
$CommunityRepo = Resolve-RepoPath -Root $RepoRoot -Path $CommunityRepoPath
$FirstPartyRel = Get-RelativeGitPath -Root $RepoRoot -Path $FirstPartyRepo
$CommunityRel = Get-RelativeGitPath -Root $RepoRoot -Path $CommunityRepo

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

Assert-RepoCleanOutsidePaths -Repo $RepoRoot -Name "entry" -AllowedRoots @($FirstPartyRel, $CommunityRel)
Assert-RepoCleanOutsidePaths -Repo $FirstPartyRepo -Name "oceans-skills" -AllowedRoots @("skills")
Assert-RepoCleanOutsidePaths -Repo $CommunityRepo -Name "community-skills" -AllowedRoots @("skills")

$ValidateScript = Join-Path $ScriptRoot "validate-skills.ps1"
try {
  & $ValidateScript `
    -FirstPartySkillsRoot (Join-Path $FirstPartyRepo "skills") `
    -CommunitySkillsRoot (Join-Path $CommunityRepo "skills")
} catch {
  Write-Host "publish-validate-failed"
  Write-Host $_
  exit 1
}

$FirstPartyChanged = Test-RepoHasChangesUnderPath -Repo $FirstPartyRepo -Path "skills"
$CommunityChanged = Test-RepoHasChangesUnderPath -Repo $CommunityRepo -Path "skills"
$FirstPartyAhead = Test-RepoHeadDiffersFromOriginMain -Repo $FirstPartyRepo
$CommunityAhead = Test-RepoHeadDiffersFromOriginMain -Repo $CommunityRepo
$EntrySubmoduleChanged = (Test-RepoHasChangesUnderPath -Repo $RepoRoot -Path $FirstPartyRel) -or
  (Test-RepoHasChangesUnderPath -Repo $RepoRoot -Path $CommunityRel)
$EntryAhead = Test-RepoHeadDiffersFromOriginMain -Repo $RepoRoot

if (-not $FirstPartyChanged -and -not $CommunityChanged -and
    -not $FirstPartyAhead -and -not $CommunityAhead -and
    -not $EntrySubmoduleChanged -and -not $EntryAhead) {
  Write-Host "publish-no-changes"
  exit 0
}

if ($FirstPartyChanged -or $FirstPartyAhead) {
  Publish-ChildRepository `
    -Repo $FirstPartyRepo `
    -Name "oceans-skills" `
    -Message "skills: publish staged first-party skills" `
    -HasWorkingTreeChanges $FirstPartyChanged `
    -IsAheadOfOrigin $FirstPartyAhead
}

if ($CommunityChanged -or $CommunityAhead) {
  Publish-ChildRepository `
    -Repo $CommunityRepo `
    -Name "community-skills" `
    -Message "skills: publish staged community skills" `
    -HasWorkingTreeChanges $CommunityChanged `
    -IsAheadOfOrigin $CommunityAhead
}

if ($DryRun) {
  Write-Host "plan-commit-entry: repos: update skill submodules"
  Write-Host "plan-push-entry: entry"
  exit 0
}

Invoke-Git -Description "stage skill submodules" -Arguments @("-C", $RepoRoot, "add", $FirstPartyRel, $CommunityRel)

if ((Test-StagedChangesUnderPath -Repo $RepoRoot -Path $FirstPartyRel) -or
    (Test-StagedChangesUnderPath -Repo $RepoRoot -Path $CommunityRel)) {
  Invoke-Git -Description "commit skill submodule updates" -Arguments @("-C", $RepoRoot, "commit", "-m", "repos: update skill submodules")
}

if (Test-RepoHeadDiffersFromOriginMain -Repo $RepoRoot) {
  Invoke-GitWithRetry `
    -Description "push entry main" `
    -Arguments @("-C", $RepoRoot, "push", "--quiet", "origin", "main") `
    -DelaySeconds 1
}
