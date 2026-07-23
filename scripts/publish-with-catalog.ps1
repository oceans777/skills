param(
  [switch] $DryRun,
  [string] $RepoRoot,
  [string] $FirstPartyRepoPath,
  [string] $CommunityRepoPath
)

$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $ScriptRoot }
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
if (-not $FirstPartyRepoPath) { $FirstPartyRepoPath = "repos/oceans-skills" }
if (-not $CommunityRepoPath) { $CommunityRepoPath = "repos/community-skills" }
$FirstPartyRepo = if ([System.IO.Path]::IsPathRooted($FirstPartyRepoPath)) { [System.IO.Path]::GetFullPath($FirstPartyRepoPath) } else { [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $FirstPartyRepoPath)) }
$CommunityRepo = if ([System.IO.Path]::IsPathRooted($CommunityRepoPath)) { [System.IO.Path]::GetFullPath($CommunityRepoPath) } else { [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $CommunityRepoPath)) }
$CatalogRoot = Join-Path $RepoRoot "catalog"

function Invoke-GitChecked {
  param([Parameter(Mandatory = $true)][string[]] $Arguments)
  $Output = & git @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed.`n$($Output | Out-String)" }
  return @($Output)
}

$PublishArguments = @{
  RepoRoot = $RepoRoot
  FirstPartyRepoPath = $FirstPartyRepo
  CommunityRepoPath = $CommunityRepo
}
if ($DryRun) { $PublishArguments.DryRun = $true }

$CatalogStatus = @()
if (Test-Path -LiteralPath $CatalogRoot -PathType Container) {
  $CatalogStatus = @(& git -C $RepoRoot status --porcelain --untracked-files=all -- catalog)
  if ($LASTEXITCODE -ne 0) { throw "git status failed for catalog." }
}
if (-not (Test-Path -LiteralPath $CatalogRoot -PathType Container) -or $CatalogStatus.Count -eq 0) {
  & (Join-Path $ScriptRoot "publish-skills.ps1") @PublishArguments
  exit $LASTEXITCODE
}

& (Join-Path $ScriptRoot "validate-skills.ps1") `
  -FirstPartySkillsRoot (Join-Path $FirstPartyRepo "skills") `
  -CommunitySkillsRoot (Join-Path $CommunityRepo "skills") `
  -CatalogRoot $CatalogRoot

$StashBefore = (& git -C $RepoRoot rev-parse -q --verify refs/stash 2>$null | Out-String).Trim()
& git -C $RepoRoot stash push -u -m oceans-catalog-publish -- catalog *> $null
if ($LASTEXITCODE -ne 0) { throw "Failed to isolate catalog changes for publishing." }
$StashAfter = (& git -C $RepoRoot rev-parse -q --verify refs/stash 2>$null | Out-String).Trim()
if (-not $StashAfter -or $StashAfter -eq $StashBefore) { throw "Failed to isolate catalog changes for publishing." }
$StashActive = $true

try {
  & (Join-Path $ScriptRoot "publish-skills.ps1") @PublishArguments
  if ($LASTEXITCODE -ne 0) { throw "Child skill publishing failed." }

  Invoke-GitChecked -Arguments @("-C", $RepoRoot, "stash", "apply", "--index", $StashAfter) | Out-Null
  Invoke-GitChecked -Arguments @("-C", $RepoRoot, "stash", "drop", $StashAfter) | Out-Null
  $StashActive = $false

  & (Join-Path $ScriptRoot "validate-skills.ps1") `
    -FirstPartySkillsRoot (Join-Path $FirstPartyRepo "skills") `
    -CommunitySkillsRoot (Join-Path $CommunityRepo "skills") `
    -CatalogRoot $CatalogRoot

  if ($DryRun) {
    Write-Host "plan-commit-entry-catalog: catalog: update skill lifecycle"
    Write-Host "plan-push-entry-catalog: entry"
    exit 0
  }

  Invoke-GitChecked -Arguments @("-C", $RepoRoot, "add", "catalog") | Out-Null
  & git -C $RepoRoot diff --cached --quiet -- catalog
  $DiffExitCode = $LASTEXITCODE
  if ($DiffExitCode -eq 1) {
    Invoke-GitChecked -Arguments @("-C", $RepoRoot, "commit", "-m", "catalog: update skill lifecycle") | Out-Null
  } elseif ($DiffExitCode -ne 0) {
    throw "git diff --cached failed for catalog."
  }

  & git -C $RepoRoot diff --quiet origin/main..HEAD -- .
  $AheadExitCode = $LASTEXITCODE
  if ($AheadExitCode -eq 1) {
    Invoke-GitChecked -Arguments @("-C", $RepoRoot, "push", "--quiet", "origin", "main") | Out-Null
  } elseif ($AheadExitCode -ne 0) {
    throw "git diff origin/main..HEAD failed."
  }
} finally {
  if ($StashActive) {
    & git -C $RepoRoot stash apply --index $StashAfter *> $null
    if ($LASTEXITCODE -eq 0) {
      & git -C $RepoRoot stash drop $StashAfter *> $null
    } else {
      Write-Warning "Failed to restore catalog changes from $StashAfter."
    }
  }
}
