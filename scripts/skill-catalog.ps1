$script:OceansCatalogSchemaVersion = "2"
$script:OceansCatalogStates = @("active", "pending-review", "deprecated", "archived", "blocked")
$script:OceansCatalogRequiredKeys = @(
  "schema_version", "name", "status", "package_repository",
  "upstream_repository", "upstream_path", "upstream_ref", "upstream_commit",
  "candidate_upstream_repository", "candidate_upstream_path", "candidate_upstream_ref", "candidate_upstream_commit",
  "replacement", "status_reason", "transition_note", "updated_at"
)
$script:OceansCatalogOptionalKeys = @("content_sha256", "candidate_content_sha256")
$script:OceansCatalogKeys = @($script:OceansCatalogRequiredKeys + $script:OceansCatalogOptionalKeys)
$script:OceansCatalogLockPath = $null
. (Join-Path $PSScriptRoot "skill-content-hash.ps1")

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

function Test-OceansCatalogPackageRepositoryAllowed {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $PackageRepository)
  if ($PackageRepository -in @("community-skills", "oceans-skills")) { return $true }
  return (Test-OceansCatalogSkillName -Name $PackageRepository)
}

function Test-OceansCatalogOnlyStub {
  param(
    [AllowEmptyString()][string] $PackageRepository,
    [AllowEmptyString()][string] $SkillName,
    [AllowEmptyString()][string] $Replacement,
    [AllowEmptyString()][string] $Status
  )
  return ($Status -eq "archived" -and
    -not [string]::IsNullOrWhiteSpace($Replacement) -and
    $PackageRepository -ceq $Replacement -and
    $PackageRepository -cne $SkillName)
}

function Resolve-OceansCatalogSkillDirectory {
  param(
    [Parameter(Mandatory = $true)][string] $FirstPartySkillsRoot,
    [Parameter(Mandatory = $true)][string] $CommunitySkillsRoot,
    [AllowEmptyString()][string] $PackageRepository,
    [AllowEmptyString()][string] $SkillName,
    [AllowEmptyString()][string] $Replacement = "",
    [AllowEmptyString()][string] $Status = ""
  )
  if ($PackageRepository -eq "community-skills") {
    return [PSCustomObject]@{ Ok = $true; Path = (Join-Path $CommunitySkillsRoot $SkillName); Stub = $false }
  }
  if ($PackageRepository -eq "oceans-skills") {
    return [PSCustomObject]@{ Ok = $true; Path = (Join-Path $FirstPartySkillsRoot $SkillName); Stub = $false }
  }
  if (-not (Test-OceansCatalogSkillName -Name $PackageRepository)) {
    return [PSCustomObject]@{ Ok = $false; Path = $null; Stub = $false }
  }
  if ($PackageRepository -ceq $SkillName) {
    return [PSCustomObject]@{ Ok = $true; Path = (Join-Path $FirstPartySkillsRoot $SkillName); Stub = $false }
  }
  if (Test-OceansCatalogOnlyStub -PackageRepository $PackageRepository -SkillName $SkillName -Replacement $Replacement -Status $Status) {
    return [PSCustomObject]@{ Ok = $true; Path = ""; Stub = $true }
  }
  return [PSCustomObject]@{ Ok = $false; Path = $null; Stub = $false }
}

function Test-OceansCatalogHubReposLayout {
  param([Parameter(Mandatory = $true)][string] $FirstPartySkillsRoot)
  $Parent = Split-Path -Parent $FirstPartySkillsRoot
  $Base = Split-Path -Leaf $FirstPartySkillsRoot
  if ([string]::IsNullOrWhiteSpace($Parent)) { return $false }
  return ($Base -eq "repos" -and (Test-Path -LiteralPath (Join-Path $Parent ".gitmodules") -PathType Leaf))
}

function Get-OceansCatalogHubSkillNames {
  param([Parameter(Mandatory = $true)][string] $FirstPartySkillsRoot)
  $Names = New-Object System.Collections.Generic.List[string]
  $Parent = Split-Path -Parent $FirstPartySkillsRoot
  if ([string]::IsNullOrWhiteSpace($Parent)) { return @($Names) }
  $Gitmodules = Join-Path $Parent ".gitmodules"
  if (-not (Test-Path -LiteralPath $Gitmodules -PathType Leaf)) { return @($Names) }
  $Output = & git -C $Parent config -f $Gitmodules --get-regexp '^submodule\..*\.path$'
  foreach ($Line in @($Output)) {
    $Text = [string]$Line
    if ([string]::IsNullOrWhiteSpace($Text)) { continue }
    $Space = $Text.LastIndexOf(' ')
    if ($Space -lt 1) { continue }
    $Path = $Text.Substring($Space + 1).Trim()
    if ($Path -in @("repos/community-skills", "repos/oceans-skills")) { continue }
    if ($Path.StartsWith("repos/") -and -not $Path.Substring(6).Contains("/")) {
      $Names.Add($Path.Substring(6))
    }
  }
  return @($Names)
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
    [AllowEmptyString()][string] $TransitionNote = "",
    [AllowEmptyString()][string] $ContentSha256 = "",
    [AllowEmptyString()][string] $CandidateContentSha256 = ""
  )

  if (-not (Test-OceansCatalogSkillName -Name $SkillName)) { throw "Invalid catalog skill name: $SkillName" }
  if (-not (Test-OceansCatalogState -State $Status)) { throw "Unsupported catalog state: $Status" }
  if (-not (Test-OceansCatalogPackageRepositoryAllowed -PackageRepository $PackageRepository)) {
    throw "Unsupported package repository: $PackageRepository"
  }
  foreach ($Value in @(
      $SkillName, $Status, $PackageRepository, $UpstreamRepository, $UpstreamPath, $UpstreamRef, $UpstreamCommit,
      $CandidateUpstreamRepository, $CandidateUpstreamPath, $CandidateUpstreamRef, $CandidateUpstreamCommit,
      $Replacement, $StatusReason, $TransitionNote, $ContentSha256, $CandidateContentSha256
    )) {
    Assert-OceansCatalogSingleLineValue -Value $Value
  }
  if ($ContentSha256 -and -not (Test-OceansSha256 -Value $ContentSha256)) { throw "Invalid content SHA-256 for $SkillName" }
  if ($CandidateContentSha256 -and -not (Test-OceansSha256 -Value $CandidateContentSha256)) { throw "Invalid candidate content SHA-256 for $SkillName" }

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
    "content_sha256=$ContentSha256",
    "candidate_content_sha256=$CandidateContentSha256",
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
  foreach ($RequiredKey in $script:OceansCatalogRequiredKeys) {
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
      $ContentSha256 = [string]$Record["content_sha256"]
      $CandidateContentSha256 = [string]$Record["candidate_content_sha256"]
      if ([string]$Record["schema_version"] -ne $script:OceansCatalogSchemaVersion) { $Issues.Add("Unsupported catalog schema for ${SkillName}: $([string]$Record['schema_version'])") }
      if (-not (Test-OceansCatalogSkillName -Name $SkillName)) { $Issues.Add("Invalid catalog filename: $($RecordFile.Name)") }
      if ([string]$Record["name"] -cne $SkillName) { $Issues.Add("Catalog name mismatch: $SkillName") }
      if (-not (Test-OceansCatalogState -State $Status)) { $Issues.Add("Unsupported catalog status for ${SkillName}: $Status") }
      $Replacement = [string]$Record["replacement"]
      $ResolvedSkill = Resolve-OceansCatalogSkillDirectory -FirstPartySkillsRoot $FirstPartySkillsRoot -CommunitySkillsRoot $CommunitySkillsRoot -PackageRepository $PackageRepository -SkillName $SkillName -Replacement $Replacement -Status $Status
      $SkillDirectory = if ($ResolvedSkill.Ok) { [string]$ResolvedSkill.Path } else { $null }
      if (-not $ResolvedSkill.Ok) { $Issues.Add("Unsupported package repository for ${SkillName}: $PackageRepository") }

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

      if ($ContentSha256 -and -not (Test-OceansSha256 -Value $ContentSha256)) { $Issues.Add("Invalid content SHA-256 for $SkillName") }
      if ($CandidateContentSha256 -and -not (Test-OceansSha256 -Value $CandidateContentSha256)) { $Issues.Add("Invalid candidate content SHA-256 for $SkillName") }
      if ($CurrentCount -eq 0 -and $ContentSha256) { $Issues.Add("Content SHA-256 exists without current provenance: $SkillName") }
      if ($CandidateCount -eq 0 -and $CandidateContentSha256) { $Issues.Add("Candidate content SHA-256 exists without candidate provenance: $SkillName") }

      if ($CurrentCount -eq 4) {
        if (-not (Test-OceansCatalogRepositoryUrl -Value $CurrentValues[0])) { $Issues.Add("Invalid upstream repository for $SkillName") }
        if (-not (Test-OceansCatalogUpstreamPath -Value $CurrentValues[1])) { $Issues.Add("Invalid upstream path for ${SkillName}: $($CurrentValues[1])") }
        if ($CurrentValues[3] -notmatch '^[0-9a-f]{40}$') { $Issues.Add("Invalid upstream commit for $SkillName") }
        if ($ContentSha256 -and $SkillDirectory -and (Test-Path -LiteralPath $SkillDirectory -PathType Container)) {
          try {
            $ActualContentSha256 = Get-OceansSkillContentSha256 -SkillPath $SkillDirectory
            if ($ActualContentSha256 -cne $ContentSha256) { $Issues.Add("Published content SHA-256 mismatch for $SkillName") }
          } catch { $Issues.Add("Unable to calculate published content SHA-256 for ${SkillName}: $($_.Exception.Message)") }
        }
      }
      if ($CandidateCount -eq 4) {
        if (-not (Test-OceansCatalogRepositoryUrl -Value $CandidateValues[0])) { $Issues.Add("Invalid candidate repository for $SkillName") }
        if (-not (Test-OceansCatalogUpstreamPath -Value $CandidateValues[1])) { $Issues.Add("Invalid candidate path for ${SkillName}: $($CandidateValues[1])") }
        if ($CandidateValues[3] -notmatch '^[0-9a-f]{40}$') { $Issues.Add("Invalid candidate commit for $SkillName") }
        if (-not $CandidateContentSha256) { $Issues.Add("Candidate content SHA-256 is missing: $SkillName") }
        $ReviewPath = Get-OceansCatalogReviewPath -CatalogRoot $CatalogRoot -PackageRepository $PackageRepository -SkillName $SkillName
        if (-not (Test-Path -LiteralPath $ReviewPath -PathType Container)) {
          $Issues.Add("Candidate review content is missing: $PackageRepository/$SkillName")
        } elseif ($CandidateContentSha256 -and (Test-OceansSha256 -Value $CandidateContentSha256)) {
          try {
            $ActualCandidateSha256 = Get-OceansSkillContentSha256 -SkillPath $ReviewPath
            if ($ActualCandidateSha256 -cne $CandidateContentSha256) { $Issues.Add("Candidate content SHA-256 mismatch for $SkillName") }
          } catch { $Issues.Add("Unable to calculate candidate content SHA-256 for ${SkillName}: $($_.Exception.Message)") }
        }
      }

      $StatusReason = [string]$Record["status_reason"]
      switch ($Status) {
        "pending-review" {
          if ($CurrentCount -ne 0) { $Issues.Add("Pending new skill must not have current provenance: $SkillName") }
          if ($CandidateCount -ne 4) { $Issues.Add("Pending new skill must have a complete candidate: $SkillName") }
          if ($PackageRepository -in @("community-skills", "oceans-skills") -and $SkillDirectory -and (Test-Path -LiteralPath $SkillDirectory -PathType Container)) { $Issues.Add("Pending new skill already exists in package repository: $SkillName") }
          if (-not [string]::IsNullOrWhiteSpace($StatusReason)) { $Issues.Add("Pending skill must not keep a status reason: $SkillName") }
        }
        "active" {
          if ($CurrentCount -ne 4) { $Issues.Add("Active skill lacks current provenance: $SkillName") }
          if (-not [string]::IsNullOrWhiteSpace($StatusReason)) { $Issues.Add("Active skill must not keep a status reason: $SkillName") }
          if (-not $SkillDirectory -or -not (Test-Path -LiteralPath $SkillDirectory -PathType Container)) { $Issues.Add("Active skill package is missing: $PackageRepository/$SkillName") }
        }
        { $_ -in @("deprecated", "archived", "blocked") } {
          if ($CurrentCount -ne 4) { $Issues.Add("$Status skill lacks current provenance: $SkillName") }
          if ($CandidateCount -ne 0) { $Issues.Add("$Status skill cannot have a pending candidate: $SkillName") }
          if ([string]::IsNullOrWhiteSpace($StatusReason)) { $Issues.Add("Missing lifecycle reason for $Status skill: $SkillName") }
          $CatalogOnly = Test-OceansCatalogOnlyStub -PackageRepository $PackageRepository -SkillName $SkillName -Replacement $Replacement -Status $Status
          if (-not $CatalogOnly -and (-not $SkillDirectory -or -not (Test-Path -LiteralPath $SkillDirectory -PathType Container))) { $Issues.Add("$Status skill package is missing: $PackageRepository/$SkillName") }
        }
      }

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

  if (Test-OceansCatalogHubReposLayout -FirstPartySkillsRoot $FirstPartySkillsRoot) {
    foreach ($HubSkillName in @(Get-OceansCatalogHubSkillNames -FirstPartySkillsRoot $FirstPartySkillsRoot)) {
      $PinnedPath = Join-Path $FirstPartySkillsRoot $HubSkillName
      if (-not (Test-Path -LiteralPath $PinnedPath -PathType Container)) {
        $Issues.Add("Pinned skill repository is missing: $HubSkillName")
        continue
      }
      $RecordPath = Get-OceansCatalogRecordPath -CatalogRoot $CatalogRoot -SkillName $HubSkillName
      if (-not (Test-Path -LiteralPath $RecordPath -PathType Leaf)) {
        $Issues.Add("Skill is missing from catalog: $HubSkillName")
        continue
      }
      $Record = Get-OceansCatalogRecord -Path $RecordPath
      if ([string]$Record["package_repository"] -cne $HubSkillName) { $Issues.Add("Catalog repository mismatch for ${HubSkillName}: $([string]$Record['package_repository'])") }
    }
  } elseif (Test-Path -LiteralPath $FirstPartySkillsRoot -PathType Container) {
    foreach ($PackageDirectory in @(Get-ChildItem -LiteralPath $FirstPartySkillsRoot -Directory)) {
      $RecordPath = Get-OceansCatalogRecordPath -CatalogRoot $CatalogRoot -SkillName $PackageDirectory.Name
      if (-not (Test-Path -LiteralPath $RecordPath -PathType Leaf)) {
        $Issues.Add("Skill is missing from catalog: oceans-skills/$($PackageDirectory.Name)")
        continue
      }
      $Record = Get-OceansCatalogRecord -Path $RecordPath
      if ([string]$Record["package_repository"] -cne "oceans-skills") { $Issues.Add("Catalog repository mismatch for $($PackageDirectory.Name): $([string]$Record['package_repository'])") }
      if ([string]$Record["status"] -ceq "pending-review") { $Issues.Add("Pending new skill must not exist in active package directory: $($PackageDirectory.Name)") }
    }
  }

  if (Test-Path -LiteralPath $CommunitySkillsRoot -PathType Container) {
    foreach ($PackageDirectory in @(Get-ChildItem -LiteralPath $CommunitySkillsRoot -Directory)) {
      $RecordPath = Get-OceansCatalogRecordPath -CatalogRoot $CatalogRoot -SkillName $PackageDirectory.Name
      if (-not (Test-Path -LiteralPath $RecordPath -PathType Leaf)) {
        $Issues.Add("Skill is missing from catalog: community-skills/$($PackageDirectory.Name)")
        continue
      }
      $Record = Get-OceansCatalogRecord -Path $RecordPath
      if ([string]$Record["package_repository"] -cne "community-skills") { $Issues.Add("Catalog repository mismatch for $($PackageDirectory.Name): $([string]$Record['package_repository'])") }
      if ([string]$Record["status"] -ceq "pending-review") { $Issues.Add("Pending new skill must not exist in active package directory: $($PackageDirectory.Name)") }
    }
  }

  if (Test-Path -LiteralPath $ReviewRoot -PathType Container) {
    foreach ($PackageReviewRoot in @(Get-ChildItem -LiteralPath $ReviewRoot -Directory)) {
      $PackageRepository = $PackageReviewRoot.Name
      foreach ($ReviewDirectory in @(Get-ChildItem -LiteralPath $PackageReviewRoot.FullName -Directory)) {
        $SkillName = $ReviewDirectory.Name
        $RecordPath = Get-OceansCatalogRecordPath -CatalogRoot $CatalogRoot -SkillName $SkillName
        if (-not (Test-Path -LiteralPath $RecordPath -PathType Leaf)) {
          $Issues.Add("Orphan candidate review content: $PackageRepository/$SkillName")
          continue
        }
        $Record = Get-OceansCatalogRecord -Path $RecordPath
        if ([string]$Record["package_repository"] -cne $PackageRepository) { $Issues.Add("Candidate repository mismatch for ${SkillName}: $([string]$Record['package_repository'])") }
        if ([string]::IsNullOrWhiteSpace([string]$Record["candidate_upstream_commit"])) { $Issues.Add("Orphan candidate review content: $PackageRepository/$SkillName") }
        if ([string]::IsNullOrWhiteSpace([string]$Record["candidate_content_sha256"])) { $Issues.Add("Candidate content SHA-256 is missing: $PackageRepository/$SkillName") }
      }
    }
  }

  return $Issues
}
