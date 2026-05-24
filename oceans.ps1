param(
  [Parameter(Position = 0)]
  [ValidateSet("sync", "install", "validate", "status", "import", "stage", "publish", "help")]
  [string] $Command = "help",

  [string] $SourceRoot,
  [ValidateSet("codex", "agents", "claude", "openclaw", "hermes", "custom")] [string] $Runtime,
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
  [string] $PatchSummary
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

switch ($Command) {
  "sync" {
    & "$RepoRoot\scripts\sync.ps1"
  }
  "install" {
    $InstallArgs = @{}
    if ($Runtime) { $InstallArgs.Runtime = $Runtime }
    if ($AllExistingRuntimes) { $InstallArgs.AllExistingRuntimes = $true }
    & "$RepoRoot\scripts\install-skills.ps1" @InstallArgs
  }
  "validate" {
    & "$RepoRoot\scripts\validate-skills.ps1"
  }
  "status" {
    & "$RepoRoot\scripts\status.ps1"
  }
  "import" {
    $ImportArgs = @{}
    if ($SourceRoot) {
      $ImportArgs.SourceRoot = $SourceRoot
    }
    if ($Runtime) {
      $ImportArgs.Runtime = $Runtime
    }
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
    & "$RepoRoot\scripts\publish-skills.ps1" @PublishArgs
  }
  "help" {
    Write-Host "oceans777 skills commands:"
    Write-Host ""
    Write-Host "Daily user commands:"
    Write-Host "  .\oceans.ps1 sync      Pull updates and check out pinned child repositories"
    Write-Host "  .\oceans.ps1 install   Install skills locally"
    Write-Host "  .\oceans.ps1 validate  Validate repository and skill structure"
    Write-Host "  .\oceans.ps1 status    Show repository and install status"
    Write-Host "  .\oceans.ps1 import    Scan local skills and print an import review report"
    Write-Host ""
    Write-Host "Maintainer publishing commands:"
    Write-Host "  .\oceans.ps1 stage     Stage one local skill into an oceans777 repository"
    Write-Host "  .\oceans.ps1 publish   Validate, commit, and push staged skill repository changes"
  }
}
