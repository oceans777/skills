if (-not (Get-Command Get-OceansIncludedSkillFiles -ErrorAction SilentlyContinue)) {
  . (Join-Path $PSScriptRoot "skill-publish-rules.ps1")
}

function Set-OceansCanonicalSkillPermissions {
  param([Parameter(Mandatory = $true)][string] $SkillPath)

  $RootItem = Get-Item -LiteralPath $SkillPath -Force
  if (-not $RootItem.PSIsContainer -or ($RootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Cannot normalize unsafe skill directory: $SkillPath"
  }

  if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
    return
  }

  $Items = @($RootItem) + @(Get-ChildItem -LiteralPath $RootItem.FullName -Force -Recurse)
  foreach ($Item in $Items) {
    if (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Cannot normalize reparse point inside skill: $($Item.FullName)"
    }
    $Mode = if ($Item.PSIsContainer) { "755" } else { "644" }
    & chmod $Mode -- $Item.FullName
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to normalize skill permissions: $($Item.FullName)"
    }
  }
}

function Get-OceansCanonicalTextSha256 {
  param([Parameter(Mandatory = $true)][string] $Path)

  $StrictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
  $CanonicalUtf8 = New-Object System.Text.UTF8Encoding($false)
  try {
    $Text = $StrictUtf8.GetString([System.IO.File]::ReadAllBytes($Path))
  } catch {
    throw "Cannot canonicalize non-UTF-8 skill text: $Path"
  }
  $CanonicalText = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
  $Bytes = $CanonicalUtf8.GetBytes($CanonicalText)
  $Hasher = [System.Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($Hasher.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
  } finally {
    $Hasher.Dispose()
  }
}

function Get-OceansSkillContentSha256 {
  param([Parameter(Mandatory = $true)][string] $SkillPath)

  $ResolvedRoot = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $SkillPath).Path)
  $Utf8 = New-Object System.Text.UTF8Encoding($false)
  $Entries = New-Object System.Collections.Generic.List[string]
  foreach ($File in @(Get-OceansIncludedSkillFiles -SkillPath $ResolvedRoot)) {
    $RelativePath = $File.FullName.Substring($ResolvedRoot.Length).TrimStart(
      [System.IO.Path]::DirectorySeparatorChar,
      [System.IO.Path]::AltDirectorySeparatorChar
    ).Replace('\', '/')
    $PathHex = ([BitConverter]::ToString($Utf8.GetBytes($RelativePath))).Replace('-', '').ToLowerInvariant()
    $FileHash = Get-OceansCanonicalTextSha256 -Path $File.FullName
    $Entries.Add("$PathHex $FileHash")
  }

  $SortedEntries = $Entries.ToArray()
  [Array]::Sort($SortedEntries, [StringComparer]::Ordinal)
  $Manifest = if ($SortedEntries.Count -gt 0) { ($SortedEntries -join "`n") + "`n" } else { "" }
  $Bytes = $Utf8.GetBytes($Manifest)
  $Hasher = [System.Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($Hasher.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
  } finally {
    $Hasher.Dispose()
  }
}

function Test-OceansSha256 {
  param([AllowEmptyString()][string] $Value)
  return $Value -match '^[0-9a-f]{64}$'
}
