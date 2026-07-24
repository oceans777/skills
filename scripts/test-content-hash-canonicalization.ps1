$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
. (Join-Path $RepoRoot "scripts\skill-content-hash.ps1")

$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("oceans-content-hash-test-" + [Guid]::NewGuid().ToString("N"))
try {
  $LfRoot = Join-Path $TestRoot "lf"
  $CrlfRoot = Join-Path $TestRoot "crlf"
  New-Item -ItemType Directory -Force -Path (Join-Path $LfRoot "nested"), (Join-Path $CrlfRoot "nested") | Out-Null

  $Utf8 = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllBytes((Join-Path $LfRoot "SKILL.md"), $Utf8.GetBytes("first`nsecond"))
  [System.IO.File]::WriteAllBytes((Join-Path $CrlfRoot "SKILL.md"), $Utf8.GetBytes("first`r`nsecond"))
  [System.IO.File]::WriteAllBytes((Join-Path $LfRoot "nested\reference.md"), $Utf8.GetBytes("alpha`nbeta`ngamma`n"))
  [System.IO.File]::WriteAllBytes((Join-Path $CrlfRoot "nested\reference.md"), $Utf8.GetBytes("alpha`rbeta`r`ngamma`r`n"))

  $LfHash = Get-OceansSkillContentSha256 -SkillPath $LfRoot
  $CrlfHash = Get-OceansSkillContentSha256 -SkillPath $CrlfRoot
  if ($LfHash -ne $CrlfHash) {
    throw "Canonical hashes differ: LF=$LfHash CRLF=$CrlfHash"
  }

  [System.IO.File]::WriteAllBytes((Join-Path $CrlfRoot "SKILL.md"), $Utf8.GetBytes("first`nchanged"))
  $ChangedHash = Get-OceansSkillContentSha256 -SkillPath $CrlfRoot
  if ($LfHash -eq $ChangedHash) {
    throw "Content mutation did not change the canonical hash."
  }

  Write-Host "Canonical content hash test passed: $LfHash"
} finally {
  if (Test-Path -LiteralPath $TestRoot) {
    Remove-Item -LiteralPath $TestRoot -Recurse -Force
  }
}
