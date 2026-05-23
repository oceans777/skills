$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $RepoRoot
. "$RepoRoot\scripts\common.ps1"

Invoke-GitWithRetry -Description "Pull entry repository" -Arguments @("pull", "--ff-only") -Attempts 3 -DelaySeconds 5
Invoke-Git -Description "Sync child repository URLs" -Arguments @("submodule", "sync", "--recursive")
Invoke-GitWithRetry -Description "Update child repositories" -Arguments @("submodule", "update", "--init", "--recursive") -Attempts 3 -DelaySeconds 5
