# Telemetry.ps1
# Opt-in crash reporting. Nothing here ever runs unless a human answered "y" at
# the consent prompt, and nothing here is allowed to affect the run's outcome -
# same "never fatal" rule as Logging.ps1: a failing network call must degrade to
# "no report sent", not take the deployment down with it.
#
# What gets sent, and where, is documented for the user in PRIVACY.md - keep
# that file in sync with the payload shape below if you change it.

$script:TelemetryEndpoint = 'https://telemetry.ethanantonio.com/event'
# 3 seconds: long enough for a normal network call, short enough that a
# hanging/unreachable endpoint can't noticeably delay the run finishing.
$script:TelemetryTimeoutSec = 3

# Where the user's one-time y/n answer is remembered, so they're only asked
# once per machine rather than on every run. $env:APPDATA only exists on
# Windows; the CI test suite and any cross-platform pwsh run fall back to a
# dotfile under the user's home folder instead.
function Get-WizardTelemetryConsentPath {
    if ($IsWindows -and $env:APPDATA) {
        $dir = Join-Path $env:APPDATA 'IntuneScriptWizard'
    } else {
        $dir = Join-Path $HOME '.intune-script-wizard'
    }
    return (Join-Path $dir 'telemetry-consent.json')
}

# Reads back a previously saved answer. Returns $null (not $true/$false) when
# nobody has answered yet, so the caller can tell "never asked" apart from "said no".
function Get-WizardTelemetryConsent {
    $path = Get-WizardTelemetryConsentPath
    # Read-WizardJsonFile (lib/Storage.ps1) already returns $null for a missing
    # or unreadable file, so a first run or a corrupt pref file both just mean
    # "ask again" rather than crashing here.
    $saved = Read-WizardJsonFile -Path $path -AsHashtable
    if ($null -eq $saved) { return $null }
    return [bool]$saved.consent
}

# Asks the y/n question once and saves the answer. Only called when
# Get-WizardTelemetryConsent returned $null.
function Request-WizardTelemetryConsent {
    # An unattended run (scheduled task, CI) has nobody to answer, and
    # Read-Host against redirected input would silently return "" forever -
    # looping on that would hang the run. Skip asking, and deliberately don't
    # persist anything, so an interactive user on the same machine still gets
    # asked next time instead of being stuck on a default nobody chose.
    if (-not (Test-WizardInteractive)) { return $false }

    Write-Host ''
    Write-Host 'Crash reports help one dev (me) figure out what broke without you filing a bug -' -ForegroundColor Cyan
    Write-Host 'send them anonymously? See PRIVACY.md for exactly what that means.' -ForegroundColor Cyan

    # Loop until we get exactly 'y' or 'n' - no blank-Enter default, so a
    # mis-hit Enter key can't silently opt someone in or out.
    while ($true) {
        $answer = (Read-Host '(y/n)').Trim().ToLowerInvariant()
        if ($answer -eq 'y' -or $answer -eq 'n') { break }
        Write-Host "Please type 'y' or 'n'." -ForegroundColor Yellow
    }

    $consent = ($answer -eq 'y')
    try {
        $path = Get-WizardTelemetryConsentPath
        $dir = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
        }
        Save-WizardJsonFile -Path $path -Value @{ consent = $consent; answeredAt = (Get-Date).ToString('o') }
    } catch {
        # Couldn't save the preference (read-only profile, odd permissions):
        # honour the answer for this run anyway, just re-ask next time.
        Write-WizardDebug "Could not save telemetry preference: $($_.Exception.Message)"
    }
    return $consent
}

# One [regex pattern, replacement] pair per line. Kept as a single list so new
# patterns can be added here without touching anything that calls this function.
$script:TelemetryScrubPatterns = @(
    # IPv4 and IPv6 addresses.
    @('\b\d{1,3}(\.\d{1,3}){3}\b', '<ip>'),
    @('\b([0-9a-fA-F]{1,4}:){2,7}[0-9a-fA-F]{1,4}\b', '<ip>'),
    # Windows per-user paths and UNC shares, e.g. C:\Users\jsmith\... or \\server\share.
    @('[A-Za-z]:\\Users\\[^\\]+', '<path>'),
    @('\\\\[^\\]+\\', '<path>\\'),
    # Email addresses.
    @('[\w.+-]+@[\w-]+\.[\w.-]+', '<email>'),
    # GUIDs - Graph error bodies are full of tenant/object IDs, which are
    # effectively customer-identifying.
    @('\b[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\b', '<guid>'),
    # Bearer tokens and JWTs.
    @('Bearer\s+[A-Za-z0-9\-_.]+', 'Bearer <token>'),
    @('eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+', '<token>'),
    # password=..., client_secret=..., apikey=..., Pwd=... style key/value pairs -
    # keep the key so the report still says *what* leaked a secret, drop the value.
    @('(?i)(password|client_secret|apikey|api_key|pwd|secret)\s*[=:]\s*\S+', '$1=<redacted>')
)

# Hard cap so one runaway field (a giant stack trace, an accidentally embedded
# file dump) can't blow up the request size or the receiving Worker's storage cost.
$script:TelemetryMaxFieldLength = 2000

# Strips anything that could identify the machine or its user out of a string
# before it's added to a telemetry payload. This is the only scrubbing that
# happens anywhere in the pipeline - the receiving Worker trusts this and does
# not scrub again, so any pattern that matters has to live here.
function Protect-WizardTelemetryPayload {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $result = $Text
    # Exact, cheap substitutions first: the current machine's own identifiers,
    # not just a pattern that might coincidentally match them.
    $literals = @(
        @($env:USERNAME, '<user>'),
        @($env:USERPROFILE, '<home>'),
        @($env:COMPUTERNAME, '<hostname>'),
        @($env:USERDOMAIN, '<domain>'),
        @($HOME, '<home>')
    )
    foreach ($pair in $literals) {
        $value = $pair[0]
        if ([string]::IsNullOrEmpty($value)) { continue }
        $result = $result.Replace($value, $pair[1])
    }

    foreach ($pair in $script:TelemetryScrubPatterns) {
        $result = [regex]::Replace($result, $pair[0], $pair[1])
    }

    if ($result.Length -gt $script:TelemetryMaxFieldLength) {
        $result = $result.Substring(0, $script:TelemetryMaxFieldLength) + ' <truncated>'
    }
    return $result
}

# Sends one crash report. Called only when the user has opted in. Every string
# field is scrubbed before it's added to the payload; failures are logged to
# the debug log only and never thrown, so this can never change $exitCode.
function Send-WizardCrashReport {
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    try {
        $payload = @{
            app        = 'intune-script-wizard'
            type       = 'crash'
            version    = $script:WizardVersion
            buildStamp = (Get-WizardBuildStamp)
            psVersion  = $PSVersionTable.PSVersion.ToString()
            os         = $PSVersionTable.OS
            summary    = Protect-WizardTelemetryPayload -Text (Get-WizardErrorSummary -ErrorRecord $ErrorRecord)
            detail     = Protect-WizardTelemetryPayload -Text (Get-WizardErrorDetail -ErrorRecord $ErrorRecord)
        }
        Invoke-RestMethod -Uri $script:TelemetryEndpoint -Method Post `
            -Body ($payload | ConvertTo-Json -Depth 5) -ContentType 'application/json' `
            -TimeoutSec $script:TelemetryTimeoutSec -ErrorAction Stop | Out-Null
    } catch {
        # Unreachable endpoint, timeout, TLS issue - none of it matters to the
        # deployment that just happened. Note it in the debug log and move on.
        Write-WizardDebug "Crash report not sent: $($_.Exception.Message)"
    }
}
