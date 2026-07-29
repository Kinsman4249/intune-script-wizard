# Logging.ps1
# Toggleable debug tracing. Off by default so normal runs stay quiet; when it is
# on it records every Graph URL and request body, which is what you actually need
# when the service answers an assignment call with a bare 400.

# Bump this by hand on release. Shown whenever debug logging is enabled so a
# pasted log can be tied back to an exact build.
$script:WizardVersion = '0.2.0'

$script:DebugToConsole = $false
$script:DebugToFile    = $false
$script:DebugFilePath  = $null

function Get-WizardBuildStamp {
    # Version plus the short commit hash when the tool is running from a git
    # checkout, e.g. "0.2.0+5571aff" or "0.2.0+nogit" for a copied-out folder.
    $suffix = 'nogit'
    try {
        $root = Split-Path -Parent $PSScriptRoot
        $hash = & git -C $root rev-parse --short HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $hash) {
            $suffix = $hash.Trim()
            # Mark the build dirty if tracked files differ from the commit.
            $dirty = & git -C $root status --porcelain 2>$null
            if ($LASTEXITCODE -eq 0 -and $dirty) { $suffix += '-dirty' }
        }
    } catch {
        # git missing or not a repo: fall through to 'nogit'.
    }
    return "$script:WizardVersion+$suffix"
}

function Initialize-WizardLogging {
    param(
        [ValidateSet('None', 'Console', 'File', 'Both')]
        [string]$Mode = 'None',
        # Where a logs/ folder is created when file logging is requested.
        [string]$LogRoot
    )

    $script:DebugToConsole = $Mode -in @('Console', 'Both')
    $script:DebugToFile    = $Mode -in @('File', 'Both')

    if (-not ($script:DebugToConsole -or $script:DebugToFile)) { return }

    if ($script:DebugToFile) {
        $logDir = Join-Path $LogRoot 'logs'
        if (-not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $script:DebugFilePath = Join-Path $logDir "wizard-$stamp.log"
    }

    $build = Get-WizardBuildStamp
    Write-WizardDebug "Intune Script Wizard build $build"
    Write-WizardDebug "PowerShell $($PSVersionTable.PSVersion) on $($PSVersionTable.Platform)"
    if ($script:DebugToFile) {
        Write-Host "Debug log: $script:DebugFilePath (build $build)" -ForegroundColor DarkGray
    } else {
        Write-Host "Debug logging on (build $build)" -ForegroundColor DarkGray
    }
}

function Write-WizardDebug {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message)

    if (-not ($script:DebugToConsole -or $script:DebugToFile)) { return }

    $line = "[{0}] {1}" -f (Get-Date).ToString('HH:mm:ss.fff'), $Message
    if ($script:DebugToConsole) { Write-Host $line -ForegroundColor DarkGray }
    if ($script:DebugToFile -and $script:DebugFilePath) {
        Add-Content -LiteralPath $script:DebugFilePath -Value $line
    }
}

function Test-WizardDebugEnabled {
    # Lets callers skip building an expensive debug string when nothing consumes it.
    return ($script:DebugToConsole -or $script:DebugToFile)
}
