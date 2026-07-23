param(
  [Parameter(Position = 0)]
  [ValidateSet("sync", "install", "validate", "test", "status", "import", "stage", "publish", "add", "catalog", "help")]
  [string] $Command = "help",

  [string] $SourceRoot,
  [ValidateSet("codex", "agents", "claude", "openclaw", "hermes", "custom")] [string] $Runtime,
  [ValidateSet("text", "json")] [string] $Format,
  [string] $Skill,
  [ValidateSet("oceans", "community")] [string] $Target,
  [switch] $AllowRisk,
  [switch] $ReplaceExisting,
  [switch] $AllowSourceChange,
  [switch] $AllExistingRuntimes,
  [switch] $DryRun,
  [switch] $WithoutCatalog,
  [string] $UpstreamUrl,
  [string] $UpstreamAuthor,
  [string] $UpstreamLicense,
  [string] $LicenseFile,
  [string] $PatchSummary,
  [string] $Url,
  [string] $SkillPath,
  [string] $SourceRef,
  [ValidateSet("list", "activate", "reject", "cancel-review", "restore", "unblock", "deprecate", "archive", "block")] [string] $Action = "list",
  [string] $Reason,
  [string] $Replacement,
  [string] $LocalRepository,
  [string] $CatalogRoot,
  [string] $FirstPartySkillsRoot,
  [string] $CommunitySkillsRoot
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

switch ($Command) {
  "sync" { & "$RepoRoot\scripts\sync.ps1" }
  "install" {
    $Args = @{}
    if ($Runtime) { $Args.Runtime = $Runtime }
    if ($AllExistingRuntimes) { $Args.AllExistingRuntimes = $true }
    if ($CatalogRoot) { $Args.CatalogRoot = $CatalogRoot }
    if ($FirstPartySkillsRoot) { $Args.FirstPartySkillsRoot = $FirstPartySkillsRoot }
    if ($CommunitySkillsRoot) { $Args.CommunitySkillsRoot = $CommunitySkillsRoot }
    if ($WithoutCatalog) { $Args.WithoutCatalog = $true }
    & "$RepoRoot\scripts\install-skills.ps1" @Args
  }
  "validate" {
    $Args = @{}
    if ($CatalogRoot) { $Args.CatalogRoot = $CatalogRoot }
    if ($FirstPartySkillsRoot) { $Args.FirstPartySkillsRoot = $FirstPartySkillsRoot }
    if ($CommunitySkillsRoot) { $Args.CommunitySkillsRoot = $CommunitySkillsRoot }
    if ($WithoutCatalog) { $Args.WithoutCatalog = $true }
    & "$RepoRoot\scripts\validate-skills.ps1" @Args
  }
  "test" { & "$RepoRoot\scripts\test.ps1" }
  "status" {
    $Args = @{}
    if ($Runtime) { $Args.Runtime = $Runtime }
    if ($AllExistingRuntimes) { $Args.AllExistingRuntimes = $true }
    & "$RepoRoot\scripts\status.ps1" @Args
  }
  "import" {
    $Args = @{}
    if ($SourceRoot) { $Args.SourceRoot = $SourceRoot }
    if ($Runtime) { $Args.Runtime = $Runtime }
    if ($Format) { $Args.Format = $Format }
    & "$RepoRoot\scripts\import-skills.ps1" @Args
  }
  "stage" {
    $Args = @{}
    if ($SourceRoot) { $Args.SourceRoot = $SourceRoot }
    if ($Runtime) { $Args.Runtime = $Runtime }
    if ($Skill) { $Args.Skill = $Skill }
    if ($Target) { $Args.Target = $Target }
    if ($AllowRisk) { $Args.AllowRisk = $true }
    if ($ReplaceExisting) { $Args.ReplaceExisting = $true }
    if ($DryRun) { $Args.DryRun = $true }
    if ($UpstreamUrl) { $Args.UpstreamUrl = $UpstreamUrl }
    if ($UpstreamAuthor) { $Args.UpstreamAuthor = $UpstreamAuthor }
    if ($UpstreamLicense) { $Args.UpstreamLicense = $UpstreamLicense }
    if ($LicenseFile) { $Args.LicenseFile = $LicenseFile }
    if ($PatchSummary) { $Args.PatchSummary = $PatchSummary }
    & "$RepoRoot\scripts\stage-skill.ps1" @Args
  }
  "publish" {
    $Args = @{}
    if ($DryRun) { $Args.DryRun = $true }
    & "$RepoRoot\scripts\publish-skills.ps1" @Args
  }
  "add" {
    if (-not $Url) { throw "-Url is required for add." }
    $Args = @{ Url = $Url }
    if ($SkillPath) { $Args.SkillPath = $SkillPath }
    if ($SourceRef) { $Args.SourceRef = $SourceRef }
    if ($Target) { $Args.Target = $Target }
    if ($AllowRisk) { $Args.AllowRisk = $true }
    if ($ReplaceExisting) { $Args.ReplaceExisting = $true }
    if ($AllowSourceChange) { $Args.AllowSourceChange = $true }
    if ($DryRun) { $Args.DryRun = $true }
    if ($LocalRepository) { $Args.LocalRepository = $LocalRepository }
    if ($CatalogRoot) { $Args.CatalogRoot = $CatalogRoot }
    & "$RepoRoot\scripts\add-skill-from-url.ps1" @Args
  }
  "catalog" {
    $Args = @{ Action = $Action }
    if ($Skill) { $Args.Skill = $Skill }
    if ($Reason) { $Args.Reason = $Reason }
    if ($Replacement) { $Args.Replacement = $Replacement }
    if ($CatalogRoot) { $Args.CatalogRoot = $CatalogRoot }
    if ($FirstPartySkillsRoot) { $Args.FirstPartySkillsRoot = $FirstPartySkillsRoot }
    if ($CommunitySkillsRoot) { $Args.CommunitySkillsRoot = $CommunitySkillsRoot }
    & "$RepoRoot\scripts\catalog-skill.ps1" @Args
  }
  "help" {
    Write-Host "oceans777 skills commands:"
    Write-Host ""
    Write-Host "Daily user commands:"
    Write-Host "  .\oceans.ps1 sync      Pull updates and check out pinned child repositories"
    Write-Host "  .\oceans.ps1 install   Reconcile lifecycle state and install active skills"
    Write-Host "  .\oceans.ps1 validate  Validate repositories, catalog, and review candidates"
    Write-Host "  .\oceans.ps1 test      Run the platform test suite"
    Write-Host "  .\oceans.ps1 status    Show repository and runtime skill root status"
    Write-Host "  .\oceans.ps1 import    Scan local runtime skills and print an import review report"
    Write-Host "  .\oceans.ps1 catalog   List, approve, reject, or change lifecycle state"
    Write-Host ""
    Write-Host "Maintainer publishing commands:"
    Write-Host "  .\oceans.ps1 add       Queue one GitHub skill URL for isolated review"
    Write-Host "  .\oceans.ps1 stage     Stage one trusted local skill into an oceans777 repository"
    Write-Host "  .\oceans.ps1 publish   Publish child commits, catalog, and submodule pointers coherently"
  }
}
