# Telemetry.ps1
# Crash reporting. Nothing here is allowed to affect the run's outcome - same
# "never fatal" rule as Logging.ps1: a failing network call, a corrupt state
# file, anything, must degrade to "no report sent", not take the deployment
# down with it.
#
# Design: every fatal error is saved to a local file first, unconditionally.
# Whether it's ever sent over the network is a separate question, decided by
# asking the user right there at the moment of the crash (there is no
# start-of-run prompt and no persisted "always yes/no" answer file - see
# PRIVACY.md). To avoid nagging on a machine that keeps hitting the exact
# same bug, a signature that was just asked about backs off: it waits 5
# more occurrences before asking again, then 10, then 15, growing by 5 each
# time. A genuinely different error is always asked about immediately, since
# it isn't covered by another signature's backoff. Saying yes flushes every
# saved-but-unsent report (this signature and any others) in one batched
# request, since a request costs the same whether it carries one event or
# fifty.
#
# What gets sent, and where, is documented for the user in PRIVACY.md - keep
# that file in sync with the payload shape below if you change it.

$script:TelemetryEndpoint = 'https://telemetry.ethanantonio.com/event'
# Not a secret - it ships readable in this file and the server treats it as
# a bot-noise filter, not access control. Kept as one named constant so
# rotating it later is a one-line change.
$script:TelemetryAppToken = 'd4a3b89de27ea43910f46d61cd8759e532ce814c16d97661'
$script:TelemetryAppName = 'intune-script-wizard'
# Our payload shape's own version, independent of the wizard's release
# version. Bump this if the fields below are ever renamed or restructured,
# so old and new shapes stay distinguishable in the stored data.
$script:TelemetrySchemaVersion = '1'

# 3 seconds: long enough for a normal network call, short enough that a
# hanging/unreachable endpoint can't noticeably delay the run finishing.
$script:TelemetryTimeoutSec = 3
$script:TelemetryMaxRetries = 2
# Exponential backoff starting here, doubling each retry, plus jitter so a
# fleet of machines hitting the same outage doesn't all retry in lockstep.
$script:TelemetryRetryBaseDelaySec = 2

# Server-side limits (see the telemetry endpoint's contract). Checking these
# locally is free; a rejected request costs the same as an accepted one and
# stores nothing, so it's cheaper to never send an oversized one.
$script:TelemetryMaxEventsPerBatch = 50
$script:TelemetryMaxBatchBytes = 60000  # stays under the real 64 KiB cap with headroom
$script:TelemetryMaxSummaryBytes = 500
$script:TelemetryMaxDetailBytes = 4000
# How many unsent crash reports we'll hold onto locally. Old ones are
# dropped first - a report from months ago is less useful than a recent one,
# and this keeps the local file and the eventual batch bounded.
$script:TelemetryMaxPendingStored = 50

# Where local telemetry state (pending unsent reports + per-signature
# backoff counters) lives. $env:APPDATA only exists on Windows; the CI test
# suite and any cross-platform pwsh run fall back to a dotfile under the
# user's home folder instead.
function Get-WizardTelemetryStatePath {
    if ($IsWindows -and $env:APPDATA) {
        $dir = Join-Path $env:APPDATA 'IntuneScriptWizard'
    } else {
        $dir = Join-Path $HOME '.intune-script-wizard'
    }
    return (Join-Path $dir 'telemetry-state.json')
}

# Loads the local telemetry state, or a fresh empty one if there isn't a
# usable file yet (first run, or a corrupt file - either way, start clean
# rather than failing the crash-report path over it).
function Get-WizardTelemetryState {
    $path = Get-WizardTelemetryStatePath
    $saved = $null
    try {
        $saved = Read-WizardJsonFile -Path $path -AsHashtable
    } catch {
        Write-WizardDebug "Could not read telemetry state, starting fresh: $($_.Exception.Message)"
    }
    if ($null -eq $saved) { $saved = @{} }
    if (-not $saved.ContainsKey('signatures')) { $saved.signatures = @{} }
    if (-not $saved.ContainsKey('pending')) { $saved.pending = @() }
    return $saved
}

function Save-WizardTelemetryState {
    param([Parameter(Mandatory)][hashtable]$State)
    try {
        $path = Get-WizardTelemetryStatePath
        $dir = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
        }
        Save-WizardJsonFile -Path $path -Value $State -Depth 8
    } catch {
        # Couldn't save (read-only profile, odd permissions): this run's
        # report is still handled in memory, it just won't be remembered
        # for next time. Not fatal to the deployment either way.
        Write-WizardDebug "Could not save telemetry state: $($_.Exception.Message)"
    }
}

# A best-effort, local-only check (no network call, so it can't cost the
# telemetry endpoint's budget) so an offline machine doesn't sit through a
# timeout it was never going to win.
function Test-WizardNetworkAvailable {
    try {
        return [System.Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()
    } catch {
        # If the check itself fails, don't use that as a reason to block a
        # report that might otherwise have gone through - let the real
        # attempt find out.
        return $true
    }
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

# Cuts a string down to a byte budget measured in UTF-8, not characters - the
# server's own limits are byte-based, and non-ASCII text (accented letters,
# emoji) takes more than one byte per character.
function ConvertTo-WizardTruncatedUtf8 {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][int]$MaxBytes)

    $encoding = [System.Text.Encoding]::UTF8
    if ($encoding.GetByteCount($Text) -le $MaxBytes) { return $Text }

    $bytes = $encoding.GetBytes($Text)
    $slice = $bytes[0..($MaxBytes - 1)]
    # Decoding a byte slice that ends mid-character produces U+FFFD
    # replacement characters at the end; trim those off for a clean cut.
    $decoded = $encoding.GetString($slice).TrimEnd([char]0xFFFD)
    return "$decoded <truncated>"
}

# Strips anything that could identify the machine or its user out of a string
# before it's added to a telemetry payload, then truncates it to a byte
# budget. This is the only scrubbing that happens anywhere in the pipeline -
# the receiving Worker trusts this and does not scrub again, so any pattern
# that matters has to live here.
function Protect-WizardTelemetryPayload {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][int]$MaxBytes
    )

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

    return (ConvertTo-WizardTruncatedUtf8 -Text $result -MaxBytes $MaxBytes)
}

# Groups crashes so we don't ask about the same recurring bug every single
# time. Deliberately not the raw scrubbed text (that could still be long or
# messy) - just a short hash of exception type + error id + the start of the
# summary, stable across runs on the same machine.
function Get-WizardCrashSignature {
    param(
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ScrubbedSummary
    )

    $prefixLength = [Math]::Min(120, $ScrubbedSummary.Length)
    $basis = "$($ErrorRecord.Exception.GetType().FullName)|$($ErrorRecord.FullyQualifiedErrorId)|$($ScrubbedSummary.Substring(0, $prefixLength))"

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($basis))
    } finally {
        $sha256.Dispose()
    }
    return ([System.BitConverter]::ToString($hashBytes) -replace '-', '').Substring(0, 16).ToLowerInvariant()
}

# Decides whether this crash should trigger a consent prompt, and updates
# $State in place either way. A signature never seen before always prompts
# (that's "significantly different" from anything already being tracked). A
# known signature only prompts once it's recurred often enough: 5 more times,
# then 10 more, then 15 more, growing by 5 at each stage, so a machine stuck
# in a crash loop is asked about it occasionally rather than every run.
function Resolve-WizardCrashPromptDecision {
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Signature
    )

    if (-not $State.signatures.ContainsKey($Signature)) {
        $State.signatures[$Signature] = @{ occurrencesSincePrompt = 0; promptStage = 1 }
        return $true
    }

    $entry = $State.signatures[$Signature]
    $entry.occurrencesSincePrompt++
    $requiredGap = 5 * $entry.promptStage
    if ($entry.occurrencesSincePrompt -ge $requiredGap) {
        $entry.occurrencesSincePrompt = 0
        $entry.promptStage++
        return $true
    }
    return $false
}

# Picks the pending reports to send this time: newest first up to the
# server's per-request event cap, then trimming from the oldest end of that
# selection until the serialized batch fits the whole-request size cap too.
# Batching is all-or-nothing server-side, so it's better to send a smaller
# batch that's guaranteed to be accepted than a full one that gets rejected
# and stores nothing.
function Select-WizardTelemetryBatch {
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$PendingEntries)

    if ($PendingEntries.Count -eq 0) { return $null }

    $selected = $PendingEntries
    if ($selected.Count -gt $script:TelemetryMaxEventsPerBatch) {
        $selected = $selected[-$script:TelemetryMaxEventsPerBatch..-1]
    }

    while ($selected.Count -gt 0) {
        $payloads = @($selected | ForEach-Object { $_.Payload })
        $json = $payloads | ConvertTo-Json -Depth 6 -AsArray
        if ([System.Text.Encoding]::UTF8.GetByteCount($json) -le $script:TelemetryMaxBatchBytes) {
            return @{ Entries = $selected; Json = $json }
        }
        $selected = $selected[1..($selected.Count - 1)]
    }
    return $null
}

# Posts one already-serialized batch. Retries only on 5xx/network failures,
# never on a 4xx (the request itself would be wrong every time), and gives up
# immediately on a 429 rather than waiting out the endpoint's rate window -
# this is a best-effort background report, not worth blocking a deployment
# over.
function Send-WizardTelemetryBatch {
    param([Parameter(Mandatory)][string]$Json)

    if (-not (Test-WizardNetworkAvailable)) {
        Write-WizardDebug 'Crash report(s) not sent: no network available.'
        return $false
    }

    $headers = @{ 'X-App-Token' = $script:TelemetryAppToken }
    $attempt = 0
    while ($true) {
        try {
            Invoke-RestMethod -Uri $script:TelemetryEndpoint -Method Post -Headers $headers `
                -Body $Json -ContentType 'application/json' -TimeoutSec $script:TelemetryTimeoutSec -ErrorAction Stop | Out-Null
            return $true
        } catch {
            $statusCode = $null
            if ($_.Exception.Response) {
                try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { $statusCode = $null }
            }
            Write-WizardDebug "Crash report send failed (attempt $($attempt + 1)): $($_.Exception.Message)"

            if ($statusCode -and $statusCode -ge 400 -and $statusCode -lt 500) { return $false }
            if ($attempt -ge $script:TelemetryMaxRetries) { return $false }

            $delaySec = ($script:TelemetryRetryBaseDelaySec * [Math]::Pow(2, $attempt)) + (Get-Random -Minimum 0.0 -Maximum 1.0)
            Start-Sleep -Seconds $delaySec
            $attempt++
        }
    }
}

# Handles one fatal error end to end: save it locally (always), decide
# whether to ask about sending it (per the backoff rules above), and if the
# answer is yes, flush every saved-but-unsent report in one request. Every
# step is wrapped so nothing here can throw or change the run's exit code -
# same rule as the rest of this file.
function Send-WizardCrashReport {
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    try {
        $summary = Protect-WizardTelemetryPayload -Text (Get-WizardErrorSummary -ErrorRecord $ErrorRecord) -MaxBytes $script:TelemetryMaxSummaryBytes
        $detail = Protect-WizardTelemetryPayload -Text (Get-WizardErrorDetail -ErrorRecord $ErrorRecord) -MaxBytes $script:TelemetryMaxDetailBytes

        $payload = @{
            app        = $script:TelemetryAppName
            type       = 'crash'
            v          = $script:TelemetrySchemaVersion
            version    = $script:WizardVersion
            buildStamp = (Get-WizardBuildStamp)
            psVersion  = $PSVersionTable.PSVersion.ToString()
            os         = $PSVersionTable.OS
            summary    = $summary
            detail     = $detail
        }

        $state = Get-WizardTelemetryState

        # Always saved locally, no matter what happens next - this is the
        # one artifact that exists regardless of whether anyone ever agrees
        # to send it.
        $state.pending = @($state.pending) + @(@{ Id = [guid]::NewGuid().ToString(); Payload = $payload })
        if ($state.pending.Count -gt $script:TelemetryMaxPendingStored) {
            $state.pending = $state.pending[-$script:TelemetryMaxPendingStored..-1]
        }

        $signature = Get-WizardCrashSignature -ErrorRecord $ErrorRecord -ScrubbedSummary $summary
        $shouldPrompt = Resolve-WizardCrashPromptDecision -State $state -Signature $signature

        if (-not $shouldPrompt) {
            Save-WizardTelemetryState -State $state
            return
        }

        # An unattended run (scheduled task, CI) has nobody to answer, and
        # Read-Host against redirected input would silently return "" forever -
        # looping on that would hang the run. Skip asking; the report stays
        # saved locally and pending for the next run that can ask.
        if (-not (Test-WizardInteractive)) {
            Save-WizardTelemetryState -State $state
            return
        }

        Write-Host ''
        Write-Host 'Crash reports help one dev (me) figure out what broke without you filing a bug -' -ForegroundColor Cyan
        Write-Host 'send this one (and any others saved locally) anonymously? See PRIVACY.md for what that means.' -ForegroundColor Cyan
        $consent = $false
        while ($true) {
            $answer = (Read-Host '(y/n)').Trim().ToLowerInvariant()
            if ($answer -eq 'y' -or $answer -eq 'n') { $consent = ($answer -eq 'y'); break }
            Write-Host "Please type 'y' or 'n'." -ForegroundColor Yellow
        }

        if ($consent) {
            $batch = Select-WizardTelemetryBatch -PendingEntries $state.pending
            if ($batch -and (Send-WizardTelemetryBatch -Json $batch.Json)) {
                $sentIds = @($batch.Entries | ForEach-Object { $_.Id })
                $state.pending = @($state.pending | Where-Object { $sentIds -notcontains $_.Id })
            }
        }

        Save-WizardTelemetryState -State $state
    } catch {
        # Anything above (state file corruption, JSON errors, whatever) is
        # noted in the debug log only and never thrown - a crash report must
        # never itself become the reason the run reports a failure.
        Write-WizardDebug "Crash report not sent: $($_.Exception.Message)"
    }
}
