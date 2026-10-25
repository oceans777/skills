function New-OceansStagingDirectory {
  param([Parameter(Mandatory = $true)][string] $TargetPath)

  $Parent = Split-Path -Parent $TargetPath
  $Name = Split-Path -Leaf $TargetPath
  if (-not (Test-Path -LiteralPath $Parent -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $Parent | Out-Null
  }

  $StagingPath = Join-Path $Parent ".$Name.oceans-stage.$([Guid]::NewGuid().ToString('N'))"
  New-Item -ItemType Directory -Path $StagingPath | Out-Null
  return $StagingPath
}

function Remove-OceansExcludedPaths {
  param([Parameter(Mandatory = $true)][string] $RootPath)

  $Excluded = @('.git', '.oceans-skill-source', '.DS_Store', 'Thumbs.db', '.pytest_cache', '__pycache__', 'node_modules')
  Get-ChildItem -LiteralPath $RootPath -Force -Recurse -ErrorAction SilentlyContinue |
    Sort-Object { $_.FullName.Length } -Descending |
    Where-Object { $Excluded -contains $_.Name } |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force }
}

function Complete-OceansSkillReplacePreservingGit {
  param(
    [Parameter(Mandatory = $true)][string] $StagingPath,
    [Parameter(Mandatory = $true)][string] $TargetPath
  )

  $StagedItem = Get-Item -LiteralPath $StagingPath -Force
  $TargetItem = Get-Item -LiteralPath $TargetPath -Force
  if (-not $StagedItem.PSIsContainer -or (($StagedItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
    throw "Invalid staged directory: $StagingPath"
  }
  if (-not $TargetItem.PSIsContainer -or (($TargetItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
    throw "Invalid skill repository: $TargetPath"
  }
  $GitPath = Join-Path $TargetPath ".git"
  if (-not (Test-Path -LiteralPath $GitPath)) { throw "Skill repository is missing .git: $TargetPath" }
  $GitItem = Get-Item -LiteralPath $GitPath -Force
  if (($GitItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Refusing to preserve a reparse-point .git: $GitPath"
  }

  $Backup = Join-Path ([System.IO.Path]::GetTempPath()) ("oceans-git-preserve-" + [Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $Backup | Out-Null
  try {
    Get-ChildItem -LiteralPath $TargetPath -Force | Where-Object { $_.Name -cne ".git" } | ForEach-Object {
      Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $Backup $_.Name) -Recurse -Force
    }
    Get-ChildItem -LiteralPath $TargetPath -Force | Where-Object { $_.Name -cne ".git" } | ForEach-Object {
      Remove-Item -LiteralPath $_.FullName -Recurse -Force
    }
    Get-ChildItem -LiteralPath $StagingPath -Force | Copy-Item -Destination $TargetPath -Recurse -Force
    Remove-Item -LiteralPath $StagingPath -Recurse -Force
    Remove-Item -LiteralPath $Backup -Recurse -Force
  } catch {
    Get-ChildItem -LiteralPath $TargetPath -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -cne ".git" } | ForEach-Object {
      Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $Backup) {
      Get-ChildItem -LiteralPath $Backup -Force | Copy-Item -Destination $TargetPath -Recurse -Force
      Remove-Item -LiteralPath $Backup -Recurse -Force -ErrorAction SilentlyContinue
    }
    throw
  }
}

function Complete-OceansDirectoryTransaction {
  param(
    [Parameter(Mandatory = $true)][string] $StagingPath,
    [Parameter(Mandatory = $true)][string] $TargetPath
  )

  $StagedItem = Get-Item -LiteralPath $StagingPath -Force
  if (-not $StagedItem.PSIsContainer -or
      ($StagedItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Invalid staged directory: $StagingPath"
  }

  $Parent = [System.IO.Path]::GetFullPath((Split-Path -Parent $TargetPath))
  $Name = Split-Path -Leaf $TargetPath
  $ResolvedStaging = [System.IO.Path]::GetFullPath($StagingPath)
  $ExpectedPrefix = Join-Path $Parent ".$Name.oceans-stage."
  if (-not $ResolvedStaging.StartsWith($ExpectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Staged directory must be a sibling of its target: $StagingPath"
  }

  $BackupPath = Join-Path $Parent ".$Name.oceans-backup"
  $LockPath = Join-Path $Parent ".$Name.oceans-lock"
  $LockStream = $null
  try {
    try {
      $LockStream = [System.IO.File]::Open($LockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    } catch [System.IO.IOException] {
      try {
        $StaleLock = [System.IO.File]::Open($LockPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $StaleLock.Dispose()
        Remove-Item -LiteralPath $LockPath -Force
        $LockStream = [System.IO.File]::Open($LockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
      } catch {
        throw "Another directory transaction is active: $TargetPath"
      }
    }

    if (Test-Path -LiteralPath $TargetPath) {
      $TargetItem = Get-Item -LiteralPath $TargetPath -Force
      if (($TargetItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to replace a reparse-point target: $TargetPath"
      }
    }

    if (Test-Path -LiteralPath $BackupPath) {
      $BackupItem = Get-Item -LiteralPath $BackupPath -Force
      if (($BackupItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing unsafe transaction backup: $BackupPath"
      }
      if (Test-Path -LiteralPath $TargetPath) {
        Remove-Item -LiteralPath $BackupPath -Recurse -Force
      } else {
        Move-Item -LiteralPath $BackupPath -Destination $TargetPath
      }
    }

    if (Test-Path -LiteralPath $TargetPath) {
      Move-Item -LiteralPath $TargetPath -Destination $BackupPath
    }

    Move-Item -LiteralPath $StagingPath -Destination $TargetPath
    if (Test-Path -LiteralPath $BackupPath) {
      try {
        Remove-Item -LiteralPath $BackupPath -Recurse -Force
      } catch {
        Write-Warning "Activated $TargetPath but could not remove recovery backup: $BackupPath"
      }
    }
  } catch {
    if ((Test-Path -LiteralPath $BackupPath) -and
        -not (Test-Path -LiteralPath $TargetPath)) {
      $BackupItem = Get-Item -LiteralPath $BackupPath -Force
      if (($BackupItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
        Move-Item -LiteralPath $BackupPath -Destination $TargetPath
      }
    }
    throw
  } finally {
    if ($LockStream) { $LockStream.Dispose() }
    if (Test-Path -LiteralPath $LockPath -PathType Leaf) {
      Remove-Item -LiteralPath $LockPath -Force
    }
  }

}
