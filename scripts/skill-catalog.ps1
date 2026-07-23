$script:OceansCatalogSchemaVersion = "2"
$script:OceansCatalogStates = @("active", "pending-review", "deprecated", "archived", "blocked")
$script:OceansCatalogKeys = @(
  "schema_version", "name", "status", "package_repository",
  "upstream_repository", "upstream_path", "upstream_ref", "upstream_commit",
  "candidate_upstream_repository", "candidate_upstream_path", "candidate_upstream_ref", "candidate_upstream_commit",
  "replacement", "status_reason", "transition_note", "updated_at"
)
$script:OceansCatalogLockPath = $null

function Test-OceansCatalogSkillName {
  param([Parameter(Mandatory = $true)][string] $Name)
  return ($Name.Length -le 64 -and $Name -match '^[a-z0-9]+(-[a-z0-9]+)*$')
}

function Test-OceansCatalogState {
  param([Parameter(Mandatory = $true)][string] $State)
  return $script:OceansCatalogStates -contains $State
}

function Get-OceansCatalogRecordPath {
  param(
    [Parameter(Mandatory = $true)][string] $CatalogRoot,
    [Parameter(Mandatory = $true)][string] $SkillName
  )
  return (Join-Path (Join-Path $CatalogRoot "skills") "$SkillName.skill")
}

function Get-OceansCatalogReviewPath {
  param(
    [Parameter(Mandatory = $true)][string] $CatalogRoot,
    [Parameter(Mandatory = $true)][string] $PackageRepository,
    [Parameter(Mandatory = $true)][string] $SkillName
  )
  return (Join-Path (Join-Path (Join-Path $CatalogRoot "review-queue") $PackageRepository) $SkillName)
}

function Get-OceansCatalogRecord {
  param([Parameter(Mandatory = $true)][string] $Path)

  $Values = @{}
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $Values }
  foreach ($Line in @(Get-Content -LiteralPath $Path -Encoding UTF8)) {
    $Separator = $Line.IndexOf('=')
    if ($Separator -lt 1) { continue }
    $Key = $Line.Substring(0, $Separator)
    $Value = $Line.Substring($Separator + 1)
    if (-not $Values.ContainsKey($Key)) { $Values[$Key] = $Value }
  }
  return $Values
}

function Get-OceansCatalogStateForSkill {
  param(
    [Parameter(Mandatory = $true)][string] $CatalogRoot,
    [Parameter(Mandatory = $true)][string] $SkillName
  )
  $RecordPath = Get-OceansCatalogRecordPath -CatalogRoot $CatalogRoot -SkillName $SkillName
  if (-not (Test-Path -LiteralPath $RecordPath -PathType Leaf)) { return $null }
  $Record = Get-OceansCatalogRecord -Path $RecordPath
  $Status = [string]$Record["status"]
  if (-not (Test-OceansCatalogState -State $Status)) { throw "catalog-invalid-state: $SkillName" }
  return $Status
}

function Test-OceansCatalogRecordHasCandidate {
  param([Parameter(Mandatory = $true)][string] $RecordPath)
  $Record = Get-OceansCatalogRecord -Path $RecordPath
  return -not [string]::IsNullOrWhiteSpace([string]$Record["candidate_upstream_commit"])
}

function Assert-OceansCatalogSingleLineValue {
  param([AllowEmptyString()][string] $Value)
  if ($Value -match '[\x00-\x1F\x7F]') { throw "Catalog values must be single-line text." }
}

function Test-OceansCatalogRepositoryUrl {
  param([AllowEmptyString()][string] $Value)
  return $Value -match '^https://github\.com/[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$'
}

function Test-OceansCatalogUpstreamPath {
  param([AllowEmptyString()][string] $Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
  if ($Value -eq ".") { return $true }
  if ([System.IO.Path]::IsPathRooted($Value) -or $Value.Contains('\')) { return $false }
  return -not (($Value -split '/') -contains '..')
}

function Enter-OceansCatalogLock {
  param(
    [Parameter(Mandatory = $true)][string] $CatalogRoot,
    [Parameter(Mandatory = $true)][string] $SkillName
  )
  if (-not (Test-OceansCatalogSkillName -Name $SkillName)) { throw "Invalid catalog skill name: $SkillName" }
  $LockRoot = Join-Path $CatalogRoot ".locks"
  New-Item -ItemType Directory -Force -Path $LockRoot | Out-Null
  $LockPath = Join-Path $LockRoot "$SkillName.lock"
  try {
    New-Item -ItemType Directory -Path $LockPath -ErrorAction Stop | Out-Null
  } catch {
    if (Test-Path -LiteralPath $LockPath -PathType Container) {
      $Age = [DateTime]::UtcNow - (Get-Item -LiteralPath $LockPath).LastWriteTimeUtc
      if ($Age.TotalMinutes -gt 30) {
        Remove-Item -LiteralPath $LockPath -Recurse -Force
        New-Item -ItemType Directory -Path $LockPath -ErrorAction Stop | Out-Null
      } else {
        throw "Another catalog operation is active: $SkillName"
      }
    } else {
      throw "Refusing unsafe catalog lock: $LockPath"
    }
  }
  [System.IO.File]::WriteAllText((Join-Path $LockPath "pid"), [string]$PID, (New-Object System.Text.UTF8Encoding($false)))
  $script:OceansCatalogLockPath = $LockPath
}

function Exit-OceansCatalogLock {
  if ($script:OceansCatalogLockPath -and (Test-Path -LiteralPath $script:OceansCatalogLockPath -PathType Container)) {
    Remove-Item -LiteralPath $script:OceansCatalogLockPath -Recurse -Force
  }
  $script:OceansCatalogLockPath = $null
}

function Write-OceansCatalogRecord {
  param(
    [Parameter(Mandatory = $true)][string] $CatalogRoot,
    [Parameter(Mandatory = $true)][string] $SkillName,
    [Parameter(Mandatory = $true)][string] $Status,
    [Parameter(Mandatory = $true)][string] $PackageRepository,
    [AllowEmptyString()][string] $UpstreamRepository = "",
    [AllowEmptyString()][string] $UpstreamPath = "",
    [AllowEmptyString()][string] $UpstreamRef = "",
    [AllowEmptyString()][string] $UpstreamCommit = "",
    [AllowEmptyString()][string] $CandidateUpstreamRepository = "",
    [AllowEmptyString()][string] $CandidateUpstreamPath = "",
    [AllowEmptyString()][string] $CandidateUpstreamRef = "",
    [AllowEmptyString()][string] $CandidateUpstreamCommit = "",
    [AllowEmptyString()][string] $Replacement = "",
    [AllowEmptyString()][string] $StatusReason = "",
    [AllowEmptyString()][string] $TransitionNote = ""
  )

  if (-not (Test-OceansCatalogSkillName -Name $SkillName)) { throw "Invalid catalog skill name: $SkillName" }
  if (-not (Test-OceansCatalogState -State $Status)) { throw "Unsupported catalog state: $Status" }
  if (@("oceans-skills", "community-skills") -notcontains $PackageRepository) {
    throw "Unsupported package repository: $PackageRepository"
  }
  foreach ($Value in @(
      $SkillName, $Status, $PackageRepository, $UpstreamRepository, $UpstreamPath, $UpstreamRef, $UpstreamCommit,
      $CandidateUpstreamRepository, $CandidateUpstreamPath, $CandidateUpstreamRef, $CandidateUpstreamCommit,
      $Replacement, $StatusReason, $TransitionNote
    )) {
    Assert-OceansCatalogSingleLineValue -Value $Value
  }

  $SkillsDirectory = Join-Path $CatalogRoot "skills"
  New-Item -ItemType Directory -Force -Path $SkillsDirectory | Out-Null
  $RecordPath = Get-OceansCatalogRecordPath -CatalogRoot $CatalogRoot -SkillName $SkillName
  $StagingPath = Join-Path $SkillsDirectory ".$SkillName.skill.$([Guid]::NewGuid().ToString('N'))"
  $Lines = @(
    "schema_version=$($script:OceansCatalogSchemaVersion)",
    "name=$SkillName",
    "status=$Status",
    "package_repository=$PackageRepository",
    "upstream_repository=$UpstreamRepository",
    "upstream_path=$UpstreamPath",
    "upstream_ref=$UpstreamRef",
    "upstream_commit=$UpstreamCommit",
    "candidate_upstream_repository=$CandidateUpstreamRepository",
    "candidate_upstream_path=$CandidateUpstreamPath",
    "candidate_upstream_ref=$CandidateUpstreamRef",
    "candidate_upstream_commit=$CandidateUpstreamCommit",
    "replacement=$Replacement",
    "status_reason=$StatusReason",
    "transition_note=$TransitionNote",
    "updated_at=$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
  )
  [System.IO.File]::WriteAllLines($StagingPath, $Lines, (New-Object System.Text.UTF8Encoding($false)))
  Move-Item -LiteralPath $StagingPath -Destination $RecordPath -Force
  return $RecordPath
}

function Get-OceansCatalogRecordSchemaIssues {
  param([Parameter(Mandatory = $true)][string] $RecordPath)
  $Issues = New-Object System.Collections.Generic.List[string]
  $Seen = @{}
  foreach ($Line in @(Get-Content -LiteralPath $RecordPath -Encoding UTF8)) {
    $Separator = $Line.IndexOf('=')
    if ($Separator -lt 1) {
      $Issues.Add("Malformed catalog line in $([System.IO.Path]::GetFileName($RecordPath))")
      continue
    }
    $Key = $Line.Substring(0, $Separator)
    if ($script:OceansCatalogKeys -notcontains $Key) {
      $Issues.Add("Unknown catalog key in $([System.IO.Path]::GetFileName($RecordPath)): $Key")
    }
    if ($Seen.ContainsKey($Key)) {
      $Issues.Add("Duplicate catalog key in $([System.IO.Path]::GetFileName($RecordPath)): $Key")
    } else {
      $Seen[$Key] = $true
    }
  }
  foreach ($RequiredKey in $script:OceansCatalogKeys) {
    if (-not $Seen.ContainsKey($RequiredKey)) {
      $Issues.Add("Missing catalog key in $([System.IO.Path]::GetFileName($RecordPath)): $RequiredKey")
    }
  }
  return $Issues
}

function Get-OceansCatalogValidationIssues {
  param(
    [Parameter(Mandatory = $true)][string] $CatalogRoot,
    [Parameter(Mandatory = $true)][string] $FirstPartySkillsRoot,
    [Parameter(Mandatory = $true)][string] $CommunitySkillsRoot
  )

  $Issues = New-Object System.Collections.Generic.List[string]
  if (-not (Test-Path -LiteralPath $CatalogRoot -PathType Container)) {
    $Issues.Add("Missing catalog root: $CatalogRoot")
    return $Issues
  }
  $SkillsDirectory = Join-Path $CatalogRoot "skills"
  $ReviewRoot = Join-Path $CatalogRoot "review-queue"
  if (-not (Test-Path -LiteralPath $SkillsDirectory -PathType Container)) { $Issues.Add("Missing catalog skills directory: $SkillsDirectory") }
  if (-not (Test-Path -LiteralPath $ReviewRoot -PathType Container)) { $Issues.Add("Missing catalog review queue: $ReviewRoot") }

  foreach ($LegacyState in $script:OceansCatalogStates) {
    $LegacyDirectory = Join-Path $CatalogRoot $LegacyState
    if (Test-Path -LiteralPath $LegacyDirectory -PathType Container) {
      if (@(Get-ChildItem -LiteralPath $LegacyDirectory -Filter '*.skill' -File -ErrorAction SilentlyContinue).Count -gt 0) {
        $Issues.Add("Legacy state-directory catalog records are not supported: $LegacyDirectory")
      }
    }
  }

  if (Test-Path -LiteralPath $SkillsDirectory -PathType Container) {
    foreach ($RecordFile in @(Get-ChildItem -LiteralPath $SkillsDirectory -Filter '*.skill' -File | Sort-Object Name)) {
      $SkillName = [System.IO.Path]::GetFileNameWithoutExtension($RecordFile.Name)
      foreach ($SchemaIssue in @(Get-OceansCatalogRecordSchemaIssues -RecordPath $RecordFile.FullName)) { $Issues.Add($SchemaIssue) }
      $Record = Get-OceansCatalogRecord -Path $RecordFile.FullName
      $Status = [string]$Record["status"]
      $PackageRepository = [string]$Record["package_repository"]
      if ([string]$Record["schema_version"] -ne $script:OceansCatalogSchemaVersion) { $Issues.Add("Unsupported catalog schema for ${SkillName}: $([string]$Record['schema_version'])") }
      if (-not (Test-OceansCatalogSkillName -Name $SkillName)) { $Issues.Add("Invalid catalog filename: $($RecordFile.Name)") }
      if ([string]$Record["name"] -cne $SkillName) { $Issues.Add("Catalog name mismatch: $SkillName") }
      if (-not (Test-OceansCatalogState -State $Status)) { $Issues.Add("Unsupported catalog status for ${SkillName}: $Status") }
      switch ($PackageRepository) {
        "oceans-skills" { $RepositoryRoot = $FirstPartySkillsRoot }
        "community-skills" { $RepositoryRoot = $CommunitySkillsRoot }
        default { $Issues.Add("Unsupported package repository for ${SkillName}: $PackageRepository"); $RepositoryRoot = $null }
      }

      $CurrentValues = @(
        [string]$Record["upstream_repository"], [string]$Record["upstream_path"],
        [string]$Record["upstream_ref"], [string]$Record["upstream_commit"]
      )
      $CandidateValues = @(
        [string]$Record["candidate_upstream_repository"], [string]$Record["candidate_upstream_path"],
        [string]$Record["candidate_upstream_ref"], [string]$Record["candidate_upstream_commit"]
      )
      $CurrentCount = @($CurrentValues | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
      $CandidateCount = @($CandidateValues | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
      if ($CurrentCount -notin @(0, 4)) { $Issues.Add("Partial current provenance for $SkillName") }
      if ($CandidateCount -notin @(0, 4)) { $Issues.Add("Partial candidate provenance for $SkillName") }

      if ($CurrentCount -eq 4) {
        if (-not (Test-OceansCatalogRepositoryUrl -Value $CurrentValues[0])) { $Issues.Add("Invalid upstream repository for $SkillName") }
        if (-not (Test-OceansCatalogUpstreamPath -Value $CurrentValues[1])) { $Issues.Add("Invalid upstream path for ${SkillName}: $($CurrentValues[1])") }
        if ($CurrentValues[3] -notmatch '^[0-9a-f]{40}$') { $Issues.Add("Invalid upstream commit for $SkillName") }
      }
      if ($CandidateCount -eq 4) {
        if (-not (Test-OceansCatalogRepositoryUrl -Value $CandidateValues[0])) { $Issues.Add("Invalid candidate repository for $SkillName") }
        if (-not (Test-OceansCatalogUpstreamPath -Value $CandidateValues[1])) { $Issues.Add("Invalid candidate path for ${SkillName}: $($CandidateValues[1])") }
        if ($CandidateValues[3] -notmatch '^[0-9a-f]{40}$') { $Issues.Add("Invalid candidate commit for $SkillName") }
        $ReviewPath = Get-OceansCatalogReviewPath -CatalogRoot $CatalogRoot -PackageRepository $PackageRepository -SkillName $SkillName
        if (-not (Test-Path -LiteralPath $ReviewPath -PathType Container)) { $Issues.Add("Candidate review content is missing: $PackageRepository/$SkillName") }
      }

      $StatusReason = [string]$Record["status_reason"]
      switch ($Status) {
        "pending-review" {
          if ($CurrentCount -ne 0) { $Issues.Add("Pending new skill must not have current provenance: $SkillName") }
          if ($CandidateCount -ne 4) { $Issues.Add("Pending new skill must have a complete candidate: $SkillName") }
          if ($RepositoryRoot -and (Test-Path -LiteralPath (Join-Path $RepositoryRoot $SkillName) -PathType Container)) { $Issues.Add("Pending new skill already exists in package repository: $SkillName") }
          if (-not [string]::IsNullOrWhiteSpace($StatusReason)) { $Issues.Add("Pending skill must not keep a status reason: $SkillName") }
        }
        "active" {
          if ($CurrentCount -ne 4) { $Issues.Add("Active skill lacks current provenance: $SkillName") }
          if (-not [string]::IsNullOrWhiteSpace($StatusReason)) { $Issues.Add("Active skill must not keep a status reason: $SkillName") }
          if ($RepositoryRoot -and -not (Test-Path -LiteralPath (Join-Path $RepositoryRoot $SkillName) -PathType Container)) { $Issues.Add("Active skill package is missing: $PackageRepository/$SkillName") }
        }
        { $_ -in @("deprecated", "archived", "blocked") } {
          if ($CurrentCount -ne 4) { $Issues.Add("$Status skill lacks current provenance: $SkillName") }
          if ($CandidateCount -ne 0) { $Issues.Add("$Status skill cannot have a pending candidate: $SkillName") }
          if ([string]::IsNullOrWhiteSpace($StatusReason)) { $Issues.Add("Missing lifecycle reason for $Status skill: $SkillName") }
          if ($RepositoryRoot -and -not (Test-Path -LiteralPath (Join-Path $RepositoryRoot $SkillName) -PathType Container)) { $Issues.Add("$Status skill package is missing: $PackageRepository/$SkillName") }
        }
      }

      $Replacement = [string]$Record["replacement"]
      if (-not [string]::IsNullOrWhiteSpace($Replacement)) {
        if (-not (Test-OceansCatalogSkillName -Name $Replacement)) { $Issues.Add("Invalid replacement for ${SkillName}: $Replacement") }
        if ($Replacement -ceq $SkillName) { $Issues.Add("Skill cannot replace itself: $SkillName") }
        $ReplacementPath = Get-OceansCatalogRecordPath -CatalogRoot $CatalogRoot -SkillName $Replacement
        if (-not (Test-Path -LiteralPath $ReplacementPath -PathType Leaf)) {
          $Issues.Add("Replacement skill is missing from catalog: $SkillName -> $Replacement")
        } else {
          $ReplacementRecord = Get-OceansCatalogRecord -Path $ReplacementPath
          if ([string]$ReplacementRecord["status"] -cne "active") { $Issues.Add("Replacement skill is not active: $SkillName -> $Replacement") }
        }
      }
      if ([string]$Record["updated_at"] -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') { $Issues.Add("Invalid updated_at for $SkillName") }
    }
  }

  foreach ($RepositoryEntry in @(
      [PSCustomObject]@{ Name = "oceans-skills"; Root = $FirstPartySkillsRoot },
      [PSCustomObject]@{ Name = "community-skills"; Root = $CommunitySkillsRoot }
    )) {
    if (-not (Test-Path -LiteralPath $RepositoryEntry.Root -PathType Container)) { continue }
    foreach ($SkillDirectory in @(Get-ChildItem -LiteralPath $RepositoryEntry.Root -Directory)) {
      $RecordPath = Get-OceansCatalogRecordPath -CatalogRoot $CatalogRoot -SkillName $SkillDirectory.Name
      if (-not (Test-Path -LiteralPath $RecordPath -PathType Leaf)) {
        $Issues.Add("Skill is missing from catalog: $($RepositoryEntry.Name)/$($SkillDirectory.Name)")
        continue
      }
      $Record = Get-OceansCatalogRecord -Path $RecordPath
      if ([string]$Record["package_repository"] -cne $RepositoryEntry.Name) { $Issues.Add("Catalog repository mismatch for $($SkillDirectory.Name): $([string]$Record['package_repository'])") }
      if ([string]$Record["status"] -ceq "pending-review") { $Issues.Add("Pending new skill must not exist in active package directory: $($SkillDirectory.Name)") }
    }
  }

  foreach ($PackageRepository in @("oceans-skills", "community-skills")) {
    $PackageReviewRoot = Join-Path $ReviewRoot $PackageRepository
    if (-not (Test-Path -LiteralPath $PackageReviewRoot -PathType Container)) { continue }
    foreach ($ReviewDirectory in @(Get-ChildItem -LiteralPath $PackageReviewRoot -Directory)) {
      $SkillName = $ReviewDirectory.Name
      $RecordPath = Get-OceansCatalogRecordPath -CatalogRoot $CatalogRoot -SkillName $SkillName
      if (-not (Test-Path -LiteralPath $RecordPath -PathType Leaf)) {
        $Issues.Add("Orphan candidate review content: $PackageRepository/$SkillName")
        continue
      }
      $Record = Get-OceansCatalogRecord -Path $RecordPath
      if ([string]$Record["package_repository"] -cne $PackageRepository) { $Issues.Add("Candidate repository mismatch for ${SkillName}: $([string]$Record['package_repository'])") }
      if ([string]::IsNullOrWhiteSpace([string]$Record["candidate_upstream_commit"])) { $Issues.Add("Orphan candidate review content: $PackageRepository/$SkillName") }
    }
  }

  return $Issues
}
