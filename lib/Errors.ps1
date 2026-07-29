# Errors.ps1
# Turning exceptions into something a human can act on, and into a process exit
# code a scheduler can act on. Every fatal path in the wizard ends up here.

# Exit codes. Kept as variables rather than bare numbers so the meaning is
# greppable, and documented in the wizard's comment-based help.
#   0 - everything the run set out to do succeeded
#   1 - fatal: the run stopped early (bad arguments, auth, a failed pre-flight,
#       or -StopOnError tripping on the first script failure)
#   2 - the run finished, but one or more individual scripts failed
$script:WizardExitOk      = 0
$script:WizardExitFatal   = 1
$script:WizardExitPartial = 2

function Get-WizardErrorSummary {
    # One line describing what actually went wrong.
    #
    # Graph puts its real reason in the HTTP response body, which PowerShell
    # parks in ErrorDetails.Message rather than in the exception message. Without
    # digging it out, every rejected request reads as the useless "Response
    # status code does not indicate success: 400 (Bad Request)".
    # The body shape is documented at
    # https://learn.microsoft.com/en-us/graph/errors
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    $details = $ErrorRecord.ErrorDetails.Message
    if ($details) {
        try {
            $parsed = $details | ConvertFrom-Json -ErrorAction Stop
            if ($parsed.error) {
                $parts = @($parsed.error.code, $parsed.error.message) | Where-Object { $_ }
                if ($parts.Count -gt 0) { return ($parts -join ': ') }
            }
        } catch {
            # Not JSON (an HTML error page, a proxy banner): use it verbatim.
        }
        return $details.Trim()
    }

    $message = $ErrorRecord.Exception.Message
    if ([string]::IsNullOrWhiteSpace($message)) { return $ErrorRecord.ToString() }
    return $message
}

function Get-WizardErrorDetail {
    # The full picture, for the debug log rather than the console: exception
    # type, the line that threw, and the call stack. This is what makes a pasted
    # log usable without asking the reporter to reproduce the failure.
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    $lines = @(
        "Summary   : $(Get-WizardErrorSummary -ErrorRecord $ErrorRecord)"
        "Exception : $($ErrorRecord.Exception.GetType().FullName)"
        "Message   : $($ErrorRecord.Exception.Message)"
        "Category  : $($ErrorRecord.CategoryInfo.Category) / $($ErrorRecord.FullyQualifiedErrorId)"
        "At        : $($ErrorRecord.InvocationInfo.ScriptName):$($ErrorRecord.InvocationInfo.ScriptLineNumber)"
    )

    $inner = $ErrorRecord.Exception.InnerException
    $depth = 0
    # Bounded: a malformed exception chain must not turn error reporting into
    # the thing that hangs the run.
    while ($inner -and $depth -lt 5) {
        $lines += "Inner[$depth]  : $($inner.GetType().FullName): $($inner.Message)"
        $inner = $inner.InnerException
        $depth++
    }

    if ($ErrorRecord.ScriptStackTrace) {
        $lines += 'Stack     :'
        $lines += ($ErrorRecord.ScriptStackTrace -split "`r?`n" | ForEach-Object { "  $_" })
    }
    return ($lines -join [Environment]::NewLine)
}

function Write-WizardFailure {
    # A non-fatal failure: reported on the console in one line, recorded in the
    # debug log in full. Used for per-script failures, which the run continues past.
    param(
        [Parameter(Mandatory)][string]$Context,
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord,
        # Extra lines the caller wants shown with the error, e.g. the path of a
        # backup taken just before the failing update.
        [string[]]$Hint = @()
    )

    $summary = Get-WizardErrorSummary -ErrorRecord $ErrorRecord
    Write-Host "  ERROR: $Context" -ForegroundColor Red
    Write-Host "         $summary" -ForegroundColor Red
    foreach ($line in $Hint) { Write-Host "         $line" -ForegroundColor Yellow }

    Write-WizardDebug "FAILURE: $Context"
    Write-WizardDebug (Get-WizardErrorDetail -ErrorRecord $ErrorRecord)
    return $summary
}

function Write-WizardFatal {
    # The end of the line: the run cannot continue. Prints to stderr as well as
    # the host so a caller that only captures stderr still sees why it died.
    param(
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord,
        [string]$Context = 'The run stopped.'
    )

    $summary = Get-WizardErrorSummary -ErrorRecord $ErrorRecord

    Write-Host ''
    Write-Host "FATAL: $Context" -ForegroundColor Red
    Write-Host "  $summary" -ForegroundColor Red

    # Write-WizardDebug is a no-op when logging is off, so point the user at the
    # switch that would have captured the detail they are about to be asked for.
    if (Test-WizardDebugEnabled) {
        Write-WizardDebug 'FATAL:'
        Write-WizardDebug (Get-WizardErrorDetail -ErrorRecord $ErrorRecord)
        Write-Host '  Full detail written to the debug log.' -ForegroundColor DarkGray
    } else {
        Write-Host '  Re-run with -DebugLog File for the full trace.' -ForegroundColor DarkGray
    }

    # $Host.UI is used directly: Write-Error here would add its own record to the
    # stream and, under $ErrorActionPreference = 'Stop', throw from the handler.
    [Console]::Error.WriteLine("intune-script-wizard: $summary")
}
