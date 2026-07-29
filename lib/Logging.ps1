# Logging.ps1
# Toggleable debug tracing. Off by default so normal runs stay quiet; when it is
# on it records every Graph URL and request body, which is what you actually need
# when the service answers an assignment call with a bare 400.
#
# Nothing in here is allowed to abort a run. Logging failing (full disk,
# read-only folder) must degrade to "no log" rather than take the deployment
# down with it, so every write is best-effort.

# Bump this by hand on release; /release keeps it in step with the git tag.
# Shown whenever debug logging is enabled so a pasted log can be tied back to an
# exact build.
$script:WizardVersion = '1.3.0'

$script:DebugToConsole = $false
$script:DebugToFile    = $false
$script:DebugFilePath  = $null
# Set once the log file has proved unwritable, so a broken log warns exactly
# once instead of on every line for the rest of the run.
$script:DebugFileBroken = $false

function Get-WizardBuildStamp {
    # Version plus the short commit hash when the tool is running from a git
    # checkout, e.g. "1.3.0+5571aff" or "1.3.0+nogit" for a copied-out folder.
    $suffix = 'nogit'
    try {
        $root = Split-Path -Parent $PSScriptRoot
        # $LASTEXITCODE is cleared first: if git is missing, the call below
        # throws before setting it, and a stale value from an earlier native
        # command would otherwise be read as success.
        $global:LASTEXITCODE = 0
        $hash = & git -C $root rev-parse --short HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $hash) {
            $suffix = "$hash".Trim()
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

    $script:DebugToConsole  = $Mode -in @('Console', 'Both')
    $script:DebugToFile     = $Mode -in @('File', 'Both')
    $script:DebugFileBroken = $false

    if (-not ($script:DebugToConsole -or $script:DebugToFile)) { return }

    if ($script:DebugToFile) {
        # A read-only or full -Path must not stop a deployment that needs no
        # local writes at all, so fall back to console tracing instead.
        try {
            $logDir = Join-Path $LogRoot 'logs'
            if (-not (Test-Path -LiteralPath $logDir)) {
                New-Item -ItemType Directory -Path $logDir -Force -ErrorAction Stop | Out-Null
            }
            $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
            $script:DebugFilePath = Join-Path $logDir "wizard-$stamp.log"
            # Prove it is writable now rather than discovering it mid-run.
            Set-Content -LiteralPath $script:DebugFilePath -Value '' -ErrorAction Stop
        } catch {
            Write-Warning "Could not open a debug log under '$LogRoot': $($_.Exception.Message). Falling back to console tracing."
            $script:DebugToFile    = $false
            $script:DebugFilePath  = $null
            $script:DebugToConsole = $true
        }
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

    # Multi-line messages (an error detail block) get one timestamp per line so
    # the log stays greppable.
    $stamp = (Get-Date).ToString('HH:mm:ss.fff')
    $lines = @($Message -split "`r?`n" | ForEach-Object { "[$stamp] $_" })

    if ($script:DebugToConsole) {
        foreach ($line in $lines) { Write-Host $line -ForegroundColor DarkGray }
    }
    if ($script:DebugToFile -and $script:DebugFilePath -and -not $script:DebugFileBroken) {
        try {
            Add-Content -LiteralPath $script:DebugFilePath -Value $lines -ErrorAction Stop
        } catch {
            # Warn once, then stop trying: a failing log must not turn into a
            # failing deployment, and must not spam one warning per traced call.
            $script:DebugFileBroken = $true
            Write-Warning "Debug log '$script:DebugFilePath' became unwritable ($($_.Exception.Message)); continuing without file logging."
        }
    }
}

function Test-WizardDebugEnabled {
    # Lets callers skip building an expensive debug string when nothing consumes it.
    return ($script:DebugToConsole -or $script:DebugToFile)
}

function Get-WizardLogPath {
    return $script:DebugFilePath
}

function Close-WizardLogging {
    # Called from the wizard's outermost finally, including on a fatal error, so
    # the log path is the last thing on screen when someone needs to go read it.
    param([int]$ExitCode = 0)

    if (-not (Test-WizardDebugEnabled)) { return }
    Write-WizardDebug "Run finished with exit code $ExitCode"
    if ($script:DebugToFile -and $script:DebugFilePath -and -not $script:DebugFileBroken) {
        Write-Host "Debug log: $script:DebugFilePath" -ForegroundColor DarkGray
    }
}
