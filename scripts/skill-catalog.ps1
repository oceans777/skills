$script:OceansCatalogStates = @("active", "pending-review", "deprecated", "archived", "blocked")

function Test-OceansCatalogState {
  param([Parameter(Mandatory = $true)][string] $State)
  return $script:OceansCatalogStates -contains $State
}

function Get-OceansCatalogRecordPath {
  param(
    [Parameter(Mandatory = $true)][string] $CatalogRoot,
    [Parameter(Mandatory = $true)][string] $State,
    [Parameter(Mandatory = $true)][string] $SkillName
  )
  return (Join-Path (Join-Path $CatalogRoot $State) "$SkillName.skill")
}

function Get-OceansCatalogRecord {
  param([Parameter(Mandatory = $true)][string] $Path)

  $Values = @{}
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $Values
  }
  foreach ($Line in @(Get-Content -LiteralPath $Path -Encoding UTF8)) {
    $Separator = $Line.IndexOf('=')
    if ($Separator -lt 1) { continue }
    $Key = $Line.Substring(0, $Separator)
    $Value = $Line.Substring($Separator + 1)
    $Values[$Key] = $Value
  }
  return $Values
}

function Get-OceansCatalogStatesForSkill {
  param(
    [Parameter(Mandatory = $true)][string] $CatalogRoot,
    [Parameter(Mandatory = $true)][string] $SkillName
  )

  $States = New-Object System.Collections.Generic.List[string]
  foreach ($State in $script:OceansCatalogStates) {
    $RecordPath = Get-OceansCatalogRecordPath -CatalogRoot $CatalogRoot -State $State -SkillName $SkillName
    if (Test-Path -LiteralPath $RecordPath -PathType Leaf) {
      $States.Add($State)
    }
  }
  return @($States)
}

function Get-OceansCatalogStateForSkill {
  param(
    [Parameter(Mandatory = $true)][string] $CatalogRoot,
    [Parameter(Mandatory = $true)][string] $SkillName
  )

  $States = @(Get-OceansCatalogStatesForSkill -CatalogRoot $CatalogRoot -SkillName $SkillName)
  if ($States.Count -eq 0) { return $null }
  if ($States.Count -gt 1) { throw "catalog-duplicate-state: $SkillName" }
  return $States[0]
}

function Assert-OceansCatalogSingleLineValue {
  param([AllowEmptyString()][string] $Value)
  if ($Value -match '[\r\n]') {
    throw "Catalog values must be single-line text."
  }
}

function Write-OceansCatalogRecord {
  param(
    [Parameter(Mandatory = $true)][string] $CatalogRoot,
    [Parameter(Mandatory = $true)][string] $State,
    [Parameter(Mandatory = $true)][string] $SkillName,
    [Parameter(Mandatory = $true)][string] $Repository,
    [Parameter(Mandatory = $true)][string] $SourceUrl,
    [Parameter(Mandatory = $true)][string] $SourcePath,
    [Parameter(Mandatory = $true)][string] $SourceRef,
    [Parameter(Mandatory = $true)][string] $SourceCommit,
    [AllowEmptyString()][string] $Replacement = "",
    [AllowEmptyString()][string] $Reason = ""
  )

  if (-not (Test-OceansCatalogState -State $State)) {
    throw "Unsupported catalog state: $State"
  }
  if (@("oceans-skills", "community-skills") -notcontains $Repository) {
    throw "Unsupported catalog repository: $Repository"
  }
  foreach ($Value in @($SkillName, $Repository, $SourceUrl, $SourcePath, $SourceRef, $SourceCommit, $Replacement, $Reason)) {
    Assert-OceansCatalogSingleLineValue -Value $Value
  }

  $StateDirectory = Join-Path $CatalogRoot $State
  New-Item -ItemType Directory -Force -Path $StateDirectory | Out-Null
  $RecordPath = Get-OceansCatalogRecordPath -CatalogRoot $CatalogRoot -State $State -SkillName $SkillName
  $StagingPath = Join-Path $StateDirectory ".$SkillName.skill.$([Guid]::NewGuid().ToString('N'))"
  $Lines = @(
    "name=$SkillName",
    "repository=$Repository",
    "source_url=$SourceUrl",
    "source_path=$SourcePath",
    "source_ref=$SourceRef",
    "source_commit=$SourceCommit",
    "replacement=$Replacement",
    "reason=$Reason",
    "updated_at=$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
  )
  [System.IO.File]::WriteAllLines($StagingPath, $Lines, (New-Object System.Text.UTF8Encoding($false)))
  Move-Item -LiteralPath $StagingPath -Destination $RecordPath -Force
  return $RecordPath
}

function Move-OceansCatalogRecord {
  param(
    [Parameter(Mandatory = $true)][string] $CatalogRoot,
    [Parameter(Mandatory = $true)][string] $SkillName,
    [Parameter(Mandatory = $true)][string] $TargetState,
    [AllowEmptyString()][string] $Replacement = "",
    [AllowEmptyString()][string] $Reason = ""
  )

  if (-not (Test-OceansCatalogState -State $TargetState)) {
    throw "Unsupported catalog state: $TargetState"
  }
  $CurrentState = Get-OceansCatalogStateForSkill -CatalogRoot $CatalogRoot -SkillName $SkillName
  if (-not $CurrentState) { throw "catalog-skill-not-found: $SkillName" }
  $CurrentPath = Get-OceansCatalogRecordPath -CatalogRoot $CatalogRoot -State $CurrentState -SkillName $SkillName
  $Record = Get-OceansCatalogRecord -Path $CurrentPath
  if (-not $Replacement) { $Replacement = [string]$Record["replacement"] }
  if (-not $Reason) { $Reason = [string]$Record["reason"] }

  $TargetPath = Write-OceansCatalogRecord `
    -CatalogRoot $CatalogRoot `
    -State $TargetState `
    -SkillName $SkillName `
    -Repository ([string]$Record["repository"]) `
    -SourceUrl ([string]$Record["source_url"]) `
    -SourcePath ([string]$Record["source_path"]) `
    -SourceRef ([string]$Record["source_ref"]) `
    -SourceCommit ([string]$Record["source_commit"]) `
    -Replacement $Replacement `
    -Reason $Reason

  if (-not $CurrentPath.Equals($TargetPath, [StringComparison]::OrdinalIgnoreCase)) {
    Remove-Item -LiteralPath $CurrentPath -Force
  }
  return $TargetPath
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

  foreach ($State in $script:OceansCatalogStates) {
    $StateDirectory = Join-Path $CatalogRoot $State
    if (-not (Test-Path -LiteralPath $StateDirectory -PathType Container)) {
      $Issues.Add("Missing catalog state directory: $StateDirectory")
      continue
    }
    foreach ($RecordFile in @(Get-ChildItem -LiteralPath $StateDirectory -Filter '*.skill' -File)) {
      $SkillName = [System.IO.Path]::GetFileNameWithoutExtension($RecordFile.Name)
      $Record = Get-OceansCatalogRecord -Path $RecordFile.FullName
      if ([string]$Record["name"] -cne $SkillName) {
        $Issues.Add("Catalog name mismatch in ${State}: $SkillName")
      }
      $Repository = [string]$Record["repository"]
      switch ($Repository) {
        "oceans-skills" { $RepositoryRoot = $FirstPartySkillsRoot }
        "community-skills" { $RepositoryRoot = $CommunitySkillsRoot }
        default {
          $Issues.Add("Unsupported catalog repository for ${SkillName}: $Repository")
          $RepositoryRoot = $null
        }
      }
      if ([string]$Record["source_url"] -notmatch '^https://github\.com/') {
        $Issues.Add("Invalid catalog source_url for $SkillName")
      }
      if ([string]$Record["source_path"] -cne "skills/$SkillName") {
        $Issues.Add("Invalid catalog source_path for ${SkillName}: $([string]$Record['source_path'])")
      }
      if ([string]::IsNullOrWhiteSpace([string]$Record["source_ref"])) {
        $Issues.Add("Missing catalog source_ref for $SkillName")
      }
      if ([string]$Record["source_commit"] -notmatch '^[0-9a-f]{40}$') {
        $Issues.Add("Invalid catalog source_commit for $SkillName")
      }
      if (@("archived", "blocked") -contains $State -and [string]::IsNullOrWhiteSpace([string]$Record["reason"])) {
        $Issues.Add("Missing lifecycle reason for $State skill: $SkillName")
      }
      if ($RepositoryRoot -and -not (Test-Path -LiteralPath (Join-Path $RepositoryRoot $SkillName) -PathType Container)) {
        $Issues.Add("Catalog record points to a missing skill: $Repository/$SkillName")
      }
      $States = @(Get-OceansCatalogStatesForSkill -CatalogRoot $CatalogRoot -SkillName $SkillName)
      if ($States.Count -ne 1) {
        $Issues.Add("Skill exists in multiple catalog states: $SkillName")
      }
    }
  }

  foreach ($RepositoryEntry in @(
      [PSCustomObject]@{ Name = "oceans-skills"; Root = $FirstPartySkillsRoot },
      [PSCustomObject]@{ Name = "community-skills"; Root = $CommunitySkillsRoot }
    )) {
    if (-not (Test-Path -LiteralPath $RepositoryEntry.Root -PathType Container)) { continue }
    foreach ($SkillDirectory in @(Get-ChildItem -LiteralPath $RepositoryEntry.Root -Directory)) {
      try {
        $State = Get-OceansCatalogStateForSkill -CatalogRoot $CatalogRoot -SkillName $SkillDirectory.Name
      } catch {
        $Issues.Add("Skill exists in multiple catalog states: $($SkillDirectory.Name)")
        continue
      }
      if (-not $State) {
        $Issues.Add("Skill is missing from catalog: $($RepositoryEntry.Name)/$($SkillDirectory.Name)")
        continue
      }
      $RecordPath = Get-OceansCatalogRecordPath -CatalogRoot $CatalogRoot -State $State -SkillName $SkillDirectory.Name
      $Record = Get-OceansCatalogRecord -Path $RecordPath
      if ([string]$Record["repository"] -cne $RepositoryEntry.Name) {
        $Issues.Add("Catalog repository mismatch for $($SkillDirectory.Name): $([string]$Record['repository'])")
      }
    }
  }

  return $Issues
}
