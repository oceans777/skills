$ErrorActionPreference = "Stop"

function Format-GitCommand {
  param(
    [Parameter(Mandatory = $true)]
    [string[]] $Arguments
  )

  return "git $($Arguments -join ' ')"
}

function Invoke-Git {
  param(
    [Parameter(Mandatory = $true)]
    [string] $Description,

    [Parameter(Mandatory = $true)]
    [string[]] $Arguments
  )

  & git @Arguments
  $exitCode = $LASTEXITCODE
  if ($exitCode -ne 0) {
    throw "$Description failed: $(Format-GitCommand -Arguments $Arguments) exited with code $exitCode."
  }
}

function Invoke-GitWithRetry {
  param(
    [Parameter(Mandatory = $true)]
    [string] $Description,

    [Parameter(Mandatory = $true)]
    [string[]] $Arguments,

    [ValidateRange(1, 10)]
    [int] $Attempts = 3,

    [ValidateRange(0, 300)]
    [int] $DelaySeconds = 5
  )

  $lastNativeExitCode = 0

  for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
    & git @Arguments
    $lastNativeExitCode = $LASTEXITCODE
    if ($lastNativeExitCode -eq 0) {
      return
    }

    if ($attempt -lt $Attempts) {
      Write-Warning "$Description failed with exit code $lastNativeExitCode. Retrying in $DelaySeconds seconds ($attempt/$Attempts)..."
      Start-Sleep -Seconds $DelaySeconds
    }
  }

  throw "$Description failed after $Attempts attempts. Last command: $(Format-GitCommand -Arguments $Arguments). Last exit code: $lastNativeExitCode. Check network and GitHub access, then rerun the same oceans777 command."
}
