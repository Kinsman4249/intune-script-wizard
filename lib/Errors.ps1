# Errors.ps1
# Turning exceptions into something a human can act on, and into a process exit
# code a scheduler can act on. Every fatal path in the wizard ends up here.

# Exit codes. Kept as variables rather than bare numbers so the meaning is
# greppable, and documented in the wizard's comment-based help.
#   0 - everything the run set out to do succeeded
#   1 - fatal: the run stopped early (bad arguments, auth, a failed pre-flight,
#       or -StopOnError tripping on the first script failure)
#   2 - the run finished, but one or more individual scripts failed
# $script: means these variables live in this file's module scope, so any
# function below (or in another file that dot-sources this one) can read them.
$script:WizardExitOk      = 0
$script:WizardExitFatal   = 1
$script:WizardExitPartial = 2

# Pulls a one-line, human-readable reason out of a caught error.
function Get-WizardErrorSummary {
    # One line describing what actually went wrong.
    #
    # Graph puts its real reason in the HTTP response body, which PowerShell
    # parks in ErrorDetails.Message rather than in the exception message. Without
    # digging it out, every rejected request reads as the useless "Response
    # status code does not indicate success: 400 (Bad Request)".
    # The body shape is documented at
    # https://learn.microsoft.com/en-us/graph/errors
    # param() declares this function's inputs. [Parameter(Mandatory)] means
    # PowerShell will refuse to run the function until the caller supplies
    # -ErrorRecord; the type in brackets restricts it to a real caught error object.
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    $details = $ErrorRecord.ErrorDetails.Message
    if ($details) {
        # try/catch: run the risky code in try, and if it throws an exception,
        # jump to catch instead of crashing the whole function.
        try {
            # Pipe (|) sends the JSON text on the left into ConvertFrom-Json on the
            # right, turning it into a PowerShell object we can dot into (.error).
            $parsed = $details | ConvertFrom-Json -ErrorAction Stop
            if ($parsed.error) {
                # Build an array of the code/message fields, then filter out any
                # that are empty. $_ inside the Where-Object script block means
                # "the current item being tested".
                $parts = @($parsed.error.code, $parsed.error.message) | Where-Object { $_ }
                if ($parts.Count -gt 0) { return ($parts -join ': ') }
            }
        } catch {
            # Not JSON (an HTML error page, a proxy banner): use it verbatim.
        }
        return $details.Trim()
    }

    $message = $ErrorRecord.Exception.Message
    # [string]::IsNullOrWhiteSpace checks for empty, blank, or whitespace-only text.
    if ([string]::IsNullOrWhiteSpace($message)) { return $ErrorRecord.ToString() }
    return $message
}

# Builds a multi-line, detailed report of an error, meant for the debug log
# (not the console) so a bug report has everything needed to diagnose it.
function Get-WizardErrorDetail {
    # The full picture, for the debug log rather than the console: exception
    # type, the line that threw, and the call stack. This is what makes a pasted
    # log usable without asking the reporter to reproduce the failure.
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    # @( ... ) is an array literal; each line here becomes one element of $lines.
    # "$(...)" inside a string runs the code inside and inserts its result as text.
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
    # while loops keep running as long as the condition is true; here it walks
    # the chain of "inner" exceptions (an exception caused by another exception).
    while ($inner -and $depth -lt 5) {
        $lines += "Inner[$depth]  : $($inner.GetType().FullName): $($inner.Message)"
        $inner = $inner.InnerException
        $depth++
    }

    if ($ErrorRecord.ScriptStackTrace) {
        $lines += 'Stack     :'
        # -split breaks the stack trace text into separate lines on any newline,
        # then ForEach-Object indents each one with $_ standing for that line.
        $lines += ($ErrorRecord.ScriptStackTrace -split "`r?`n" | ForEach-Object { "  $_" })
    }
    # -join glues the array of lines back into one string, using the OS's
    # native newline character between each one.
    return ($lines -join [Environment]::NewLine)
}

# Reports a failure that does NOT stop the run (e.g. one script in a batch
# failed but others can still be tried).
function Write-WizardFailure {
    # A non-fatal failure: reported on the console in one line, recorded in the
    # debug log in full. Used for per-script failures, which the run continues past.
    param(
        [Parameter(Mandatory)][string]$Context,
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord,
        # Extra lines the caller wants shown with the error, e.g. the path of a
        # backup taken just before the failing update.
        # [string[]] means an array of strings; = @() gives it a default of "no lines".
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

# Reports a failure that DOES stop the run, right before the wizard exits.
function Write-WizardFatal {
    # The end of the line: the run cannot continue. Prints to stderr as well as
    # the host so a caller that only captures stderr still sees why it died.
    param(
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord,
        # Giving a parameter "= 'default text'" makes it optional; callers can
        # skip -Context and this value is used instead.
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

    # Always saves the crash locally and decides for itself (per-crash prompt,
    # with backoff on repeats) whether to also ask about sending it - see
    # lib/Telemetry.ps1. There is no separate opt-in flag to check here.
    Send-WizardCrashReport -ErrorRecord $ErrorRecord
}
