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
$script:WizardVersion = '1.13.3'

$script:DebugToConsole = $false
$script:DebugToFile    = $false
$script:DebugFilePath  = $null
# Set once the log file has proved unwritable, so a broken log warns exactly
# once instead of on every line for the rest of the run.
$script:DebugFileBroken = $false

# The "script:" prefix above makes these variables script-scoped: they live for
# as long as this .ps1 file is loaded and can be read/written by any function
# defined in it (like a shared setting), instead of disappearing when a
# function returns the way an ordinary local variable would.

# Reports the tool's version, optionally with a git commit hash, for debug logs.
function Get-WizardBuildStamp {
    # Version plus the short commit hash when the tool is running from a git
    # checkout, e.g. "1.3.0+5571aff" or "1.3.0+nogit" for a copied-out folder.
    $suffix = 'nogit'
    # try/catch: run the risky code in "try", and if it throws an error, jump
    # to "catch" instead of crashing the whole script. Here, any failure just
    # means git isn't available, so we quietly keep the 'nogit' default.
    try {
        $root = Split-Path -Parent $PSScriptRoot
        # $LASTEXITCODE is cleared first: if git is missing, the call below
        # throws before setting it, and a stale value from an earlier native
        # command would otherwise be read as success.
        $global:LASTEXITCODE = 0
        # The "&" is PowerShell's call operator, used here to run the external
        # git.exe program and capture what it prints as text.
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

# Turns debug logging on/off and picks console, file, or both, based on $Mode.
# Call this once near the start of a run before any Write-WizardDebug calls.
function Initialize-WizardLogging {
    # A param() block declares this function's inputs. Each one below becomes
    # a variable ($Mode, $LogRoot) usable inside the function body.
    param(
        # [ValidateSet(...)] restricts $Mode to exactly these four strings;
        # PowerShell rejects the call up front if anything else is passed.
        [ValidateSet('None', 'Console', 'File', 'Both')]
        [string]$Mode = 'None',
        # Where a logs/ folder is created when file logging is requested.
        [string]$LogRoot
    )

    # "-in @(...)" checks whether $Mode is one of the values in that array
    # (a comma-free list written with @() ), giving a true/false result.
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

# Writes one debug line to the console and/or log file, depending on what
# Initialize-WizardLogging turned on. This is the function the rest of the
# tool calls whenever it wants to trace what it's doing.
function Write-WizardDebug {
    # [Parameter(Mandatory)] means the caller must supply -Message or
    # PowerShell stops and prompts/errors instead of running with it blank.
    # [AllowEmptyString()] still permits an empty "" string, just not a
    # missing one entirely.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message)

    # Bail out early (do nothing) if neither console nor file logging is on,
    # so callers can call this freely without checking themselves every time.
    if (-not ($script:DebugToConsole -or $script:DebugToFile)) { return }

    # Multi-line messages (an error detail block) get one timestamp per line so
    # the log stays greppable.
    $stamp = (Get-Date).ToString('HH:mm:ss.fff')
    # -split breaks the message into an array of lines on any line-ending
    # style (`r`n is Windows-style CRLF, written as a backtick-escaped
    # sequence). The pipe "|" then feeds each line into ForEach-Object, which
    # runs its script block once per item; inside that block, $_ refers to
    # the current item being processed.
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

# Returns true if either console or file debug logging is currently active.
function Test-WizardDebugEnabled {
    # Lets callers skip building an expensive debug string when nothing consumes it.
    return ($script:DebugToConsole -or $script:DebugToFile)
}

# Returns the current debug log file's path (or $null if file logging is off).
function Get-WizardLogPath {
    return $script:DebugFilePath
}

# Writes a final "run finished" line and, if logging to a file, prints its
# path so the user knows where to look afterward.
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
