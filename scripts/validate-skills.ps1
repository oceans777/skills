param(
  [string] $FirstPartySkillsRoot,
  [string] $CommunitySkillsRoot,
  [string] $CatalogRoot,
  [switch] $WithoutCatalog
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptRoot "skill-publish-rules.ps1")
. (Join-Path $ScriptRoot "skill-catalog.ps1")
$Failures = New-Object System.Collections.Generic.List[string]
$CustomSourceRoots = $PSBoundParameters.ContainsKey("FirstPartySkillsRoot") -or $PSBoundParameters.ContainsKey("CommunitySkillsRoot")
$CatalogExplicit = $PSBoundParameters.ContainsKey("CatalogRoot")

if (-not $FirstPartySkillsRoot) { $FirstPartySkillsRoot = Join-Path $RepoRoot "repos\oceans-skills\skills" }
if (-not $CommunitySkillsRoot) { $CommunitySkillsRoot = Join-Path $RepoRoot "repos\community-skills\skills" }
if (-not $CatalogRoot) { $CatalogRoot = Join-Path $RepoRoot "catalog" }
if ($CustomSourceRoots -and -not $CatalogExplicit -and -not $WithoutCatalog) {
  throw "Custom skill roots require -CatalogRoot. Use -WithoutCatalog only for an intentional legacy fixture."
}
if ($WithoutCatalog -and $CatalogExplicit) { throw "-WithoutCatalog cannot be combined with -CatalogRoot." }

function Test-SkillPath {
  param(
    [Parameter(Mandatory = $true)][string] $RepositoryName,
    [Parameter(Mandatory = $true)][string] $SkillName,
    [Parameter(Mandatory = $true)][string] $SkillPath,
    [Parameter(Mandatory = $true)][bool] $RequireUpstream
  )
  if (-not (Test-Path -LiteralPath $SkillPath -PathType Container)) {
    $Failures.Add("Missing skill path in ${RepositoryName}: $SkillName")
    return
  }
  foreach ($Issue in @(Get-OceansSkillMetadataIssues -SkillPath $SkillPath -ExpectedName $SkillName)) {
    $Failures.Add("Invalid skill metadata in ${RepositoryName}: ${SkillName}: $Issue")
  }
  $SkillItem = Get-Item -LiteralPath $SkillPath -Force
  $IsReparsePoint = (($SkillItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
  if ($IsReparsePoint) { $Failures.Add("Unsupported symlink in ${RepositoryName}: $SkillName") }
  if (-not $IsReparsePoint) {
    Get-OceansSkillItemsNoFollow -SkillPath $SkillPath |
      Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 } |
      ForEach-Object { $Failures.Add("Unsupported symlink in ${RepositoryName}: ${SkillName}: $($_.FullName)") }
  }
  if (-not (Test-Path -LiteralPath (Join-Path $SkillPath "SKILL.md") -PathType Leaf)) {
    $Failures.Add("Missing SKILL.md in ${RepositoryName}: $SkillName")
  } elseif (Test-OceansMissingLicenseReference -SkillPath $SkillPath) {
    $Failures.Add("Missing referenced license file in ${RepositoryName}: $SkillName")
  }
  foreach ($Risk in @(Get-OceansSkillRiskNotes -SkillPath $SkillPath)) {
    if ($Risk -ne "risk: missing referenced license file") { $Failures.Add("Unsafe skill content in ${RepositoryName}: ${SkillName}: $Risk") }
  }
  if ($RequireUpstream) {
    foreach ($Required in @("UPSTREAM.md", "PATCHES.md", "LICENSE")) {
      $RequiredPath = Join-Path $SkillPath $Required
      $RequiredContent = ""
      if (Test-Path -LiteralPath $RequiredPath -PathType Leaf) { $RequiredContent = [string](Get-Content -LiteralPath $RequiredPath -Raw) }
      if (-not (Test-Path -LiteralPath $RequiredPath -PathType Leaf) -or $RequiredContent.Trim().Length -eq 0) {
        $Failures.Add("Missing or empty $Required in ${RepositoryName}: $SkillName")
      }
    }
  }
}

function Test-SkillDirectory {
  param([string] $RepositoryName, [string] $SkillsPath, [bool] $RequireUpstream)
  if (-not (Test-Path -LiteralPath $SkillsPath -PathType Container)) {
    $Failures.Add("Missing skills path: $SkillsPath")
    return
  }
  foreach ($SkillDirectory in @(Get-ChildItem -LiteralPath $SkillsPath -Directory)) {
    Test-SkillPath -RepositoryName $RepositoryName -SkillName $SkillDirectory.Name -SkillPath $SkillDirectory.FullName -RequireUpstream $RequireUpstream
  }
}

Test-SkillDirectory -RepositoryName "oceans-skills" -SkillsPath $FirstPartySkillsRoot -RequireUpstream $false
Test-SkillDirectory -RepositoryName "community-skills" -SkillsPath $CommunitySkillsRoot -RequireUpstream $true

$FirstPartyNames = if (Test-Path -LiteralPath $FirstPartySkillsRoot -PathType Container) { @(Get-ChildItem -LiteralPath $FirstPartySkillsRoot -Directory | ForEach-Object { $_.Name }) } else { @() }
$CommunityNames = if (Test-Path -LiteralPath $CommunitySkillsRoot -PathType Container) { @(Get-ChildItem -LiteralPath $CommunitySkillsRoot -Directory | ForEach-Object { $_.Name }) } else { @() }
foreach ($Name in $FirstPartyNames) {
  if ($CommunityNames -contains $Name) { $Failures.Add("Duplicate skill name across repositories: $Name") }
}

if (-not $WithoutCatalog) {
  foreach ($Issue in @(Get-OceansCatalogValidationIssues -CatalogRoot $CatalogRoot -FirstPartySkillsRoot $FirstPartySkillsRoot -CommunitySkillsRoot $CommunitySkillsRoot)) {
    $Failures.Add($Issue)
  }
  $CatalogSkills = Join-Path $CatalogRoot "skills"
  if (Test-Path -LiteralPath $CatalogSkills -PathType Container) {
    foreach ($RecordFile in @(Get-ChildItem -LiteralPath $CatalogSkills -Filter '*.skill' -File)) {
      $Record = Get-OceansCatalogRecord -Path $RecordFile.FullName
      if ([string]::IsNullOrWhiteSpace([string]$Record["candidate_upstream_commit"])) { continue }
      $SkillName = [System.IO.Path]::GetFileNameWithoutExtension($RecordFile.Name)
      $PackageRepository = [string]$Record["package_repository"]
      $CandidatePath = Get-OceansCatalogReviewPath -CatalogRoot $CatalogRoot -PackageRepository $PackageRepository -SkillName $SkillName
      Test-SkillPath `
        -RepositoryName "review-queue/$PackageRepository" `
        -SkillName $SkillName `
        -SkillPath $CandidatePath `
        -RequireUpstream ($PackageRepository -eq "community-skills")
    }
  }
} else {
  Write-Warning "Catalog validation explicitly disabled."
}

if ($Failures.Count -gt 0) {
  $Failures | ForEach-Object { Write-Output "ERROR: $_" }
  throw "Validation failed with $($Failures.Count) issue(s)."
}

Write-Host "Validation passed."
