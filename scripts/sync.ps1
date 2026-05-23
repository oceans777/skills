$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $RepoRoot

function Invoke-Git {
  & git @args
  if ($LASTEXITCODE -ne 0) {
    throw "git $($args -join ' ') failed with exit code $LASTEXITCODE."
  }
}

Invoke-Git pull --ff-only
Invoke-Git submodule sync --recursive
Invoke-Git submodule update --init --recursive
