$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$SandboxRoot = Join-Path $env:TEMP ("oceans-stage-test-" + [Guid]::NewGuid().ToString("N"))

function Assert-Contains {
  param(
    [Parameter(Mandatory = $true)]
    [string] $Text,

    [Parameter(Mandatory = $true)]
    [string] $Expected
  )

  if (-not $Text.Contains($Expected)) {
    throw "Expected output to contain: $Expected"
  }
}

function Assert-PathExists {
  param([Parameter(Mandatory = $true)][string] $Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    throw "Expected path to exist: $Path"
  }
}

function Assert-PathMissing {
  param([Parameter(Mandatory = $true)][string] $Path)

  if (Test-Path -LiteralPath $Path) {
    throw "Expected path not to exist: $Path"
  }
}

function Assert-FileContains {
  param(
    [Parameter(Mandatory = $true)]
    [string] $Path,

    [Parameter(Mandatory = $true)]
    [string] $Expected
  )

  Assert-PathExists -Path $Path
  $Text = Get-Content -LiteralPath $Path -Raw
  Assert-Contains -Text $Text -Expected $Expected
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
      -not $LeafName.StartsWith("oceans-stage-test-", [StringComparison]::Ordinal)) {
    throw "Unsafe cleanup target: $ResolvedRoot"
  }

  Remove-Item -LiteralPath $ResolvedRoot -Recurse -Force
}

function Invoke-GitQuiet {
  param(
    [Parameter(Mandatory = $true)]
    [string] $RepoPath,

    [Parameter(Mandatory = $true)]
    [string[]] $Arguments
  )

  & git -C $RepoPath @Arguments *> $null
  if ($LASTEXITCODE -ne 0) {
    throw "git -C $RepoPath $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
  }
}

function Initialize-TestRepository {
  param([Parameter(Mandatory = $true)][string] $RepoPath)

  New-Item -ItemType Directory -Force -Path (Join-Path $RepoPath "skills") | Out-Null
  & git -C $RepoPath init *> $null
  if ($LASTEXITCODE -ne 0) { throw "git init failed for $RepoPath" }
  Invoke-GitQuiet -RepoPath $RepoPath -Arguments @("checkout", "-q", "-B", "main")
  Invoke-GitQuiet -RepoPath $RepoPath -Arguments @("config", "user.email", "stage-test@example.invalid")
  Invoke-GitQuiet -RepoPath $RepoPath -Arguments @("config", "user.name", "Stage Test")
  Invoke-GitQuiet -RepoPath $RepoPath -Arguments @("config", "core.autocrlf", "false")
  Set-Content -LiteralPath (Join-Path $RepoPath "skills\.gitkeep") -Value "" -Encoding UTF8
  Invoke-GitQuiet -RepoPath $RepoPath -Arguments @("add", ".")
  Invoke-GitQuiet -RepoPath $RepoPath -Arguments @("commit", "-m", "initial")
}

function New-Fixture {
  param([Parameter(Mandatory = $true)][string] $Name)

  $Root = Join-Path $SandboxRoot $Name
  $SourceRoot = Join-Path $Root "source"
  $FirstPartyRepo = Join-Path $Root "repo\oceans-skills"
  $CommunityRepo = Join-Path $Root "repo\community-skills"
  $FirstPartyRoot = Join-Path $FirstPartyRepo "skills"
  $CommunityRoot = Join-Path $CommunityRepo "skills"

  New-Item -ItemType Directory -Force -Path $SourceRoot | Out-Null
  Initialize-TestRepository -RepoPath $FirstPartyRepo
  Initialize-TestRepository -RepoPath $CommunityRepo

  New-Item -ItemType Directory -Force -Path (Join-Path $SourceRoot "good-skill") | Out-Null
  Set-Content -LiteralPath (Join-Path $SourceRoot "good-skill\SKILL.md") -Value "---`nname: good-skill`ndescription: Safe test skill.`n---`n" -Encoding UTF8

  New-Item -ItemType Directory -Force -Path (Join-Path $SourceRoot "community-skill") | Out-Null
  Set-Content -LiteralPath (Join-Path $SourceRoot "community-skill\SKILL.md") -Value "---`nname: community-skill`ndescription: Community test skill.`n---`n" -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $SourceRoot "community-skill\LICENSE.source") -Value "Example source license" -Encoding UTF8

  New-Item -ItemType Directory -Force -Path (Join-Path $SourceRoot "risky-skill") | Out-Null
  Set-Content -LiteralPath (Join-Path $SourceRoot "risky-skill\SKILL.md") -Value "---`nname: risky-skill`ndescription: Risky test skill.`n---`napi_key: test-value`n" -Encoding UTF8

  [PSCustomObject]@{
    Root = $Root
    SourceRoot = $SourceRoot
    FirstPartyRepo = $FirstPartyRepo
    CommunityRepo = $CommunityRepo
    FirstPartyRoot = $FirstPartyRoot
    CommunityRoot = $CommunityRoot
  }
}

function Invoke-StageSkill {
  param(
    [Parameter(Mandatory = $true)]
    [object] $Fixture,

    [Parameter(Mandatory = $true)]
    [string[]] $Arguments,

    [switch] $ExpectFailure
  )

  $Output = & powershell -NoProfile -ExecutionPolicy Bypass -File "$RepoRoot\scripts\stage-skill.ps1" @Arguments *>&1 | Out-String
  $ExitCode = $LASTEXITCODE
  if ($ExpectFailure) {
    if ($ExitCode -eq 0) {
      throw "Expected stage-skill.ps1 to fail. Output:`n$Output"
    }
  } elseif ($ExitCode -ne 0) {
    throw "Expected stage-skill.ps1 to pass. Exit code: $ExitCode Output:`n$Output"
  }

  $Output
}

function Get-BaseArgs {
  param(
    [Parameter(Mandatory = $true)]
    [object] $Fixture,

    [Parameter(Mandatory = $true)]
    [string] $Skill,

    [Parameter(Mandatory = $true)]
    [string] $Target
  )

  @(
    "-SourceRoot", $Fixture.SourceRoot,
    "-Skill", $Skill,
    "-Target", $Target,
    "-FirstPartySkillsRoot", $Fixture.FirstPartyRoot,
    "-CommunitySkillsRoot", $Fixture.CommunityRoot
  )
}

try {
  $Fixture = New-Fixture -Name "success"
  $Output = & "$RepoRoot\scripts\stage-skill.ps1" `
    -SourceRoot $Fixture.SourceRoot `
    -Skill "good-skill" `
    -Target "oceans" `
    -FirstPartySkillsRoot $Fixture.FirstPartyRoot `
    -CommunitySkillsRoot $Fixture.CommunityRoot *>&1 | Out-String
  if ($LASTEXITCODE -ne 0) {
    throw "Expected stage-skill.ps1 to pass. Output:`n$Output"
  }

  Assert-Contains -Text $Output -Expected "staged-skill: good-skill"
  Assert-Contains -Text $Output -Expected "target_repository: oceans-skills"
  Assert-Contains -Text $Output -Expected "risk_status: none detected"
  Assert-PathExists -Path (Join-Path $Fixture.FirstPartyRoot "good-skill\SKILL.md")
  Assert-PathMissing -Path (Join-Path $Fixture.FirstPartyRoot "good-skill\.oceans-skill-source")

  $Fixture = New-Fixture -Name "runtime-source"
  $AgentsHome = Join-Path $Fixture.Root "agents-home"
  $AgentsSkillRoot = Join-Path $AgentsHome "skills"
  New-Item -ItemType Directory -Force -Path (Join-Path $AgentsSkillRoot "agents-skill") | Out-Null
  Set-Content -LiteralPath (Join-Path $AgentsSkillRoot "agents-skill\SKILL.md") -Value "---`nname: agents-skill`ndescription: Agents runtime skill.`n---`n" -Encoding UTF8
  $OldAgentsHome = $env:AGENTS_HOME
  try {
    $env:AGENTS_HOME = $AgentsHome
    $Output = & "$RepoRoot\scripts\stage-skill.ps1" `
      -Runtime "agents" `
      -Skill "agents-skill" `
      -Target "oceans" `
      -FirstPartySkillsRoot $Fixture.FirstPartyRoot `
      -CommunitySkillsRoot $Fixture.CommunityRoot *>&1 | Out-String
  } finally {
    if ($null -eq $OldAgentsHome) { Remove-Item Env:\AGENTS_HOME -ErrorAction SilentlyContinue } else { $env:AGENTS_HOME = $OldAgentsHome }
  }
  if ($LASTEXITCODE -ne 0) {
    throw "Expected runtime stage to pass. Output:`n$Output"
  }
  Assert-Contains -Text $Output -Expected "staged-skill: agents-skill"
  Assert-PathExists -Path (Join-Path $Fixture.FirstPartyRoot "agents-skill\SKILL.md")

  $Fixture = New-Fixture -Name "source-root-wins"
  $AgentsHome = Join-Path $Fixture.Root "agents-home"
  New-Item -ItemType Directory -Force -Path (Join-Path $AgentsHome "skills") | Out-Null
  $OldAgentsHome = $env:AGENTS_HOME
  try {
    $env:AGENTS_HOME = $AgentsHome
    $Output = & "$RepoRoot\scripts\stage-skill.ps1" `
      -SourceRoot $Fixture.SourceRoot `
      -Runtime "agents" `
      -Skill "good-skill" `
      -Target "oceans" `
      -FirstPartySkillsRoot $Fixture.FirstPartyRoot `
      -CommunitySkillsRoot $Fixture.CommunityRoot *>&1 | Out-String
  } finally {
    if ($null -eq $OldAgentsHome) { Remove-Item Env:\AGENTS_HOME -ErrorAction SilentlyContinue } else { $env:AGENTS_HOME = $OldAgentsHome }
  }
  if ($LASTEXITCODE -ne 0) {
    throw "Expected SourceRoot override stage to pass. Output:`n$Output"
  }
  Assert-Contains -Text $Output -Expected "staged-skill: good-skill"
  Assert-PathExists -Path (Join-Path $Fixture.FirstPartyRoot "good-skill\SKILL.md")

  $Fixture = New-Fixture -Name "system-rejected"
  New-Item -ItemType Directory -Force -Path (Join-Path $Fixture.SourceRoot ".system") | Out-Null
  Set-Content -LiteralPath (Join-Path $Fixture.SourceRoot ".system\SKILL.md") -Value "---`nname: system`ndescription: System skill.`n---`n" -Encoding UTF8
  $Args = Get-BaseArgs -Fixture $Fixture -Skill ".system" -Target "oceans"
  $Output = Invoke-StageSkill -Fixture $Fixture -Arguments $Args -ExpectFailure
  Assert-Contains -Text $Output -Expected "skip-system: .system"

  $Fixture = New-Fixture -Name "missing-skill-md"
  New-Item -ItemType Directory -Force -Path (Join-Path $Fixture.SourceRoot "missing-skill") | Out-Null
  Set-Content -LiteralPath (Join-Path $Fixture.SourceRoot "missing-skill\README.md") -Value "Missing SKILL.md" -Encoding UTF8
  $Args = Get-BaseArgs -Fixture $Fixture -Skill "missing-skill" -Target "oceans"
  $Output = Invoke-StageSkill -Fixture $Fixture -Arguments $Args -ExpectFailure
  Assert-Contains -Text $Output -Expected "missing-skill-md: missing-skill"

  $Fixture = New-Fixture -Name "metadata-mismatch"
  New-Item -ItemType Directory -Force -Path (Join-Path $Fixture.SourceRoot "folder-name") | Out-Null
  Set-Content -LiteralPath (Join-Path $Fixture.SourceRoot "folder-name\SKILL.md") -Value "---`nname: different-name`ndescription: Name mismatch.`n---`n" -Encoding UTF8
  $Args = Get-BaseArgs -Fixture $Fixture -Skill "folder-name" -Target "oceans"
  $Output = Invoke-StageSkill -Fixture $Fixture -Arguments $Args -ExpectFailure
  Assert-Contains -Text $Output -Expected "invalid-skill-metadata: folder-name"
  Assert-Contains -Text $Output -Expected "risk: skill name does not match folder name"

  $Fixture = New-Fixture -Name "metadata-missing-description"
  New-Item -ItemType Directory -Force -Path (Join-Path $Fixture.SourceRoot "missing-description") | Out-Null
  Set-Content -LiteralPath (Join-Path $Fixture.SourceRoot "missing-description\SKILL.md") -Value "---`nname: missing-description`n---`n" -Encoding UTF8
  $Args = Get-BaseArgs -Fixture $Fixture -Skill "missing-description" -Target "oceans"
  $Output = Invoke-StageSkill -Fixture $Fixture -Arguments $Args -ExpectFailure
  Assert-Contains -Text $Output -Expected "invalid-skill-metadata: missing-description"
  Assert-Contains -Text $Output -Expected "risk: missing skill description"

  $Fixture = New-Fixture -Name "crlf-uppercase-frontmatter"
  New-Item -ItemType Directory -Force -Path (Join-Path $Fixture.SourceRoot "crlf-skill") | Out-Null
  Set-Content -LiteralPath (Join-Path $Fixture.SourceRoot "crlf-skill\SKILL.md") -Value "---`r`nName: crlf-skill`r`nDescription: CRLF metadata.`r`n---`r`n" -NoNewline -Encoding UTF8
  $Args = Get-BaseArgs -Fixture $Fixture -Skill "crlf-skill" -Target "oceans"
  $Output = Invoke-StageSkill -Fixture $Fixture -Arguments $Args
  Assert-Contains -Text $Output -Expected "staged-skill: crlf-skill"

  $Fixture = New-Fixture -Name "secret-risk"
  $Args = Get-BaseArgs -Fixture $Fixture -Skill "risky-skill" -Target "oceans"
  $Output = Invoke-StageSkill -Fixture $Fixture -Arguments $Args -ExpectFailure
  Assert-Contains -Text $Output -Expected "risk-blocked: risky-skill"
  Assert-Contains -Text $Output -Expected "risk: secret-like text"

  $Fixture = New-Fixture -Name "path-risk"
  New-Item -ItemType Directory -Force -Path (Join-Path $Fixture.SourceRoot "path-skill") | Out-Null
  Set-Content -LiteralPath (Join-Path $Fixture.SourceRoot "path-skill\SKILL.md") -Value "---`nname: path-skill`ndescription: Uses C:\users\Name With Space\private-notes.`n---`n" -Encoding UTF8
  $Args = Get-BaseArgs -Fixture $Fixture -Skill "path-skill" -Target "oceans"
  $Output = Invoke-StageSkill -Fixture $Fixture -Arguments $Args -ExpectFailure
  Assert-Contains -Text $Output -Expected "risk-blocked: path-skill"
  Assert-Contains -Text $Output -Expected "risk: local absolute path"

  $Fixture = New-Fixture -Name "benign-route-path"
  New-Item -ItemType Directory -Force -Path (Join-Path $Fixture.SourceRoot "route-skill\data\__pycache__") | Out-Null
  Set-Content -LiteralPath (Join-Path $Fixture.SourceRoot "route-skill\SKILL.md") -Value "---`nname: route-skill`ndescription: Mentions app API users route.`n---`napp/api/users/route.ts`n/homework/project`n" -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $Fixture.SourceRoot "route-skill\data\__pycache__\cache.pyc") -Value "C:\Users\example\cache-only" -Encoding UTF8
  $Args = Get-BaseArgs -Fixture $Fixture -Skill "route-skill" -Target "oceans"
  $Output = Invoke-StageSkill -Fixture $Fixture -Arguments $Args
  Assert-Contains -Text $Output -Expected "staged-skill: route-skill"
  Assert-Contains -Text $Output -Expected "risk_status: none detected"
  Assert-PathExists -Path (Join-Path $Fixture.FirstPartyRoot "route-skill\SKILL.md")
  Assert-PathMissing -Path (Join-Path $Fixture.FirstPartyRoot "route-skill\data\__pycache__\cache.pyc")

  $Fixture = New-Fixture -Name "missing-license-risk"
  New-Item -ItemType Directory -Force -Path (Join-Path $Fixture.SourceRoot "missing-license-skill") | Out-Null
  Set-Content -LiteralPath (Join-Path $Fixture.SourceRoot "missing-license-skill\SKILL.md") -Value "---`nname: missing-license-skill`ndescription: Missing license reference.`nlicense: Complete terms in LICENSE.txt`n---`n" -Encoding UTF8
  $Args = Get-BaseArgs -Fixture $Fixture -Skill "missing-license-skill" -Target "oceans"
  $Output = Invoke-StageSkill -Fixture $Fixture -Arguments $Args -ExpectFailure
  Assert-Contains -Text $Output -Expected "risk-blocked: missing-license-skill"
  Assert-Contains -Text $Output -Expected "risk: missing referenced license file"

  $Fixture = New-Fixture -Name "large-risk"
  New-Item -ItemType Directory -Force -Path (Join-Path $Fixture.SourceRoot "large-skill") | Out-Null
  Set-Content -LiteralPath (Join-Path $Fixture.SourceRoot "large-skill\SKILL.md") -Value "---`nname: large-skill`ndescription: Large file skill.`n---`n" -Encoding UTF8
  $LargeFile = Join-Path $Fixture.SourceRoot "large-skill\large.bin"
  [System.IO.File]::WriteAllBytes($LargeFile, (New-Object byte[] 1048577))
  $Args = Get-BaseArgs -Fixture $Fixture -Skill "large-skill" -Target "oceans"
  $Output = Invoke-StageSkill -Fixture $Fixture -Arguments $Args -ExpectFailure
  Assert-Contains -Text $Output -Expected "risk-blocked: large-skill"
  Assert-Contains -Text $Output -Expected "risk: file larger than 1 MB"

  $Fixture = New-Fixture -Name "binary-risk"
  New-Item -ItemType Directory -Force -Path (Join-Path $Fixture.SourceRoot "binary-skill") | Out-Null
  Set-Content -LiteralPath (Join-Path $Fixture.SourceRoot "binary-skill\SKILL.md") -Value "---`nname: binary-skill`ndescription: Binary file skill.`n---`n" -Encoding UTF8
  $BinaryFile = Join-Path $Fixture.SourceRoot "binary-skill\invalid.bin"
  [System.IO.File]::WriteAllBytes($BinaryFile, [byte[]](0xff, 0xfe, 0xfd))
  $Args = Get-BaseArgs -Fixture $Fixture -Skill "binary-skill" -Target "oceans"
  $Output = Invoke-StageSkill -Fixture $Fixture -Arguments $Args -ExpectFailure
  Assert-Contains -Text $Output -Expected "risk-blocked: binary-skill"
  Assert-Contains -Text $Output -Expected "risk: binary or unreadable file"

  $Fixture = New-Fixture -Name "reparse-point-rejected"
  New-Item -ItemType Directory -Force -Path (Join-Path $Fixture.SourceRoot "reparse-skill") | Out-Null
  Set-Content -LiteralPath (Join-Path $Fixture.SourceRoot "reparse-skill\SKILL.md") -Value "---`nname: reparse-skill`ndescription: Reparse point skill.`n---`n" -Encoding UTF8
  $ExternalDirectory = Join-Path $Fixture.Root "external-directory"
  New-Item -ItemType Directory -Force -Path $ExternalDirectory | Out-Null
  Set-Content -LiteralPath (Join-Path $ExternalDirectory "secret.txt") -Value "api_key: external-secret" -Encoding UTF8
  $JunctionPath = Join-Path $Fixture.SourceRoot "reparse-skill\external-link"
  New-Item -ItemType Junction -Path $JunctionPath -Target $ExternalDirectory | Out-Null
  $Args = (Get-BaseArgs -Fixture $Fixture -Skill "reparse-skill" -Target "oceans") + @("-AllowRisk")
  $Output = Invoke-StageSkill -Fixture $Fixture -Arguments $Args -ExpectFailure
  Assert-Contains -Text $Output -Expected "unsupported-symlink: reparse-skill"
  Assert-PathMissing -Path (Join-Path $Fixture.FirstPartyRoot "reparse-skill\external-link\secret.txt")

  $Fixture = New-Fixture -Name "community-missing-attribution"
  $Args = Get-BaseArgs -Fixture $Fixture -Skill "community-skill" -Target "community"
  $Output = Invoke-StageSkill -Fixture $Fixture -Arguments $Args -ExpectFailure
  Assert-Contains -Text $Output -Expected "missing-community-attribution: community-skill"

  $Fixture = New-Fixture -Name "community-attribution"
  $LicenseFile = Join-Path $Fixture.SourceRoot "community-skill\LICENSE.source"
  $Args = (Get-BaseArgs -Fixture $Fixture -Skill "community-skill" -Target "community") + @(
    "-UpstreamUrl", "https://example.invalid/community-skill",
    "-UpstreamAuthor", "Example Author",
    "-UpstreamLicense", "MIT",
    "-LicenseFile", $LicenseFile,
    "-PatchSummary", "Adjusted metadata for oceans777."
  )
  $Output = Invoke-StageSkill -Fixture $Fixture -Arguments $Args
  $CommunityTarget = Join-Path $Fixture.CommunityRoot "community-skill"
  Assert-Contains -Text $Output -Expected "staged-skill: community-skill"
  Assert-FileContains -Path (Join-Path $CommunityTarget "UPSTREAM.md") -Expected "Original repository: https://example.invalid/community-skill"
  Assert-FileContains -Path (Join-Path $CommunityTarget "UPSTREAM.md") -Expected "Original author: Example Author"
  Assert-FileContains -Path (Join-Path $CommunityTarget "UPSTREAM.md") -Expected "License: MIT"
  Assert-FileContains -Path (Join-Path $CommunityTarget "PATCHES.md") -Expected "Adjusted metadata for oceans777."
  Assert-FileContains -Path (Join-Path $CommunityTarget "LICENSE") -Expected "Example source license"

  $Fixture = New-Fixture -Name "community-partial-attribution"
  Set-Content -LiteralPath (Join-Path $Fixture.SourceRoot "community-skill\UPSTREAM.md") -Value "# Custom upstream`nOriginal project notes" -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $Fixture.SourceRoot "community-skill\LICENSE") -Value "Custom existing license" -Encoding UTF8
  $LicenseFile = Join-Path $Fixture.SourceRoot "community-skill\LICENSE.source"
  $Args = (Get-BaseArgs -Fixture $Fixture -Skill "community-skill" -Target "community") + @(
    "-UpstreamUrl", "https://example.invalid/replacement",
    "-UpstreamAuthor", "Replacement Author",
    "-UpstreamLicense", "Apache-2.0",
    "-LicenseFile", $LicenseFile,
    "-PatchSummary", "Added local patch notes."
  )
  $Output = Invoke-StageSkill -Fixture $Fixture -Arguments $Args
  $CommunityTarget = Join-Path $Fixture.CommunityRoot "community-skill"
  Assert-Contains -Text $Output -Expected "staged-skill: community-skill"
  Assert-FileContains -Path (Join-Path $CommunityTarget "UPSTREAM.md") -Expected "Original project notes"
  Assert-FileContains -Path (Join-Path $CommunityTarget "LICENSE") -Expected "Custom existing license"
  Assert-FileContains -Path (Join-Path $CommunityTarget "PATCHES.md") -Expected "Added local patch notes."

  $Fixture = New-Fixture -Name "dry-run"
  $Args = (Get-BaseArgs -Fixture $Fixture -Skill "good-skill" -Target "oceans") + @("-DryRun")
  $Output = Invoke-StageSkill -Fixture $Fixture -Arguments $Args
  Assert-Contains -Text $Output -Expected "dry_run: true"
  Assert-PathMissing -Path (Join-Path $Fixture.FirstPartyRoot "good-skill")

  $Fixture = New-Fixture -Name "cross-repository-duplicate"
  New-Item -ItemType Directory -Force -Path (Join-Path $Fixture.CommunityRoot "good-skill") | Out-Null
  Set-Content -LiteralPath (Join-Path $Fixture.CommunityRoot "good-skill\SKILL.md") -Value "---`nname: good-skill`ndescription: Other repo copy.`n---`n" -Encoding UTF8
  Invoke-GitQuiet -RepoPath $Fixture.CommunityRepo -Arguments @("add", ".")
  Invoke-GitQuiet -RepoPath $Fixture.CommunityRepo -Arguments @("commit", "-m", "add duplicate")
  $Args = (Get-BaseArgs -Fixture $Fixture -Skill "good-skill" -Target "oceans") + @("-ReplaceExisting")
  $Output = Invoke-StageSkill -Fixture $Fixture -Arguments $Args -ExpectFailure
  Assert-Contains -Text $Output -Expected "duplicate-cross-repository: good-skill"

  $Fixture = New-Fixture -Name "detached-head"
  Invoke-GitQuiet -RepoPath $Fixture.FirstPartyRepo -Arguments @("checkout", "-q", "--detach", "HEAD")
  $Args = Get-BaseArgs -Fixture $Fixture -Skill "good-skill" -Target "oceans"
  $Output = Invoke-StageSkill -Fixture $Fixture -Arguments $Args -ExpectFailure
  Assert-Contains -Text $Output -Expected "target-not-main: oceans-skills"

  $Fixture = New-Fixture -Name "dirty-outside-skills"
  Set-Content -LiteralPath (Join-Path $Fixture.FirstPartyRepo "README.md") -Value "dirty outside skills" -Encoding UTF8
  $Args = Get-BaseArgs -Fixture $Fixture -Skill "good-skill" -Target "oceans"
  $Output = Invoke-StageSkill -Fixture $Fixture -Arguments $Args -ExpectFailure
  Assert-Contains -Text $Output -Expected "target-dirty-outside-skills: oceans-skills"

  $Fixture = New-Fixture -Name "dirty-rename-outside-skills"
  Set-Content -LiteralPath (Join-Path $Fixture.FirstPartyRepo "README.md") -Value "tracked readme" -Encoding UTF8
  Invoke-GitQuiet -RepoPath $Fixture.FirstPartyRepo -Arguments @("add", "README.md")
  Invoke-GitQuiet -RepoPath $Fixture.FirstPartyRepo -Arguments @("commit", "-m", "add readme")
  Invoke-GitQuiet -RepoPath $Fixture.FirstPartyRepo -Arguments @("mv", "README.md", "skills/renamed-readme.md")
  $Args = Get-BaseArgs -Fixture $Fixture -Skill "good-skill" -Target "oceans"
  $Output = Invoke-StageSkill -Fixture $Fixture -Arguments $Args -ExpectFailure
  Assert-Contains -Text $Output -Expected "target-dirty-outside-skills: oceans-skills"

  Write-Host "PowerShell stage skill test passed."
} finally {
  Remove-SandboxRoot
}
