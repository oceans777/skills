if (-not (Get-Command Get-OceansIncludedSkillFiles -ErrorAction SilentlyContinue)) {
  . (Join-Path $PSScriptRoot "skill-publish-rules.ps1")
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
    $FileHash = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
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
