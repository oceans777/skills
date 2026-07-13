$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
$CanonicalTemp = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $env:TEMP).Path)
$TestRoot = Join-Path $CanonicalTemp ("oceans-bundled-skills-test-" + [Guid]::NewGuid().ToString('N'))
$AosRoot = Join-Path $RepoRoot 'repos\oceans-skills\skills\agent-operating-system'

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    & git @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

function Invoke-WindowsPowerShell {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    & powershell -NoProfile -ExecutionPolicy Bypass @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "powershell $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

try {
    $BootstrapScript = Join-Path $AosRoot 'scripts\bootstrap-agent-os.ps1'
    $StartTaskScript = Join-Path $AosRoot 'scripts\start-agent-task.ps1'
    if (-not (Test-Path -LiteralPath $BootstrapScript -PathType Leaf)) {
        throw "Missing bundled bootstrap script: $BootstrapScript"
    }
    if (-not (Test-Path -LiteralPath $StartTaskScript -PathType Leaf)) {
        throw "Missing bundled task script: $StartTaskScript"
    }

    $RemoteRoot = Join-Path $TestRoot 'origin.git'
    $ProjectRoot = Join-Path $TestRoot 'project'
    $WorktreeRoot = Join-Path $TestRoot 'worktrees'

    Invoke-Git -Arguments @('init', '--bare', '--initial-branch=main', $RemoteRoot)
    Invoke-Git -Arguments @('init', '-b', 'main', $ProjectRoot)
    Invoke-Git -Arguments @('-C', $ProjectRoot, 'config', 'user.name', 'Oceans Skills Test')
    Invoke-Git -Arguments @('-C', $ProjectRoot, 'config', 'user.email', 'skills-test@example.invalid')
    Set-Content -LiteralPath (Join-Path $ProjectRoot 'README.md') -Value '# Test project' -Encoding UTF8
    Invoke-Git -Arguments @('-C', $ProjectRoot, 'add', 'README.md')
    Invoke-Git -Arguments @('-C', $ProjectRoot, 'commit', '-m', 'test: initialize repository')
    Invoke-Git -Arguments @('-C', $ProjectRoot, 'remote', 'add', 'origin', $RemoteRoot)
    Invoke-Git -Arguments @('-C', $ProjectRoot, 'push', '-u', 'origin', 'main')

    Invoke-WindowsPowerShell -Arguments @('-File', $BootstrapScript, '-ProjectRoot', $ProjectRoot)

    $GeneratedAgents = Join-Path $ProjectRoot 'AGENTS.md'
    $GeneratedBootstrap = Join-Path $ProjectRoot 'scripts\agent-bootstrap.ps1'
    if (-not (Test-Path -LiteralPath $GeneratedAgents -PathType Leaf)) {
        throw 'Bootstrap did not generate AGENTS.md.'
    }
    if (-not (Test-Path -LiteralPath $GeneratedBootstrap -PathType Leaf)) {
        throw 'Bootstrap did not generate scripts\agent-bootstrap.ps1.'
    }
    if ((Get-Content -LiteralPath $GeneratedAgents -Raw -Encoding UTF8).Contains('yes长官')) {
        throw 'Generated AGENTS.md contains a personal response rule.'
    }

    $PreviousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & powershell -NoProfile -ExecutionPolicy Bypass -File $StartTaskScript `
        -ProjectRoot $ProjectRoot `
        -TaskName 'invalid-ignore' `
        -BranchName 'bad..branch' `
        -EnsureIgnore 2>$null | Out-Null
    $InvalidBranchExit = $LASTEXITCODE
    $ErrorActionPreference = $PreviousErrorActionPreference
    if ($InvalidBranchExit -eq 0) {
        throw 'Expected invalid branch name to be rejected.'
    }
    if (Test-Path -LiteralPath (Join-Path $ProjectRoot '.gitignore')) {
        throw 'Failed task setup must not create .gitignore.'
    }

    $PreviousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & powershell -NoProfile -ExecutionPolicy Bypass -File $StartTaskScript `
        -ProjectRoot $ProjectRoot `
        -TaskName 'escaped-ignore' `
        -BranchName 'codex/escaped-ignore' `
        -WorktreeDir '..\escaped-worktrees' `
        -NoFetch `
        -EnsureIgnore 2>$null | Out-Null
    $EscapedPathExit = $LASTEXITCODE
    $ErrorActionPreference = $PreviousErrorActionPreference
    if ($EscapedPathExit -eq 0) {
        throw 'Expected escaped ensure-ignore path to be rejected.'
    }
    if (Test-Path -LiteralPath (Join-Path $ProjectRoot '.gitignore')) {
        throw 'Escaped task setup must not create .gitignore.'
    }

    Push-Location $ProjectRoot
    try {
        Invoke-WindowsPowerShell -Arguments @('-File', $GeneratedBootstrap, '-SkipVerify')
    } finally {
        Pop-Location
    }
    Invoke-WindowsPowerShell -Arguments @(
        '-File', $StartTaskScript,
        '-ProjectRoot', $ProjectRoot,
        '-TaskName', 'bundled-skill-smoke',
        '-BranchName', 'codex/bundled-skill-smoke',
        '-WorktreeDir', $WorktreeRoot
    )

    $CreatedWorktree = Join-Path $WorktreeRoot 'bundled-skill-smoke'
    $CreatedBranch = (& git -C $CreatedWorktree branch --show-current).Trim()
    if ($LASTEXITCODE -ne 0 -or $CreatedBranch -ne 'codex/bundled-skill-smoke') {
        throw "Unexpected created branch: $CreatedBranch"
    }

    Write-Host 'PowerShell bundled skill smoke tests passed.'
} finally {
    if (Test-Path -LiteralPath $TestRoot) {
        Remove-Item -LiteralPath $TestRoot -Recurse -Force
    }
}
