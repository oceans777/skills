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

function Test-OceansExcludedRelativePath {
  param([Parameter(Mandatory = $true)][string] $RelativePath)

  foreach ($Part in ($RelativePath -split '[\\/]')) {
    if ($script:OceansSkillPublishExcludedNames -contains $Part) {
      return $true
    }
  }

  return $false
}

function Get-OceansSkillRiskNotes {
  param([Parameter(Mandatory = $true)][string] $SkillPath)

  $Risks = New-Object System.Collections.Generic.List[string]
  $SourceAbs = Resolve-Path -LiteralPath $SkillPath
  $SourcePath = [System.IO.Path]::GetFullPath($SourceAbs.Path)

  $Files = Get-ChildItem -LiteralPath $SourcePath -File -Recurse -Force -ErrorAction SilentlyContinue
  foreach ($File in $Files) {
    $RelativePath = $File.FullName.Substring($SourcePath.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    if (Test-OceansExcludedRelativePath -RelativePath $RelativePath) {
      continue
    }

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
