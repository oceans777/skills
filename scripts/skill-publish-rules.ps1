$script:OceansSkillPublishExcludedNames = @(
  ".git",
  ".oceans-skill-source",
  ".DS_Store",
  "Thumbs.db",
  ".pytest_cache",
  "__pycache__",
  "node_modules"
)

$script:OceansSkillPublishSecretPattern = '(?i)(api[_-]?key\s*[:=]|secret\s*[:=]|token\s*[:=]|password\s*[:=]|authorization\s*:?\s*bearer|sk-[a-zA-Z0-9_-]{10,})'
$script:OceansSkillPublishLocalPathPattern = '(^|[^A-Za-z0-9_])(/Users/[^/]+(?=/|$)|/home/[^/]+(?=/|$)|[A-Za-z]:[\\/][Uu]sers[\\/][^\\/]+(?=[\\/]|$)|/private/(?:var|tmp|etc)(?=/|$))'

function Test-OceansSkillName {
  param([Parameter(Mandatory = $true)][string] $Name)

  return ($Name -match '^[a-z0-9]+(-[a-z0-9]+)*$')
}

function Test-OceansExcludedRelativePath {
  param([Parameter(Mandatory = $true)][string] $RelativePath)

  foreach ($Part in ($RelativePath -split '[\\/]')) {
    if ($script:OceansSkillPublishExcludedNames -contains $Part) {
      return $true
    }
  }

  return $false
}

function Get-OceansSkillFrontmatter {
  param([Parameter(Mandatory = $true)][string] $SkillPath)

  $SkillFile = Join-Path $SkillPath "SKILL.md"
  $Values = @{}
  if (-not (Test-Path -LiteralPath $SkillFile -PathType Leaf)) {
    return [PSCustomObject]@{ HasFrontmatter = $false; Values = $Values }
  }

  $Lines = @(Get-Content -LiteralPath $SkillFile -ErrorAction SilentlyContinue)
  if ($Lines.Count -eq 0 -or $Lines[0].Trim() -ne "---") {
    return [PSCustomObject]@{ HasFrontmatter = $false; Values = $Values }
  }

  for ($Index = 1; $Index -lt $Lines.Count; $Index++) {
    $Line = $Lines[$Index]
    if ($Line.Trim() -eq "---") {
      return [PSCustomObject]@{ HasFrontmatter = $true; Values = $Values }
    }

    if ($Line -match '^\s*([A-Za-z0-9_-]+)\s*:\s*(.*?)\s*$') {
      $Key = $Matches[1].ToLowerInvariant()
      $Value = $Matches[2].Trim()
      if (($Value.StartsWith('"') -and $Value.EndsWith('"')) -or
          ($Value.StartsWith("'") -and $Value.EndsWith("'"))) {
        $Value = $Value.Substring(1, [Math]::Max(0, $Value.Length - 2))
      }
      $Values[$Key] = $Value
    }
  }

  return [PSCustomObject]@{ HasFrontmatter = $false; Values = $Values }
}

function Get-OceansSkillFrontmatterValue {
  param(
    [Parameter(Mandatory = $true)][object] $Frontmatter,
    [Parameter(Mandatory = $true)][string] $Key
  )

  $LookupKey = $Key.ToLowerInvariant()
  if ($Frontmatter.Values.ContainsKey($LookupKey)) {
    return [string]$Frontmatter.Values[$LookupKey]
  }

  return ""
}

function Get-OceansSkillMetadataIssues {
  param(
    [Parameter(Mandatory = $true)][string] $SkillPath,
    [Parameter(Mandatory = $true)][string] $ExpectedName
  )

  $Issues = New-Object System.Collections.Generic.List[string]
  if (-not (Test-OceansSkillName -Name $ExpectedName)) {
    $Issues.Add("risk: invalid skill folder name")
  }

  $SkillFile = Join-Path $SkillPath "SKILL.md"
  if (-not (Test-Path -LiteralPath $SkillFile -PathType Leaf)) {
    return $Issues
  }

  $Frontmatter = Get-OceansSkillFrontmatter -SkillPath $SkillPath
  if (-not $Frontmatter.HasFrontmatter) {
    $Issues.Add("risk: missing skill frontmatter")
    return $Issues
  }

  $Name = Get-OceansSkillFrontmatterValue -Frontmatter $Frontmatter -Key "name"
  if ([string]::IsNullOrWhiteSpace($Name)) {
    $Issues.Add("risk: missing skill name")
  } else {
    if (-not (Test-OceansSkillName -Name $Name)) {
      $Issues.Add("risk: invalid skill name")
    }
    if ($Name -cne $ExpectedName) {
      $Issues.Add("risk: skill name does not match folder name")
    }
  }

  $Description = Get-OceansSkillFrontmatterValue -Frontmatter $Frontmatter -Key "description"
  if ([string]::IsNullOrWhiteSpace($Description)) {
    $Issues.Add("risk: missing skill description")
  }

  return $Issues
}

function Test-OceansMissingLicenseReference {
  param([Parameter(Mandatory = $true)][string] $SkillPath)

  $Frontmatter = Get-OceansSkillFrontmatter -SkillPath $SkillPath
  if (-not $Frontmatter.HasFrontmatter) {
    return $false
  }

  $LicenseValue = Get-OceansSkillFrontmatterValue -Frontmatter $Frontmatter -Key "license"
  $References = [regex]::Matches($LicenseValue, '\bLICENSE(?:\.[A-Za-z0-9._-]+)?\b') |
    ForEach-Object { $_.Value }
  foreach ($Reference in $References) {
    if (-not (Test-Path -LiteralPath (Join-Path $SkillPath $Reference) -PathType Leaf)) {
      return $true
    }
  }

  return $false
}

function Get-OceansIncludedSkillFiles {
  param([Parameter(Mandatory = $true)][string] $SkillPath)

  $Root = [System.IO.DirectoryInfo]((Resolve-Path -LiteralPath $SkillPath).Path)
  $Stack = New-Object System.Collections.Generic.Stack[System.IO.DirectoryInfo]
  $Stack.Push($Root)

  while ($Stack.Count -gt 0) {
    $Directory = $Stack.Pop()
    $Children = Get-ChildItem -LiteralPath $Directory.FullName -Force -ErrorAction SilentlyContinue
    foreach ($Child in $Children) {
      $RelativePath = $Child.FullName.Substring($Root.FullName.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
      if (Test-OceansExcludedRelativePath -RelativePath $RelativePath) {
        continue
      }

      if ($Child.PSIsContainer) {
        $Stack.Push([System.IO.DirectoryInfo]$Child.FullName)
      } else {
        $Child
      }
    }
  }
}

function Get-OceansSkillRiskNotes {
  param([Parameter(Mandatory = $true)][string] $SkillPath)

  $Risks = New-Object System.Collections.Generic.List[string]
  $SourceAbs = Resolve-Path -LiteralPath $SkillPath
  $SourcePath = [System.IO.Path]::GetFullPath($SourceAbs.Path)

  if (Test-OceansMissingLicenseReference -SkillPath $SourcePath) {
    $Risks.Add("risk: missing referenced license file")
  }

  $Files = Get-OceansIncludedSkillFiles -SkillPath $SourcePath
  foreach ($File in $Files) {
    if ($File.Length -gt 1048576) {
      if (-not $Risks.Contains("risk: file larger than 1 MB")) {
        $Risks.Add("risk: file larger than 1 MB")
      }
      continue
    }

    try {
      $Bytes = [System.IO.File]::ReadAllBytes($File.FullName)
      if ($Bytes -contains 0) {
        if (-not $Risks.Contains("risk: binary or unreadable file")) {
          $Risks.Add("risk: binary or unreadable file")
        }
        continue
      }

      $StrictUtf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false, $true
      $Content = $StrictUtf8.GetString($Bytes)
    } catch {
      if (-not $Risks.Contains("risk: binary or unreadable file")) {
        $Risks.Add("risk: binary or unreadable file")
      }
      continue
    }

    if ($Content -match $script:OceansSkillPublishSecretPattern -and -not $Risks.Contains("risk: secret-like text")) {
      $Risks.Add("risk: secret-like text")
    }

    if ($Content -cmatch $script:OceansSkillPublishLocalPathPattern -and -not $Risks.Contains("risk: local absolute path")) {
      $Risks.Add("risk: local absolute path")
    }
  }

  return $Risks
}
