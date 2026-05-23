param(
  [string] $SourceRoot,

  [ValidateSet("text")]
  [string] $Format = "text"
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

if (-not $SourceRoot) {
  if ($env:CODEX_HOME) {
    $SourceRoot = Join-Path $env:CODEX_HOME "skills"
  } else {
    $SourceRoot = Join-Path $HOME ".codex\skills"
  }
}

if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
  throw "Local skills root does not exist: $SourceRoot"
}

$ResolvedSourceRoot = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $SourceRoot).Path)
$FirstPartyRoot = Join-Path $RepoRoot "repos\oceans-skills\skills"
$CommunityRoot = Join-Path $RepoRoot "repos\community-skills\skills"

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

function Get-RiskNotes {
  param([string] $SkillPath)

  $Risks = New-Object System.Collections.Generic.List[string]
  $Files = Get-ChildItem -LiteralPath $SkillPath -File -Recurse -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }

  $SecretPattern = '(?i)(api[_-]?key\s*[:=]|secret\s*[:=]|token\s*[:=]|password\s*[:=]|authorization:\s*bearer|sk-[a-zA-Z0-9_-]{10,})'
  $LocalPathPattern = '(?i)(/Users/|/home/|[A-Z]:\\Users\\|[A-Z]:/Users/|/private/)'

  foreach ($File in $Files) {
    $Content = $null
    try {
      $Content = Get-Content -LiteralPath $File.FullName -Raw -ErrorAction Stop
    } catch {
      continue
    }

    if ($Content -match $SecretPattern -and -not $Risks.Contains("risk: secret-like text")) {
      $Risks.Add("risk: secret-like text")
    }

    if ($Content -match $LocalPathPattern -and -not $Risks.Contains("risk: local absolute path")) {
      $Risks.Add("risk: local absolute path")
    }
  }

  if ($Risks.Count -eq 0) {
    $Risks.Add("risk: none detected")
  }

  return $Risks
}

function New-SkillReportItem {
  param([System.IO.DirectoryInfo] $Directory)

  $Name = $Directory.Name
  $SkillPath = $Directory.FullName
  $SkillFile = Join-Path $SkillPath "SKILL.md"
  $RepositoryMatch = Get-RepositoryMatch -SkillName $Name

  if ($Name -eq ".system") {
    return [ordered]@{
      Name = $Name
      Status = "skip-system"
      Destination = "do not publish"
      RepositoryMatch = $RepositoryMatch
      Action = "do not publish"
      Reason = "Codex system skills are not oceans777 source skills."
      Risks = @("risk: not scanned")
    }
  }

  if (-not (Test-Path -LiteralPath $SkillFile -PathType Leaf)) {
    return [ordered]@{
      Name = $Name
      Status = "missing-skill-md"
      Destination = "manual repair before import"
      RepositoryMatch = $RepositoryMatch
      Action = "repair SKILL.md before deciding whether to publish"
      Reason = "A publishable skill must include SKILL.md."
      Risks = @(Get-RiskNotes -SkillPath $SkillPath)
    }
  }

  $ManagedSource = Get-ManagedSource -SkillPath $SkillPath
  if ($ManagedSource -eq "oceans-skills") {
    return [ordered]@{
      Name = $Name
      Status = "already-managed"
      Destination = "repos/oceans-skills/skills/$Name"
      RepositoryMatch = $RepositoryMatch
      Action = "managed by oceans777; install may update it"
      Reason = "Local skill has an oceans777 first-party source marker."
      Risks = @(Get-RiskNotes -SkillPath $SkillPath)
    }
  }

  if ($ManagedSource -eq "community-skills") {
    return [ordered]@{
      Name = $Name
      Status = "already-managed"
      Destination = "repos/community-skills/skills/$Name"
      RepositoryMatch = $RepositoryMatch
      Action = "managed by oceans777; install may update it"
      Reason = "Local skill has an oceans777 community source marker."
      Risks = @(Get-RiskNotes -SkillPath $SkillPath)
    }
  }

  if ($RepositoryMatch -ne "none") {
    return [ordered]@{
      Name = $Name
      Status = "duplicate-local-wins"
      Destination = "local skill stays installed"
      RepositoryMatch = $RepositoryMatch
      Action = "keep local skill; repository version will not overwrite it"
      Reason = "A repository skill has the same name, but this local skill has no oceans777 source marker."
      Risks = @(Get-RiskNotes -SkillPath $SkillPath)
    }
  }

  return [ordered]@{
    Name = $Name
    Status = "review-source"
    Destination = "oceans-skills if you created it; community-skills if third-party; do not publish if private"
    RepositoryMatch = $RepositoryMatch
    Action = "review source before publishing"
    Reason = "No oceans777 source marker found."
    Risks = @(Get-RiskNotes -SkillPath $SkillPath)
  }
}

$Items = Get-ChildItem -LiteralPath $ResolvedSourceRoot -Directory -Force |
  Sort-Object Name |
  ForEach-Object { New-SkillReportItem -Directory $_ }

Write-Host "oceans777 local skill import report"
Write-Host "Source root: $ResolvedSourceRoot"
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
  Write-Host "  status: $($Item.Status)"
  Write-Host "  destination: $($Item.Destination)"
  Write-Host "  repository_match: $($Item.RepositoryMatch)"
  Write-Host "  action: $($Item.Action)"
  Write-Host "  reason: $($Item.Reason)"
  foreach ($Risk in $Item.Risks) {
    Write-Host "  $Risk"
  }
}
