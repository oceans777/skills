param(
  [Parameter(Position = 0)]
  [ValidateSet("list", "activate", "deprecate", "archive", "block", "restore")]
  [string] $Action = "list",
  [string] $Skill,
  [string] $Reason,
  [string] $Replacement,
  [string] $CatalogRoot
)

$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptRoot
. (Join-Path $ScriptRoot "skill-catalog.ps1")

if (-not $CatalogRoot) { $CatalogRoot = Join-Path $RepoRoot "catalog" }

if ($Action -eq "list") {
  Write-Output "state|repository|name|replacement|reason"
  foreach ($State in $script:OceansCatalogStates) {
    $StateDirectory = Join-Path $CatalogRoot $State
    if (-not (Test-Path -LiteralPath $StateDirectory -PathType Container)) { continue }
    foreach ($RecordFile in @(Get-ChildItem -LiteralPath $StateDirectory -Filter '*.skill' -File | Sort-Object Name)) {
      $Record = Get-OceansCatalogRecord -Path $RecordFile.FullName
      Write-Output "$State|$([string]$Record['repository'])|$([string]$Record['name'])|$([string]$Record['replacement'])|$([string]$Record['reason'])"
    }
  }
  exit 0
}

if (-not $Skill) { throw "-Skill is required." }
$TargetState = switch ($Action) {
  "activate" { "active" }
  "restore" { "active" }
  "deprecate" { "deprecated" }
  "archive" { "archived" }
  "block" { "blocked" }
}
if (@("deprecate", "archive", "block") -contains $Action -and [string]::IsNullOrWhiteSpace($Reason)) {
  throw "-Reason is required for $Action."
}

Move-OceansCatalogRecord `
  -CatalogRoot $CatalogRoot `
  -SkillName $Skill `
  -TargetState $TargetState `
  -Replacement ([string]$Replacement) `
  -Reason ([string]$Reason) | Out-Null

Write-Host "catalog-state: $TargetState"
Write-Host "skill: $Skill"
