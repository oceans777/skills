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
  [switch] $AllExistingRuntimes,
  [switch] $DryRun,
  [string] $UpstreamUrl,
  [string] $UpstreamAuthor,
  [string] $UpstreamLicense,
  [string] $LicenseFile,
  [string] $PatchSummary,
  [string] $Url,
  [string] $SkillPath,
  [ValidateSet("list", "activate", "deprecate", "archive", "block", "restore")] [string] $Action = "list",
  [string] $Reason,
  [string] $Replacement,
  [switch] $Activate,
  [string] $LocalRepository,
  [string] $CatalogRoot
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

switch ($Command) {
  "sync" { & "$RepoRoot\scripts\sync.ps1" }
  "install" {
    $InstallArgs = @{}
    if ($Runtime) { $InstallArgs.Runtime = $Runtime }
    if ($AllExistingRuntimes) { $InstallArgs.AllExistingRuntimes = $true }
    if ($CatalogRoot) { $InstallArgs.CatalogRoot = $CatalogRoot }
    & "$RepoRoot\scripts\install-skills.ps1" @InstallArgs
  }
  "validate" {
    $ValidateArgs = @{}
    if ($CatalogRoot) { $ValidateArgs.CatalogRoot = $CatalogRoot }
    & "$RepoRoot\scripts\validate-skills.ps1" @ValidateArgs
  }
  "test" { & "$RepoRoot\scripts\test.ps1" }
  "status" {
    $StatusArgs = @{}
    if ($Runtime) { $StatusArgs.Runtime = $Runtime }
    if ($AllExistingRuntimes) { $StatusArgs.AllExistingRuntimes = $true }
    & "$RepoRoot\scripts\status.ps1" @StatusArgs
  }
  "import" {
    $ImportArgs = @{}
    if ($SourceRoot) { $ImportArgs.SourceRoot = $SourceRoot }
    if ($Runtime) { $ImportArgs.Runtime = $Runtime }
    if ($Format) { $ImportArgs.Format = $Format }
    & "$RepoRoot\scripts\import-skills.ps1" @ImportArgs
  }
  "stage" {
    $StageArgs = @{}
    if ($SourceRoot) { $StageArgs.SourceRoot = $SourceRoot }
    if ($Runtime) { $StageArgs.Runtime = $Runtime }
    if ($Skill) { $StageArgs.Skill = $Skill }
    if ($Target) { $StageArgs.Target = $Target }
    if ($AllowRisk) { $StageArgs.AllowRisk = $true }
    if ($ReplaceExisting) { $StageArgs.ReplaceExisting = $true }
    if ($DryRun) { $StageArgs.DryRun = $true }
    if ($UpstreamUrl) { $StageArgs.UpstreamUrl = $UpstreamUrl }
    if ($UpstreamAuthor) { $StageArgs.UpstreamAuthor = $UpstreamAuthor }
    if ($UpstreamLicense) { $StageArgs.UpstreamLicense = $UpstreamLicense }
    if ($LicenseFile) { $StageArgs.LicenseFile = $LicenseFile }
    if ($PatchSummary) { $StageArgs.PatchSummary = $PatchSummary }
    & "$RepoRoot\scripts\stage-skill.ps1" @StageArgs
  }
  "publish" {
    $PublishArgs = @{}
    if ($DryRun) { $PublishArgs.DryRun = $true }
    & "$RepoRoot\scripts\publish-with-catalog.ps1" @PublishArgs
  }
  "add" {
    if (-not $Url) { throw "-Url is required for add." }
    $AddArgs = @{ Url = $Url }
    if ($SkillPath) { $AddArgs.SkillPath = $SkillPath }
    if ($Target) { $AddArgs.Target = $Target }
    if ($Activate) { $AddArgs.Activate = $true }
    if ($AllowRisk) { $AddArgs.AllowRisk = $true }
    if ($ReplaceExisting) { $AddArgs.ReplaceExisting = $true }
    if ($DryRun) { $AddArgs.DryRun = $true }
    if ($LocalRepository) { $AddArgs.LocalRepository = $LocalRepository }
    if ($CatalogRoot) { $AddArgs.CatalogRoot = $CatalogRoot }
    & "$RepoRoot\scripts\add-skill-from-url.ps1" @AddArgs
  }
  "catalog" {
    $CatalogArgs = @{ Action = $Action }
    if ($Skill) { $CatalogArgs.Skill = $Skill }
    if ($Reason) { $CatalogArgs.Reason = $Reason }
    if ($Replacement) { $CatalogArgs.Replacement = $Replacement }
    if ($CatalogRoot) { $CatalogArgs.CatalogRoot = $CatalogRoot }
    & "$RepoRoot\scripts\catalog-skill.ps1" @CatalogArgs
  }
  "help" {
    Write-Host "oceans777 skills commands:"
    Write-Host ""
    Write-Host "Daily user commands:"
    Write-Host "  .\oceans.ps1 sync      Pull updates and check out pinned child repositories"
    Write-Host "  .\oceans.ps1 install   Install active skills locally (default: codex)"
    Write-Host "  .\oceans.ps1 validate  Validate repositories, catalog, and skill structure"
    Write-Host "  .\oceans.ps1 test      Run the platform test suite"
    Write-Host "  .\oceans.ps1 status    Show repository and runtime skill root status"
    Write-Host "  .\oceans.ps1 import    Scan local runtime skills and print an import review report"
    Write-Host "  .\oceans.ps1 catalog   List or change skill lifecycle state"
    Write-Host ""
    Write-Host "Maintainer publishing commands:"
    Write-Host "  .\oceans.ps1 add       Intake one GitHub skill URL (pending review by default)"
    Write-Host "  .\oceans.ps1 stage     Stage one local skill into an oceans777 repository"
    Write-Host "  .\oceans.ps1 publish   Validate, commit, and push staged skill repository changes"
  }
}
