$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$PublishScript = Join-Path $RepoRoot "scripts\publish-skills.ps1"
$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "oceans-publish-test-$([Guid]::NewGuid().ToString('N'))"

function Invoke-Git([string[]] $Arguments) { $Output = & git @Arguments 2>&1; if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed.`n$($Output | Out-String)" }; return @($Output) }
function Assert-Equal([string] $Actual, [string] $Expected, [string] $Message) { if ($Actual -ne $Expected) { throw "$Message Expected '$Expected', got '$Actual'." } }
function Assert-NotEqual([string] $Actual, [string] $Unexpected, [string] $Message) { if ($Actual -eq $Unexpected) { throw "$Message Value must differ from '$Unexpected'." } }
function Write-Utf8([string] $Path, [string[]] $Lines) { [System.IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null; [System.IO.File]::WriteAllLines($Path, $Lines, (New-Object System.Text.UTF8Encoding($false))) }

function Initialize-Bare([string] $Bare, [string] $Seed, [string] $Kind) {
  New-Item -ItemType Directory -Force -Path $Seed | Out-Null
  Invoke-Git @("init", "-q", $Seed) | Out-Null; Invoke-Git @("-C", $Seed, "checkout", "-q", "-B", "main") | Out-Null
  Invoke-Git @("-C", $Seed, "config", "user.email", "test@example.invalid") | Out-Null; Invoke-Git @("-C", $Seed, "config", "user.name", "Test") | Out-Null; Invoke-Git @("-C", $Seed, "config", "core.autocrlf", "false") | Out-Null
  if ($Kind -eq "entry") {
    Write-Utf8 (Join-Path $Seed "README.md") @("entry")
    Write-Utf8 (Join-Path $Seed "catalog\skills\.gitkeep") @()
    Write-Utf8 (Join-Path $Seed "catalog\review-queue\oceans-skills\.gitkeep") @()
    Write-Utf8 (Join-Path $Seed "catalog\review-queue\community-skills\.gitkeep") @()
  } else { Write-Utf8 (Join-Path $Seed "skills\.gitkeep") @() }
  Invoke-Git @("-C", $Seed, "add", ".") | Out-Null; Invoke-Git @("-C", $Seed, "commit", "-q", "-m", "initial") | Out-Null
  Invoke-Git @("init", "-q", "--bare", $Bare) | Out-Null; Invoke-Git @("-C", $Seed, "remote", "add", "origin", $Bare) | Out-Null; Invoke-Git @("-C", $Seed, "push", "-q", "-u", "origin", "main") | Out-Null
  Invoke-Git @("--git-dir=$Bare", "symbolic-ref", "HEAD", "refs/heads/main") | Out-Null
}

function New-Fixture([string] $Name) {
  $script:Root = Join-Path $TestRoot $Name; $Remote = Join-Path $Root "remote"; $Seed = Join-Path $Root "seed"; $Work = Join-Path $Root "work"
  $script:EntryRemote = Join-Path $Remote "entry.git"; $script:FirstRemote = Join-Path $Remote "oceans.git"; $script:CommunityRemote = Join-Path $Remote "community.git"
  Initialize-Bare $EntryRemote (Join-Path $Seed "entry") "entry"; Initialize-Bare $FirstRemote (Join-Path $Seed "oceans") "child"; Initialize-Bare $CommunityRemote (Join-Path $Seed "community") "child"
  New-Item -ItemType Directory -Force -Path $Work | Out-Null
  Invoke-Git @("clone", "-q", $EntryRemote, (Join-Path $Work "entry")) | Out-Null
  $script:Entry = Join-Path $Work "entry"
  Invoke-Git @("-C", $Entry, "config", "user.email", "test@example.invalid") | Out-Null; Invoke-Git @("-C", $Entry, "config", "user.name", "Test") | Out-Null; Invoke-Git @("-C", $Entry, "config", "core.autocrlf", "false") | Out-Null
  & git -C $Entry -c protocol.file.allow=always submodule add -q -b main $FirstRemote repos/oceans-skills; if ($LASTEXITCODE -ne 0) { throw "Failed to add first submodule." }
  & git -C $Entry -c protocol.file.allow=always submodule add -q -b main $CommunityRemote repos/community-skills; if ($LASTEXITCODE -ne 0) { throw "Failed to add community submodule." }
  Invoke-Git @("-C", $Entry, "add", ".") | Out-Null; Invoke-Git @("-C", $Entry, "commit", "-q", "-m", "submodules") | Out-Null; Invoke-Git @("-C", $Entry, "push", "-q", "origin", "main") | Out-Null
  $script:First = Join-Path $Entry "repos\oceans-skills"; $script:Community = Join-Path $Entry "repos\community-skills"
  foreach ($Repo in @($First, $Community)) { Invoke-Git @("-C", $Repo, "config", "user.email", "test@example.invalid") | Out-Null; Invoke-Git @("-C", $Repo, "config", "user.name", "Test") | Out-Null; Invoke-Git @("-C", $Repo, "config", "core.autocrlf", "false") | Out-Null }
  $script:EntryBase = (Invoke-Git @("-C", $Entry, "rev-parse", "HEAD") | Select-Object -First 1).Trim()
  $script:FirstBase = (Invoke-Git @("-C", $First, "rev-parse", "HEAD") | Select-Object -First 1).Trim()
}

function Add-ActiveChange([string] $Name, [string] $Version) {
  Write-Utf8 (Join-Path $First "skills\$Name\SKILL.md") @("---", "name: $Name", "description: Publish fixture.", "---", "version=$Version")
  Write-Utf8 (Join-Path $Entry "catalog\skills\$Name.skill") @(
    "schema_version=2", "name=$Name", "status=active", "package_repository=oceans-skills",
    "upstream_repository=https://github.com/example/upstream", "upstream_path=skills/$Name", "upstream_ref=main", "upstream_commit=0123456789012345678901234567890123456789",
    "candidate_upstream_repository=", "candidate_upstream_path=", "candidate_upstream_ref=", "candidate_upstream_commit=", "replacement=", "status_reason=", "transition_note=publish fixture", "updated_at=2026-07-23T00:00:00Z"
  )
}

function Run-Publish([bool] $ExpectSuccess, [switch] $DryRun) {
  $Home = Join-Path $Root "home"; New-Item -ItemType Directory -Force -Path $Home | Out-Null
  $OldHome = $env:HOME; $OldUserProfile = $env:USERPROFILE; $OldGitConfig = $env:GIT_CONFIG_GLOBAL
  try {
    $env:HOME = $Home; $env:USERPROFILE = $Home; $env:GIT_CONFIG_GLOBAL = Join-Path $Home ".gitconfig"
    $Args = @{ RepoRoot = $Entry; FirstPartyRepoPath = $First; CommunityRepoPath = $Community }
    if ($DryRun) { $Args.DryRun = $true }
    try { $script:Output = (& $PublishScript @Args *>&1 | Out-String); $Succeeded = $true } catch { $script:Output = ($_ | Out-String); $Succeeded = $false }
  } finally {
    if ($null -eq $OldHome) { Remove-Item Env:\HOME -ErrorAction SilentlyContinue } else { $env:HOME = $OldHome }
    if ($null -eq $OldUserProfile) { Remove-Item Env:\USERPROFILE -ErrorAction SilentlyContinue } else { $env:USERPROFILE = $OldUserProfile }
    if ($null -eq $OldGitConfig) { Remove-Item Env:\GIT_CONFIG_GLOBAL -ErrorAction SilentlyContinue } else { $env:GIT_CONFIG_GLOBAL = $OldGitConfig }
  }
  if ($ExpectSuccess -and -not $Succeeded) { throw "Publish failed.`n$Output" }
  if (-not $ExpectSuccess -and $Succeeded) { throw "Publish unexpectedly succeeded." }
}
function Remote-Head([string] $Bare) { return ((Invoke-Git @("--git-dir=$Bare", "rev-parse", "refs/heads/main")) | Select-Object -First 1).Trim() }
function Entry-Pointer([string] $Path) { return (((Invoke-Git @("--git-dir=$EntryRemote", "ls-tree", "refs/heads/main", $Path)) | Select-Object -First 1) -split '\s+')[2] }
function Test-EntryPath([string] $Path) { & git --git-dir=$EntryRemote cat-file -e "refs/heads/main:$Path" 2>$null; return $LASTEXITCODE -eq 0 }

try {
  New-Fixture "no-changes"; Run-Publish $true
  Assert-Equal ((Invoke-Git @("-C", $Entry, "rev-parse", "HEAD") | Select-Object -First 1).Trim()) $EntryBase "No-op changed entry."
  if (-not $Output.Contains("publish-no-changes")) { throw "No-op did not report publish-no-changes." }

  New-Fixture "coherent-success"; Add-ActiveChange "coherent-skill" "one"; Run-Publish $true
  $ChildHead = Remote-Head $FirstRemote; $EntryHead = Remote-Head $EntryRemote
  Assert-NotEqual $ChildHead $FirstBase "Child was not published."; Assert-NotEqual $EntryHead $EntryBase "Entry was not published."
  Assert-Equal (Entry-Pointer "repos/oceans-skills") $ChildHead "Entry pointer does not reference child commit."
  if (-not (Test-EntryPath "catalog/skills/coherent-skill.skill")) { throw "Catalog record is missing from visible entry commit." }

  New-Fixture "entry-push-failure"; Add-ActiveChange "retry-skill" "one"
  Write-Utf8 (Join-Path $EntryRemote "hooks\pre-receive") @("#!/bin/sh", "exit 1")
  Run-Publish $false
  $ChildAfterFailure = Remote-Head $FirstRemote; $EntryAfterFailure = Remote-Head $EntryRemote
  Assert-NotEqual $ChildAfterFailure $FirstBase "Child should be pushed before final entry failure."
  Assert-Equal $EntryAfterFailure $EntryBase "Entry main changed despite rejected final push."
  if (Test-EntryPath "catalog/skills/retry-skill.skill") { throw "Catalog became visible without matching entry release." }
  Remove-Item (Join-Path $EntryRemote "hooks\pre-receive") -Force
  Run-Publish $true
  Assert-Equal (Entry-Pointer "repos/oceans-skills") $ChildAfterFailure "Retry entry pointer is wrong."
  if (-not (Test-EntryPath "catalog/skills/retry-skill.skill")) { throw "Retry did not publish catalog." }

  New-Fixture "validation-failure"
  Write-Utf8 (Join-Path $First "skills\orphan-skill\SKILL.md") @("---", "name: orphan-skill", "description: Orphan.", "---")
  Run-Publish $false
  Assert-Equal (Remote-Head $FirstRemote) $FirstBase "Validation failure pushed child."
  Assert-Equal (Remote-Head $EntryRemote) $EntryBase "Validation failure pushed entry."

  New-Fixture "dry-run"; Add-ActiveChange "dry-skill" "one"; Run-Publish $true -DryRun
  Assert-Equal ((Invoke-Git @("-C", $First, "rev-parse", "HEAD") | Select-Object -First 1).Trim()) $FirstBase "Dry-run committed child."
  if (-not $Output.Contains("plan-push-entry-last")) { throw "Dry-run did not document entry-last order." }
  Write-Host "PowerShell publish skills test passed."
} finally { if (Test-Path $TestRoot) { Remove-Item $TestRoot -Recurse -Force } }
