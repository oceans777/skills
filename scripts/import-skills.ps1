param(
  [string] $SourceRoot,
  [ValidateSet("codex", "agents", "claude", "openclaw", "hermes", "custom")]
  [string] $Runtime,
  [string] $FirstPartySkillsRoot,
  [string] $CommunitySkillsRoot,

  [ValidateSet("text", "json")]
  [string] $Format = "text"
)

$ErrorActionPreference = "Stop"

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptRoot
$RequestedSourceRoot = $SourceRoot
$RequestedRuntime = $Runtime
. (Join-Path $ScriptRoot "skill-roots.ps1") -DefineOnly
. (Join-Path $ScriptRoot "skill-publish-rules.ps1")

if (-not $FirstPartySkillsRoot) {
  $FirstPartySkillsRoot = Join-Path $RepoRoot "repos\oceans-skills\skills"
}

if (-not $CommunitySkillsRoot) {
  $CommunitySkillsRoot = Join-Path $RepoRoot "repos\community-skills\skills"
}

$FirstPartyRoot = $FirstPartySkillsRoot
$CommunityRoot = $CommunitySkillsRoot

if ($RequestedSourceRoot) {
  $SourceRoots = @(Get-OceansRuntimeRoot -Runtime "custom" -Path $RequestedSourceRoot -Operation "scan")
} elseif ($RequestedRuntime) {
  $SourceRoots = @(Get-OceansRuntimeRoot -Runtime $RequestedRuntime -Operation "scan")
} else {
  $SourceRoots = @(Get-OceansExistingSkillRoots)
}

if ($SourceRoots.Count -eq 0) {
  throw "No local skill roots found. Create a supported runtime skills directory or pass SourceRoot."
}

function Get-RepositoryMatch {
  param([string] $SkillName)

  $Matches = New-Object System.Collections.Generic.List[string]

  if (Test-Path -LiteralPath (Join-Path $FirstPartyRoot $SkillName) -PathType Container) {
    $Matches.Add("oceans-skills")
  }

  if (Test-Path -LiteralPath (Join-Path $CommunityRoot $SkillName) -PathType Container) {
    $Matches.Add("community-skills")
  }

  if ($Matches.Count -eq 0) {
    return "none"
  }

  return ($Matches -join ", ")
}

function Get-ManagedSource {
  param([string] $SkillPath)

  $Marker = Join-Path $SkillPath ".oceans-skill-source"
  if (-not (Test-Path -LiteralPath $Marker -PathType Leaf)) {
    return $null
  }

  $Line = Get-Content -LiteralPath $Marker -ErrorAction SilentlyContinue |
    Where-Object { $_ -like "source_repository=*" } |
    Select-Object -First 1

  if ($Line) {
    return $Line.Substring("source_repository=".Length)
  }

  return "unknown"
}

function Get-ReportRiskNotes {
  param(
    [string] $SkillPath,
    [string] $ExpectedName
  )

  $Risks = New-Object System.Collections.Generic.List[string]
  foreach ($Issue in @(Get-OceansSkillMetadataIssues -SkillPath $SkillPath -ExpectedName $ExpectedName)) {
    if (-not $Risks.Contains($Issue)) {
      $Risks.Add($Issue)
    }
  }
  foreach ($Risk in @(Get-OceansSkillRiskNotes -SkillPath $SkillPath)) {
    if (-not $Risks.Contains($Risk)) {
      $Risks.Add($Risk)
    }
  }
  if ($Risks.Count -eq 0) {
    return @("risk: none detected")
  }

  return $Risks
}

function New-SkillReportItem {
  param(
    [System.IO.DirectoryInfo] $Directory,
    [string] $Runtime,
    [string] $SourceRoot,
    [string] $LocalRuntimeMatch
  )

  $Name = $Directory.Name
  $SkillPath = $Directory.FullName
  $SkillFile = Join-Path $SkillPath "SKILL.md"
  $RepositoryMatch = Get-RepositoryMatch -SkillName $Name
  $HasLocalRuntimeDuplicate = (($LocalRuntimeMatch -split ", " | Where-Object { $_ }).Count -gt 1)

  if ($Name -eq ".system") {
    return [ordered]@{
      Name = $Name
      Runtime = $Runtime
      SourceRoot = $SourceRoot
      SourcePath = $SkillPath
      Status = "skip-system"
      Destination = "do not publish"
      RepositoryMatch = $RepositoryMatch
      LocalRuntimeMatch = $LocalRuntimeMatch
      Action = "do not publish"
      Reason = "Codex system skills are not oceans777 source skills."
      Risks = @("risk: not scanned")
    }
  }

  $MetadataIssues = @(Get-OceansSkillMetadataIssues -SkillPath $SkillPath -ExpectedName $Name)
  $InvalidFolder = $MetadataIssues -contains "risk: invalid skill folder name"
  if ($InvalidFolder) {
    return [ordered]@{
      Name = $Name
      Runtime = $Runtime
      SourceRoot = $SourceRoot
      SourcePath = $SkillPath
      Status = "invalid-skill-name"
      Destination = "manual repair before import"
      RepositoryMatch = $RepositoryMatch
      LocalRuntimeMatch = $LocalRuntimeMatch
      Action = "repair folder name and SKILL.md frontmatter before deciding whether to publish"
      Reason = "A publishable skill must have a valid folder name, SKILL.md name, and description."
      Risks = @(Get-ReportRiskNotes -SkillPath $SkillPath -ExpectedName $Name)
    }
  }

  if (-not (Test-Path -LiteralPath $SkillFile -PathType Leaf)) {
    return [ordered]@{
      Name = $Name
      Runtime = $Runtime
      SourceRoot = $SourceRoot
      SourcePath = $SkillPath
      Status = "missing-skill-md"
      Destination = "manual repair before import"
      RepositoryMatch = $RepositoryMatch
      LocalRuntimeMatch = $LocalRuntimeMatch
      Action = "repair SKILL.md before deciding whether to publish"
      Reason = "A publishable skill must include SKILL.md."
      Risks = @(Get-ReportRiskNotes -SkillPath $SkillPath -ExpectedName $Name)
    }
  }

  if ($MetadataIssues.Count -gt 0) {
    return [ordered]@{
      Name = $Name
      Runtime = $Runtime
      SourceRoot = $SourceRoot
      SourcePath = $SkillPath
      Status = "invalid-skill-metadata"
      Destination = "manual repair before import"
      RepositoryMatch = $RepositoryMatch
      LocalRuntimeMatch = $LocalRuntimeMatch
      Action = "repair folder name and SKILL.md frontmatter before deciding whether to publish"
      Reason = "A publishable skill must have a valid folder name, SKILL.md name, and description."
      Risks = @(Get-ReportRiskNotes -SkillPath $SkillPath -ExpectedName $Name)
    }
  }

  $ManagedSource = Get-ManagedSource -SkillPath $SkillPath
  if ($ManagedSource -eq "oceans-skills") {
    return [ordered]@{
      Name = $Name
      Runtime = $Runtime
      SourceRoot = $SourceRoot
      SourcePath = $SkillPath
      Status = "already-managed"
      Destination = "repos/oceans-skills/skills/$Name"
      RepositoryMatch = $RepositoryMatch
      LocalRuntimeMatch = $LocalRuntimeMatch
      Action = "managed by oceans777; install may update it"
      Reason = "Local skill has an oceans777 first-party source marker."
      Risks = @(Get-ReportRiskNotes -SkillPath $SkillPath -ExpectedName $Name)
    }
  }

  if ($ManagedSource -eq "community-skills") {
    return [ordered]@{
      Name = $Name
      Runtime = $Runtime
      SourceRoot = $SourceRoot
      SourcePath = $SkillPath
      Status = "already-managed"
      Destination = "repos/community-skills/skills/$Name"
      RepositoryMatch = $RepositoryMatch
      LocalRuntimeMatch = $LocalRuntimeMatch
      Action = "managed by oceans777; install may update it"
      Reason = "Local skill has an oceans777 community source marker."
      Risks = @(Get-ReportRiskNotes -SkillPath $SkillPath -ExpectedName $Name)
    }
  }

  if ($HasLocalRuntimeDuplicate) {
    return [ordered]@{
      Name = $Name
      Runtime = $Runtime
      SourceRoot = $SourceRoot
      SourcePath = $SkillPath
      Status = "duplicate-local-runtime"
      Destination = "choose one local runtime source before staging"
      RepositoryMatch = $RepositoryMatch
      LocalRuntimeMatch = $LocalRuntimeMatch
      Action = "stage with an explicit runtime or source root after review"
      Reason = "The same local skill folder name exists in more than one runtime root."
      Risks = @(Get-ReportRiskNotes -SkillPath $SkillPath -ExpectedName $Name)
    }
  }

  if ($RepositoryMatch -ne "none") {
    return [ordered]@{
      Name = $Name
      Runtime = $Runtime
      SourceRoot = $SourceRoot
      SourcePath = $SkillPath
      Status = "duplicate-local-wins"
      Destination = "local skill stays installed"
      RepositoryMatch = $RepositoryMatch
      LocalRuntimeMatch = $LocalRuntimeMatch
      Action = "keep local skill; repository version will not overwrite it"
      Reason = "A repository skill has the same name, but this local skill has no oceans777 source marker."
      Risks = @(Get-ReportRiskNotes -SkillPath $SkillPath -ExpectedName $Name)
    }
  }

  return [ordered]@{
    Name = $Name
    Runtime = $Runtime
    SourceRoot = $SourceRoot
    SourcePath = $SkillPath
    Status = "review-source"
    Destination = "oceans-skills if you created it; community-skills if third-party; do not publish if private"
    RepositoryMatch = $RepositoryMatch
    LocalRuntimeMatch = $LocalRuntimeMatch
    Action = "review source before publishing"
    Reason = "No oceans777 source marker found."
    Risks = @(Get-ReportRiskNotes -SkillPath $SkillPath -ExpectedName $Name)
  }
}

$SkillRecords = foreach ($Root in $SourceRoots) {
  Get-ChildItem -LiteralPath $Root.Path -Directory -Force |
    ForEach-Object {
      [PSCustomObject]@{
        Directory = $_
        Name = $_.Name
        Runtime = $Root.Runtime
        SourceRoot = $Root.Path
      }
    }
}

$LocalRuntimeMatches = @{}
foreach ($Record in $SkillRecords) {
  if (-not $LocalRuntimeMatches.ContainsKey($Record.Name)) {
    $LocalRuntimeMatches[$Record.Name] = New-Object System.Collections.Generic.List[string]
  }
  if (-not $LocalRuntimeMatches[$Record.Name].Contains($Record.Runtime)) {
    $LocalRuntimeMatches[$Record.Name].Add($Record.Runtime)
  }
}

$Items = $SkillRecords |
  Sort-Object Name, Runtime, SourceRoot |
  ForEach-Object {
    $RuntimeMatch = (@($LocalRuntimeMatches[$_.Name]) | Sort-Object) -join ", "
    New-SkillReportItem -Directory $_.Directory -Runtime $_.Runtime -SourceRoot $_.SourceRoot -LocalRuntimeMatch $RuntimeMatch
  }

if ($Format -eq "json") {
  $Json = [ordered]@{
    source_roots = @($SourceRoots | ForEach-Object {
      [ordered]@{
        runtime = $_.Runtime
        path = $_.Path
      }
    })
    first_party_target = $FirstPartyRoot
    community_target = $CommunityRoot
    mode = "report only"
    copied_files = 0
    items = @($Items | ForEach-Object {
      [ordered]@{
        name = $_.Name
        runtime = $_.Runtime
        source_root = $_.SourceRoot
        source_path = $_.SourcePath
        status = $_.Status
        destination = $_.Destination
        repository_match = $_.RepositoryMatch
        local_runtime_match = $_.LocalRuntimeMatch
        action = $_.Action
        reason = $_.Reason
        risks = @($_.Risks)
      }
    })
  }
  $Json | ConvertTo-Json -Depth 8 -Compress
  exit 0
}

Write-Host "oceans777 local skill import report"
Write-Host "Source roots:"
foreach ($Root in $SourceRoots) {
  Write-Host "  $($Root.Runtime): $($Root.Path)"
}
Write-Host "First-party target: $FirstPartyRoot"
Write-Host "Community target: $CommunityRoot"
Write-Host "Mode: report only"
Write-Host "No files were copied."
Write-Host ""

if ($Items.Count -eq 0) {
  Write-Host "No local skill directories found."
  exit 0
}

foreach ($Item in $Items) {
  Write-Host "- $($Item.Name)"
  Write-Host "  runtime: $($Item.Runtime)"
  Write-Host "  source_root: $($Item.SourceRoot)"
  Write-Host "  source_path: $($Item.SourcePath)"
  Write-Host "  status: $($Item.Status)"
  Write-Host "  destination: $($Item.Destination)"
  Write-Host "  repository_match: $($Item.RepositoryMatch)"
  Write-Host "  local_runtime_match: $($Item.LocalRuntimeMatch)"
  Write-Host "  action: $($Item.Action)"
  Write-Host "  reason: $($Item.Reason)"
  foreach ($Risk in $Item.Risks) {
    Write-Host "  $Risk"
  }
}
