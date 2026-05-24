$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$PublishScript = Join-Path $RepoRoot "scripts\publish-skills.ps1"
$SandboxRoot = Join-Path $env:TEMP ("oceans-publish-test-" + [Guid]::NewGuid().ToString("N"))

function Assert-Equal {
  param(
    [Parameter(Mandatory = $true)]
    [string] $Actual,

    [Parameter(Mandatory = $true)]
    [string] $Expected,

    [Parameter(Mandatory = $true)]
    [string] $Message
  )

  if ($Actual -ne $Expected) {
    throw "$Message Expected '$Expected', got '$Actual'."
  }
}

function Assert-NotEqual {
  param(
    [Parameter(Mandatory = $true)]
    [string] $Actual,

    [Parameter(Mandatory = $true)]
    [string] $Unexpected,

    [Parameter(Mandatory = $true)]
    [string] $Message
  )

  if ($Actual -eq $Unexpected) {
    throw "$Message Value should not be '$Unexpected'."
  }
}

function Assert-GitClean {
  param([Parameter(Mandatory = $true)][string] $RepoPath)

  $Status = Invoke-Git -RepoPath $RepoPath -Arguments @("status", "--porcelain")
  if ($Status) {
    throw "Expected git repository to be clean: $RepoPath`n$Status"
  }
}

function Remove-SandboxRoot {
  if (-not (Test-Path -LiteralPath $SandboxRoot)) {
    return
  }

  $ResolvedRoot = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $SandboxRoot).Path)
  $ResolvedTemp = [System.IO.Path]::GetFullPath($env:TEMP)
  if (-not $ResolvedTemp.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
    $ResolvedTemp += [System.IO.Path]::DirectorySeparatorChar
  }

  $LeafName = Split-Path -Leaf $ResolvedRoot
  if (-not $ResolvedRoot.StartsWith($ResolvedTemp, [StringComparison]::OrdinalIgnoreCase) -or
      -not $LeafName.StartsWith("oceans-publish-test-", [StringComparison]::Ordinal)) {
    throw "Unsafe cleanup target: $ResolvedRoot"
  }

  Remove-Item -LiteralPath $ResolvedRoot -Recurse -Force
}

function Invoke-Git {
  param(
    [Parameter(Mandatory = $true)]
    [string] $RepoPath,

    [Parameter(Mandatory = $true)]
    [string[]] $Arguments
  )

  $PreviousErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $Output = & git -C $RepoPath @Arguments 2>&1 | Out-String
    $ExitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $PreviousErrorActionPreference
  }

  if ($ExitCode -ne 0) {
    throw "git -C $RepoPath $($Arguments -join ' ') failed with exit code $ExitCode`n$Output"
  }

  $Output.Trim()
}

function Invoke-GitGlobal {
  param([Parameter(Mandatory = $true)][string[]] $Arguments)

  $PreviousErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $Output = & git @Arguments 2>&1 | Out-String
    $ExitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $PreviousErrorActionPreference
  }

  if ($ExitCode -ne 0) {
    throw "git $($Arguments -join ' ') failed with exit code $ExitCode`n$Output"
  }

  $Output.Trim()
}

function Initialize-BareRepository {
  param(
    [Parameter(Mandatory = $true)]
    [string] $BarePath,

    [Parameter(Mandatory = $true)]
    [string] $SeedPath,

    [Parameter(Mandatory = $true)]
    [ValidateSet("entry", "skills")]
    [string] $Kind
  )

  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $BarePath) | Out-Null
  New-Item -ItemType Directory -Force -Path $SeedPath | Out-Null

  Invoke-GitGlobal -Arguments @("init", $SeedPath) | Out-Null
  Invoke-Git -RepoPath $SeedPath -Arguments @("checkout", "-q", "-B", "main") | Out-Null
  Invoke-Git -RepoPath $SeedPath -Arguments @("config", "user.email", "publish-test@example.invalid") | Out-Null
  Invoke-Git -RepoPath $SeedPath -Arguments @("config", "user.name", "Publish Test") | Out-Null
  Invoke-Git -RepoPath $SeedPath -Arguments @("config", "core.autocrlf", "false") | Out-Null

  if ($Kind -eq "entry") {
    Set-Content -LiteralPath (Join-Path $SeedPath "README.md") -Value "entry fixture" -Encoding UTF8
  } else {
    New-Item -ItemType Directory -Force -Path (Join-Path $SeedPath "skills") | Out-Null
    Set-Content -LiteralPath (Join-Path $SeedPath "skills\.gitkeep") -Value "" -Encoding UTF8
  }

  Invoke-Git -RepoPath $SeedPath -Arguments @("add", ".") | Out-Null
  Invoke-Git -RepoPath $SeedPath -Arguments @("commit", "-m", "initial") | Out-Null
  Invoke-GitGlobal -Arguments @("init", "--bare", $BarePath) | Out-Null
  Invoke-Git -RepoPath $SeedPath -Arguments @("remote", "add", "origin", $BarePath) | Out-Null
  Invoke-Git -RepoPath $SeedPath -Arguments @("push", "-u", "origin", "main") | Out-Null
  Invoke-GitGlobal -Arguments @("--git-dir", $BarePath, "symbolic-ref", "HEAD", "refs/heads/main") | Out-Null
}

function New-Fixture {
  param([Parameter(Mandatory = $true)][string] $Name)

  $Root = Join-Path $SandboxRoot $Name
  $RemoteRoot = Join-Path $Root "remote"
  $WorkRoot = Join-Path $Root "work"
  $SeedRoot = Join-Path $Root "seed"
  $EntryRemote = Join-Path $RemoteRoot "entry.git"
  $FirstPartyRemote = Join-Path $RemoteRoot "oceans-skills.git"
  $CommunityRemote = Join-Path $RemoteRoot "community-skills.git"
  $EntryRepo = Join-Path $WorkRoot "entry"

  Initialize-BareRepository -BarePath $EntryRemote -SeedPath (Join-Path $SeedRoot "entry") -Kind "entry"
  Initialize-BareRepository -BarePath $FirstPartyRemote -SeedPath (Join-Path $SeedRoot "oceans-skills") -Kind "skills"
  Initialize-BareRepository -BarePath $CommunityRemote -SeedPath (Join-Path $SeedRoot "community-skills") -Kind "skills"

  New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null
  Invoke-GitGlobal -Arguments @("clone", $EntryRemote, $EntryRepo) | Out-Null
  Invoke-Git -RepoPath $EntryRepo -Arguments @("config", "user.email", "publish-test@example.invalid") | Out-Null
  Invoke-Git -RepoPath $EntryRepo -Arguments @("config", "user.name", "Publish Test") | Out-Null
  Invoke-Git -RepoPath $EntryRepo -Arguments @("config", "core.autocrlf", "false") | Out-Null

  $PreviousErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    & git -C $EntryRepo -c protocol.file.allow=always submodule add -b main $FirstPartyRemote "repos/oceans-skills" *> $null
    $FirstPartySubmoduleExitCode = $LASTEXITCODE
    & git -C $EntryRepo -c protocol.file.allow=always submodule add -b main $CommunityRemote "repos/community-skills" *> $null
    $CommunitySubmoduleExitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $PreviousErrorActionPreference
  }
  if ($FirstPartySubmoduleExitCode -ne 0) { throw "Failed to add oceans-skills submodule." }
  if ($CommunitySubmoduleExitCode -ne 0) { throw "Failed to add community-skills submodule." }

  Invoke-Git -RepoPath $EntryRepo -Arguments @("commit", "-m", "add skill submodules") | Out-Null
  Invoke-Git -RepoPath $EntryRepo -Arguments @("push", "origin", "main") | Out-Null

  $FirstPartyRepo = Join-Path $EntryRepo "repos\oceans-skills"
  $CommunityRepo = Join-Path $EntryRepo "repos\community-skills"
  foreach ($ChildRepo in @($FirstPartyRepo, $CommunityRepo)) {
    Invoke-Git -RepoPath $ChildRepo -Arguments @("config", "user.email", "publish-test@example.invalid") | Out-Null
    Invoke-Git -RepoPath $ChildRepo -Arguments @("config", "user.name", "Publish Test") | Out-Null
    Invoke-Git -RepoPath $ChildRepo -Arguments @("config", "core.autocrlf", "false") | Out-Null
  }

  Assert-GitClean -RepoPath $EntryRepo
  Assert-GitClean -RepoPath $FirstPartyRepo
  Assert-GitClean -RepoPath $CommunityRepo

  [PSCustomObject]@{
    Root = $Root
    RemoteRoot = $RemoteRoot
    WorkRoot = $WorkRoot
    EntryRemote = $EntryRemote
    FirstPartyRemote = $FirstPartyRemote
    CommunityRemote = $CommunityRemote
    EntryRepo = $EntryRepo
    FirstPartyRepo = $FirstPartyRepo
    CommunityRepo = $CommunityRepo
  }
}

function Invoke-Publish {
  param(
    [Parameter(Mandatory = $true)]
    [object] $Fixture,

    [switch] $DryRun,

    [switch] $ExpectFailure
  )

  if (-not (Test-Path -LiteralPath $PublishScript)) {
    throw "Missing publish script: $PublishScript"
  }

  $Arguments = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $PublishScript,
    "-RepoRoot", $Fixture.EntryRepo,
    "-FirstPartyRepoPath", $Fixture.FirstPartyRepo,
    "-CommunityRepoPath", $Fixture.CommunityRepo
  )
  if ($DryRun) {
    $Arguments += "-DryRun"
  }

  $EnvHome = Join-Path $Fixture.Root "publish-env-home"
  $EnvConfigHome = Join-Path $EnvHome ".config"
  New-Item -ItemType Directory -Force -Path $EnvConfigHome | Out-Null

  $OldLocation = Get-Location
  $OldGitTerminalPrompt = $env:GIT_TERMINAL_PROMPT
  $OldHome = $env:HOME
  $OldUserProfile = $env:USERPROFILE
  $OldXdgConfigHome = $env:XDG_CONFIG_HOME
  $OldGitConfigGlobal = $env:GIT_CONFIG_GLOBAL

  try {
    $env:GIT_TERMINAL_PROMPT = "0"
    $env:HOME = $EnvHome
    $env:USERPROFILE = $EnvHome
    $env:XDG_CONFIG_HOME = $EnvConfigHome
    $env:GIT_CONFIG_GLOBAL = Join-Path $EnvHome ".gitconfig"
    Set-Location -LiteralPath $Fixture.EntryRepo
    $Output = & powershell @Arguments *>&1 | Out-String
    $ExitCode = $LASTEXITCODE
  } finally {
    Set-Location -LiteralPath $OldLocation
    if ($null -eq $OldGitTerminalPrompt) { Remove-Item Env:\GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue } else { $env:GIT_TERMINAL_PROMPT = $OldGitTerminalPrompt }
    if ($null -eq $OldHome) { Remove-Item Env:\HOME -ErrorAction SilentlyContinue } else { $env:HOME = $OldHome }
    if ($null -eq $OldUserProfile) { Remove-Item Env:\USERPROFILE -ErrorAction SilentlyContinue } else { $env:USERPROFILE = $OldUserProfile }
    if ($null -eq $OldXdgConfigHome) { Remove-Item Env:\XDG_CONFIG_HOME -ErrorAction SilentlyContinue } else { $env:XDG_CONFIG_HOME = $OldXdgConfigHome }
    if ($null -eq $OldGitConfigGlobal) { Remove-Item Env:\GIT_CONFIG_GLOBAL -ErrorAction SilentlyContinue } else { $env:GIT_CONFIG_GLOBAL = $OldGitConfigGlobal }
  }

  if ($ExpectFailure) {
    if ($ExitCode -eq 0) {
      throw "Expected publish-skills.ps1 to fail. Output:`n$Output"
    }
  } elseif ($ExitCode -ne 0) {
    throw "Expected publish-skills.ps1 to pass. Exit code: $ExitCode Output:`n$Output"
  }

  $Output
}

function Get-Head {
  param([Parameter(Mandatory = $true)][string] $RepoPath)

  Invoke-Git -RepoPath $RepoPath -Arguments @("rev-parse", "HEAD")
}

function Get-RemoteMain {
  param([Parameter(Mandatory = $true)][string] $RepoPath)

  $Line = Invoke-Git -RepoPath $RepoPath -Arguments @("ls-remote", "origin", "refs/heads/main")
  ($Line -split "\s+")[0]
}

function Get-SubmodulePointer {
  param(
    [Parameter(Mandatory = $true)]
    [string] $EntryRepo,

    [Parameter(Mandatory = $true)]
    [string] $SubmodulePath
  )

  $Line = Invoke-Git -RepoPath $EntryRepo -Arguments @("ls-tree", "HEAD", $SubmodulePath)
  if ($Line -notmatch "^[0-9]+ commit ([0-9a-f]{40})\s+") {
    throw "Could not read submodule pointer for $SubmodulePath from $EntryRepo.`n$Line"
  }

  $Matches[1]
}

function Add-FirstPartySkillChange {
  param(
    [Parameter(Mandatory = $true)]
    [object] $Fixture,

    [string] $SkillName = "publish-ocean-skill",

    [switch] $Stage
  )

  $SkillPath = Join-Path $Fixture.FirstPartyRepo "skills\$SkillName"
  New-Item -ItemType Directory -Force -Path $SkillPath | Out-Null
  Set-Content -LiteralPath (Join-Path $SkillPath "SKILL.md") -Value "---`nname: $SkillName`ndescription: Publish test skill.`n---`n" -Encoding UTF8
  if ($Stage) {
    Invoke-Git -RepoPath $Fixture.FirstPartyRepo -Arguments @("add", ".") | Out-Null
  }
}

function Add-CommunitySkillChange {
  param(
    [Parameter(Mandatory = $true)]
    [object] $Fixture,

    [string] $SkillName = "publish-community-skill",

    [switch] $Invalid
  )

  $SkillPath = Join-Path $Fixture.CommunityRepo "skills\$SkillName"
  New-Item -ItemType Directory -Force -Path $SkillPath | Out-Null
  Set-Content -LiteralPath (Join-Path $SkillPath "SKILL.md") -Value "---`nname: $SkillName`ndescription: Community publish test skill.`n---`n" -Encoding UTF8
  if (-not $Invalid) {
    Set-Content -LiteralPath (Join-Path $SkillPath "UPSTREAM.md") -Value "Original repository: https://example.invalid/$SkillName`nOriginal author: Example`nLicense: MIT`n" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $SkillPath "PATCHES.md") -Value "No local patches.`n" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $SkillPath "LICENSE") -Value "MIT test license`n" -Encoding UTF8
  }
}

function Assert-PublishedChildAndEntry {
  param(
    [Parameter(Mandatory = $true)]
    [object] $Fixture,

    [Parameter(Mandatory = $true)]
    [string] $ChildRepo,

    [Parameter(Mandatory = $true)]
    [string] $SubmodulePath,

    [Parameter(Mandatory = $true)]
    [string] $OldChildHead,

    [Parameter(Mandatory = $true)]
    [string] $OldEntryHead
  )

  $NewChildHead = Get-Head -RepoPath $ChildRepo
  $NewEntryHead = Get-Head -RepoPath $Fixture.EntryRepo
  Assert-NotEqual -Actual $NewChildHead -Unexpected $OldChildHead -Message "Expected child repository to receive a commit."
  Assert-NotEqual -Actual $NewEntryHead -Unexpected $OldEntryHead -Message "Expected entry repository to receive a submodule pointer commit."
  Assert-Equal -Actual (Get-RemoteMain -RepoPath $ChildRepo) -Expected $NewChildHead -Message "Expected child commit to be pushed."
  Assert-Equal -Actual (Get-RemoteMain -RepoPath $Fixture.EntryRepo) -Expected $NewEntryHead -Message "Expected entry commit to be pushed."
  Assert-Equal -Actual (Get-SubmodulePointer -EntryRepo $Fixture.EntryRepo -SubmodulePath $SubmodulePath) -Expected $NewChildHead -Message "Expected entry submodule pointer to reference child HEAD."
  Assert-GitClean -RepoPath $ChildRepo
  Assert-GitClean -RepoPath $Fixture.EntryRepo
}

function Assert-ResumedAheadChildAndEntry {
  param(
    [Parameter(Mandatory = $true)]
    [object] $Fixture,

    [Parameter(Mandatory = $true)]
    [string] $ChildRepo,

    [Parameter(Mandatory = $true)]
    [string] $SubmodulePath,

    [Parameter(Mandatory = $true)]
    [string] $AheadChildHead,

    [Parameter(Mandatory = $true)]
    [string] $OldEntryHead,

    [Parameter(Mandatory = $true)]
    [string] $Output
  )

  $NewEntryHead = Get-Head -RepoPath $Fixture.EntryRepo
  Assert-Equal -Actual (Get-Head -RepoPath $ChildRepo) -Expected $AheadChildHead -Message "Expected child HEAD to remain at the already-created commit."
  Assert-Equal -Actual (Get-RemoteMain -RepoPath $ChildRepo) -Expected $AheadChildHead -Message "Expected interrupted child commit to be pushed on rerun."
  Assert-NotEqual -Actual $NewEntryHead -Unexpected $OldEntryHead -Message "Expected entry repository to receive a submodule pointer commit on rerun."
  Assert-Equal -Actual (Get-RemoteMain -RepoPath $Fixture.EntryRepo) -Expected $NewEntryHead -Message "Expected entry rerun commit to be pushed."
  Assert-Equal -Actual (Get-SubmodulePointer -EntryRepo $Fixture.EntryRepo -SubmodulePath $SubmodulePath) -Expected $AheadChildHead -Message "Expected entry submodule pointer to reference ahead child HEAD."
  if ($Output -match "publish-no-changes") {
    throw "Interrupted publish rerun must not print publish-no-changes."
  }
  Assert-GitClean -RepoPath $ChildRepo
  Assert-GitClean -RepoPath $Fixture.EntryRepo
}

try {
  $Fixture = New-Fixture -Name "no-child-changes"
  $EntryHead = Get-Head -RepoPath $Fixture.EntryRepo
  $FirstPartyHead = Get-Head -RepoPath $Fixture.FirstPartyRepo
  $CommunityHead = Get-Head -RepoPath $Fixture.CommunityRepo
  Invoke-Publish -Fixture $Fixture | Out-Null
  Assert-Equal -Actual (Get-Head -RepoPath $Fixture.EntryRepo) -Expected $EntryHead -Message "No child changes should not commit entry."
  Assert-Equal -Actual (Get-Head -RepoPath $Fixture.FirstPartyRepo) -Expected $FirstPartyHead -Message "No child changes should not commit first-party repo."
  Assert-Equal -Actual (Get-Head -RepoPath $Fixture.CommunityRepo) -Expected $CommunityHead -Message "No child changes should not commit community repo."

  $Fixture = New-Fixture -Name "first-party-child-change"
  Add-FirstPartySkillChange -Fixture $Fixture
  $EntryHead = Get-Head -RepoPath $Fixture.EntryRepo
  $ChildHead = Get-Head -RepoPath $Fixture.FirstPartyRepo
  Invoke-Publish -Fixture $Fixture | Out-Null
  Assert-PublishedChildAndEntry -Fixture $Fixture -ChildRepo $Fixture.FirstPartyRepo -SubmodulePath "repos/oceans-skills" -OldChildHead $ChildHead -OldEntryHead $EntryHead

  $Fixture = New-Fixture -Name "resume-ahead-first-party-child"
  Add-FirstPartySkillChange -Fixture $Fixture -SkillName "ahead-ocean-skill"
  Invoke-Git -RepoPath $Fixture.FirstPartyRepo -Arguments @("add", "skills") | Out-Null
  Invoke-Git -RepoPath $Fixture.FirstPartyRepo -Arguments @("commit", "-m", "skills: publish staged first-party skills") | Out-Null
  $EntryHead = Get-Head -RepoPath $Fixture.EntryRepo
  $AheadChildHead = Get-Head -RepoPath $Fixture.FirstPartyRepo
  $ChildRemoteHead = Get-RemoteMain -RepoPath $Fixture.FirstPartyRepo
  Assert-NotEqual -Actual $AheadChildHead -Unexpected $ChildRemoteHead -Message "Fixture should leave child repo ahead of origin/main."
  $Output = Invoke-Publish -Fixture $Fixture
  Assert-ResumedAheadChildAndEntry -Fixture $Fixture -ChildRepo $Fixture.FirstPartyRepo -SubmodulePath "repos/oceans-skills" -AheadChildHead $AheadChildHead -OldEntryHead $EntryHead -Output $Output

  $Fixture = New-Fixture -Name "community-child-change"
  Add-CommunitySkillChange -Fixture $Fixture
  $EntryHead = Get-Head -RepoPath $Fixture.EntryRepo
  $ChildHead = Get-Head -RepoPath $Fixture.CommunityRepo
  Invoke-Publish -Fixture $Fixture | Out-Null
  Assert-PublishedChildAndEntry -Fixture $Fixture -ChildRepo $Fixture.CommunityRepo -SubmodulePath "repos/community-skills" -OldChildHead $ChildHead -OldEntryHead $EntryHead

  $Fixture = New-Fixture -Name "validate-failure"
  Add-CommunitySkillChange -Fixture $Fixture -Invalid
  $EntryHead = Get-Head -RepoPath $Fixture.EntryRepo
  $ChildHead = Get-Head -RepoPath $Fixture.CommunityRepo
  Invoke-Publish -Fixture $Fixture -ExpectFailure | Out-Null
  Assert-Equal -Actual (Get-Head -RepoPath $Fixture.EntryRepo) -Expected $EntryHead -Message "Validate failure should not commit entry."
  Assert-Equal -Actual (Get-Head -RepoPath $Fixture.CommunityRepo) -Expected $ChildHead -Message "Validate failure should not commit child."

  $Fixture = New-Fixture -Name "empty-community-attribution-failure"
  Add-CommunitySkillChange -Fixture $Fixture -SkillName "empty-community-skill" -Invalid
  $EmptySkillPath = Join-Path $Fixture.CommunityRepo "skills\empty-community-skill"
  Set-Content -LiteralPath (Join-Path $EmptySkillPath "UPSTREAM.md") -Value "" -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $EmptySkillPath "PATCHES.md") -Value "   " -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $EmptySkillPath "LICENSE") -Value "" -Encoding UTF8
  $EntryHead = Get-Head -RepoPath $Fixture.EntryRepo
  $ChildHead = Get-Head -RepoPath $Fixture.CommunityRepo
  Invoke-Publish -Fixture $Fixture -ExpectFailure | Out-Null
  Assert-Equal -Actual (Get-Head -RepoPath $Fixture.EntryRepo) -Expected $EntryHead -Message "Empty community attribution should not commit entry."
  Assert-Equal -Actual (Get-Head -RepoPath $Fixture.CommunityRepo) -Expected $ChildHead -Message "Empty community attribution should not commit child."

  $Fixture = New-Fixture -Name "entry-dirty-outside-child-repos"
  Add-FirstPartySkillChange -Fixture $Fixture
  Set-Content -LiteralPath (Join-Path $Fixture.EntryRepo "ENTRY-DIRTY.txt") -Value "dirty entry file" -Encoding UTF8
  $EntryHead = Get-Head -RepoPath $Fixture.EntryRepo
  $ChildHead = Get-Head -RepoPath $Fixture.FirstPartyRepo
  Invoke-Publish -Fixture $Fixture -ExpectFailure | Out-Null
  Assert-Equal -Actual (Get-Head -RepoPath $Fixture.EntryRepo) -Expected $EntryHead -Message "Dirty entry repo should not commit entry."
  Assert-Equal -Actual (Get-Head -RepoPath $Fixture.FirstPartyRepo) -Expected $ChildHead -Message "Dirty entry repo should not commit child."

  $Fixture = New-Fixture -Name "ahead-child-outside-skills"
  Set-Content -LiteralPath (Join-Path $Fixture.FirstPartyRepo "README.md") -Value "unrelated child commit" -Encoding UTF8
  Invoke-Git -RepoPath $Fixture.FirstPartyRepo -Arguments @("add", "README.md") | Out-Null
  Invoke-Git -RepoPath $Fixture.FirstPartyRepo -Arguments @("commit", "-m", "docs: unrelated child change") | Out-Null
  $EntryHead = Get-Head -RepoPath $Fixture.EntryRepo
  $ChildHead = Get-Head -RepoPath $Fixture.FirstPartyRepo
  $ChildRemoteHead = Get-RemoteMain -RepoPath $Fixture.FirstPartyRepo
  Invoke-Publish -Fixture $Fixture -ExpectFailure | Out-Null
  Assert-Equal -Actual (Get-Head -RepoPath $Fixture.EntryRepo) -Expected $EntryHead -Message "Ahead child outside skills should not commit entry."
  Assert-Equal -Actual (Get-Head -RepoPath $Fixture.FirstPartyRepo) -Expected $ChildHead -Message "Ahead child outside skills should keep local child commit."
  Assert-Equal -Actual (Get-RemoteMain -RepoPath $Fixture.FirstPartyRepo) -Expected $ChildRemoteHead -Message "Ahead child outside skills should not push child commit."

  $Fixture = New-Fixture -Name "ahead-entry-outside-submodules"
  Set-Content -LiteralPath (Join-Path $Fixture.EntryRepo "ENTRY-AHEAD.txt") -Value "unrelated entry commit" -Encoding UTF8
  Invoke-Git -RepoPath $Fixture.EntryRepo -Arguments @("add", "ENTRY-AHEAD.txt") | Out-Null
  Invoke-Git -RepoPath $Fixture.EntryRepo -Arguments @("commit", "-m", "docs: unrelated entry change") | Out-Null
  $EntryHead = Get-Head -RepoPath $Fixture.EntryRepo
  $EntryRemoteHead = Get-RemoteMain -RepoPath $Fixture.EntryRepo
  Invoke-Publish -Fixture $Fixture -ExpectFailure | Out-Null
  Assert-Equal -Actual (Get-Head -RepoPath $Fixture.EntryRepo) -Expected $EntryHead -Message "Ahead entry outside submodules should keep local entry commit."
  Assert-Equal -Actual (Get-RemoteMain -RepoPath $Fixture.EntryRepo) -Expected $EntryRemoteHead -Message "Ahead entry outside submodules should not push entry commit."

  $Fixture = New-Fixture -Name "only-child-staged-skill-changes"
  Add-FirstPartySkillChange -Fixture $Fixture -SkillName "staged-ocean-skill" -Stage
  $EntryHead = Get-Head -RepoPath $Fixture.EntryRepo
  $ChildHead = Get-Head -RepoPath $Fixture.FirstPartyRepo
  Invoke-Publish -Fixture $Fixture | Out-Null
  Assert-PublishedChildAndEntry -Fixture $Fixture -ChildRepo $Fixture.FirstPartyRepo -SubmodulePath "repos/oceans-skills" -OldChildHead $ChildHead -OldEntryHead $EntryHead

  $Fixture = New-Fixture -Name "entry-behind-origin-main"
  $OtherEntry = Join-Path $Fixture.WorkRoot "other-entry"
  Invoke-GitGlobal -Arguments @("clone", $Fixture.EntryRemote, $OtherEntry) | Out-Null
  Invoke-Git -RepoPath $OtherEntry -Arguments @("config", "user.email", "publish-test@example.invalid") | Out-Null
  Invoke-Git -RepoPath $OtherEntry -Arguments @("config", "user.name", "Publish Test") | Out-Null
  Set-Content -LiteralPath (Join-Path $OtherEntry "REMOTE-AHEAD.txt") -Value "remote main advanced" -Encoding UTF8
  Invoke-Git -RepoPath $OtherEntry -Arguments @("add", ".") | Out-Null
  Invoke-Git -RepoPath $OtherEntry -Arguments @("commit", "-m", "advance origin main") | Out-Null
  Invoke-Git -RepoPath $OtherEntry -Arguments @("push", "origin", "main") | Out-Null
  Add-FirstPartySkillChange -Fixture $Fixture
  $EntryHead = Get-Head -RepoPath $Fixture.EntryRepo
  $ChildHead = Get-Head -RepoPath $Fixture.FirstPartyRepo
  Invoke-Publish -Fixture $Fixture -ExpectFailure | Out-Null
  Assert-Equal -Actual (Get-Head -RepoPath $Fixture.EntryRepo) -Expected $EntryHead -Message "Behind origin/main should not commit entry."
  Assert-Equal -Actual (Get-Head -RepoPath $Fixture.FirstPartyRepo) -Expected $ChildHead -Message "Behind origin/main should not commit child."

  $Fixture = New-Fixture -Name "dry-run"
  Add-FirstPartySkillChange -Fixture $Fixture
  $EntryHead = Get-Head -RepoPath $Fixture.EntryRepo
  $ChildHead = Get-Head -RepoPath $Fixture.FirstPartyRepo
  $EntryRemoteHead = Get-RemoteMain -RepoPath $Fixture.EntryRepo
  $ChildRemoteHead = Get-RemoteMain -RepoPath $Fixture.FirstPartyRepo
  Invoke-Publish -Fixture $Fixture -DryRun | Out-Null
  Assert-Equal -Actual (Get-Head -RepoPath $Fixture.EntryRepo) -Expected $EntryHead -Message "Dry run should not commit entry."
  Assert-Equal -Actual (Get-Head -RepoPath $Fixture.FirstPartyRepo) -Expected $ChildHead -Message "Dry run should not commit child."
  Assert-Equal -Actual (Get-RemoteMain -RepoPath $Fixture.EntryRepo) -Expected $EntryRemoteHead -Message "Dry run should not push entry."
  Assert-Equal -Actual (Get-RemoteMain -RepoPath $Fixture.FirstPartyRepo) -Expected $ChildRemoteHead -Message "Dry run should not push child."

  Write-Host "PowerShell publish contract tests passed."
} finally {
  Remove-SandboxRoot
}
