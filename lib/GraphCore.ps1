# GraphCore.ps1
# The foundation every other Graph-touching file builds on: normalising the
# script content the SDK hands back, and the throttling/transient-failure retry
# that wraps every single Graph call. Auth, groups, assignments and script
# create/update live in their own files (GraphAuth.ps1, Assignments.ps1,
# GraphOps.ps1) so this one stays small and dependency-free.

# Normalises whatever the SDK hands back for a script's scriptContent into raw
# bytes. Every caller that reads content off an existing script goes through
# here, because getting this wrong is silent rather than loud:
#
# scriptContent is Edm.Binary on the wire (base64 text), but the SDK model
# deserialises it straight to a byte[]. Passing a byte[] to
# FromBase64String(string) does not raise a type error - PowerShell coerces the
# array into a space-separated string of numbers first, which then fails to
# parse as base64. The mirror-image trap is [string]::IsNullOrWhiteSpace() on a
# byte[], which is never true for non-empty content, so an "is it empty?" guard
# written that way silently passes an array straight through to be stored as
# JSON numbers instead of base64.
#
# Returns $null when there is no usable content, so callers decide whether that
# is a warning or a hard stop. Accepts a base64 string too, which is what
# restore-from-disk and the offline test stubs supply.
#
# Every return of the array uses the unary comma (',$bytes'). PowerShell
# otherwise enumerates a returned array onto the pipeline, which re-collects as
# Object[] - and collapses to a single [byte] for one-byte content, where
# ToBase64String/WriteAllBytes then find no matching overload. The comma hands
# back the byte[] itself, intact.
function Get-WizardScriptContentBytes {
    param([Parameter(Mandatory)][AllowNull()]$Content)

    if ($null -eq $Content) { return $null }
    if ($Content -is [byte[]]) {
        if ($Content.Length -eq 0) { return $null }
        return ,$Content
    }

    # A backup written before the byte[] handling above was fixed stored the
    # content as a JSON array of numbers rather than base64 text, and comes back
    # off disk as an object array. Those files are perfectly recoverable - the
    # bytes are all there, just spelled differently - so read them rather than
    # making the operator hand-repair a backup to restore it.
    if ($Content -isnot [string] -and $Content -is [System.Collections.IEnumerable]) {
        $numbers = @($Content)
        if ($numbers.Count -eq 0) { return $null }
        $bytes = [byte[]]::new($numbers.Count)
        for ($i = 0; $i -lt $numbers.Count; $i++) {
            # Anything outside 0-255 is not a byte array that lost its encoding,
            # it is some other structure entirely - let the caller's own base64
            # error describe it rather than silently truncating values.
            $value = $numbers[$i] -as [int]
            if ($null -eq $value -or $value -lt 0 -or $value -gt 255) { return $null }
            $bytes[$i] = [byte]$value
        }
        return ,$bytes
    }

    $text = [string]$Content
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    # Deliberately not wrapped in try/catch: a string that is not valid base64
    # is a genuine error and each caller already has its own message for it.
    $bytes = [System.Convert]::FromBase64String($text)
    if ($bytes.Length -eq 0) { return $null }
    return ,$bytes
}

# --- Throttling and transient failures ---------------------------------------
#
# Graph throttles. A tenant with a few hundred scripts, or a -RestoreAll over a
# folder of backups, will meet a 429 sooner or later, and without a retry that
# lands as a hard failure part-way through a run.
#
# Only 429 (throttled) and 503 (service unavailable) are retried, because both
# mean the request was turned away WITHOUT being processed - so replaying it
# cannot create a second copy of anything. A 504 is deliberately not retried:
# a gateway timeout means the answer was lost, not that the request was, and
# re-sending a create after one is how a tenant ends up with two scripts.
$script:RetryStatusCodes = @(429, 503)

# Total attempts, i.e. the first try plus four retries.
$script:RetryMaxAttempts = 5

# Each wait is doubled from this, and Retry-After overrides it when the service
# says how long to wait. The environment variable exists so the offline test
# suite can exercise the retry path without actually sleeping through it;
# nothing in normal use sets it.
$script:RetryBaseSeconds = if ($env:WIZARD_RETRY_BASE_SECONDS) { [double]$env:WIZARD_RETRY_BASE_SECONDS } else { 2 }

# However long the service asks for, stop waiting at this. An unattended run
# that sits blocked for an hour on one call is not better than one that fails.
$script:RetryMaxDelaySeconds = 120

function Read-WizardRetryAfterHeader {
    # Pulls Retry-After out of one header collection, in whichever of the two
    # shapes it arrives in: the typed RetryConditionHeaderValue that
    # HttpResponseHeaders exposes, or a plain dictionary of raw strings.
    # Returns $null when it isn't there. Never throws - a missing header just
    # means falling back to the calculated delay.
    param([Parameter(Mandatory)][AllowNull()]$Headers)

    if ($null -eq $Headers) { return $null }
    try {
        $retryAfter = $Headers.PSObject.Properties['RetryAfter']
        if ($retryAfter -and $retryAfter.Value) {
            $delta = $retryAfter.Value.PSObject.Properties['Delta']
            if ($delta -and $delta.Value) { return [double]$delta.Value.TotalSeconds }
        }

        $values = $null
        if ($Headers -is [System.Collections.IDictionary]) {
            foreach ($key in $Headers.Keys) {
                # -ieq is an explicitly case-insensitive comparison; HTTP header
                # names are case-insensitive and arrive spelled either way.
                if ([string]$key -ieq 'Retry-After') { $values = $Headers[$key]; break }
            }
        } elseif ($Headers.PSObject.Methods['TryGetValues']) {
            $out = $null
            if ($Headers.TryGetValues('Retry-After', [ref]$out)) { $values = $out }
        }

        if ($values) {
            $seconds = 0.0
            if ([double]::TryParse([string](@($values)[0]), [ref]$seconds)) { return $seconds }
        }
    } catch {
        # Any surprise in the header shape falls through to the calculated
        # backoff, which is always a safe answer.
    }
    return $null
}

function Get-WizardRetryAfterSeconds {
    # Walks a caught failure looking for the service's own Retry-After.
    param([Parameter(Mandatory)][AllowNull()]$ErrorRecord)

    if (-not $ErrorRecord) { return $null }
    $exception = $ErrorRecord.Exception
    $depth = 0
    while ($exception -and $depth -lt 5) {
        foreach ($name in @('ResponseHeaders', 'Headers')) {
            $property = $exception.PSObject.Properties[$name]
            if ($property -and $property.Value) {
                $seconds = Read-WizardRetryAfterHeader -Headers $property.Value
                if ($null -ne $seconds) { return $seconds }
            }
        }
        $response = $exception.PSObject.Properties['Response']
        if ($response -and $response.Value) {
            $headers = $response.Value.PSObject.Properties['Headers']
            if ($headers -and $headers.Value) {
                $seconds = Read-WizardRetryAfterHeader -Headers $headers.Value
                if ($null -ne $seconds) { return $seconds }
            }
        }
        $exception = $exception.InnerException
        $depth++
    }
    return $null
}

function Test-WizardRetryableFailure {
    # True when a failure is worth trying again: throttling, or the service
    # saying it is unavailable. Anything the status can be read from and isn't
    # one of those is answered NO immediately - a 400 or a 403 will fail the
    # same way however many times it is sent.
    param([Parameter(Mandatory)][AllowNull()]$ErrorRecord)

    if (-not $ErrorRecord) { return $false }

    $status = Get-WizardGraphStatusCode -ErrorRecord $ErrorRecord
    if ($null -ne $status) { return ($status -in $script:RetryStatusCodes) }

    # No status to read, so match the text narrowly. As with the not-found
    # check, the default when this cannot be answered is "no", because retrying
    # a request that was actually rejected just delays a failure.
    $text = "$($ErrorRecord.Exception.Message) $($ErrorRecord.ErrorDetails.Message)"
    return ($text -match '(?i)(^|\W)(429|503)(\W|$)|too\s*many\s*requests|service\s*unavailable|throttl')
}

function Get-WizardRetryDelaySeconds {
    # How long to wait before attempt N+1. The service's own Retry-After wins
    # when it sent one; otherwise back off exponentially from the base.
    param(
        [Parameter(Mandatory)][AllowNull()]$ErrorRecord,
        [Parameter(Mandatory)][int]$Attempt
    )

    $delay = Get-WizardRetryAfterSeconds -ErrorRecord $ErrorRecord
    if ($null -eq $delay -or $delay -le 0) {
        # 2s, 4s, 8s, 16s with the default base. [Math]::Pow is exponentiation.
        $delay = $script:RetryBaseSeconds * [Math]::Pow(2, $Attempt - 1)
    }
    if ($delay -gt $script:RetryMaxDelaySeconds) { $delay = $script:RetryMaxDelaySeconds }
    return $delay
}

function Invoke-WizardGraphRetry {
    # Runs one Graph call, retrying it while the tenant is throttling or
    # unavailable. Everything that talks to Graph goes through here.
    param(
        # The call itself, as a scriptblock: '& $Call' runs it, and its result
        # is handed straight back to this function's caller.
        [Parameter(Mandatory)][scriptblock]$Call,
        # Named in the "retrying" message, e.g. "Reading script abc123".
        [Parameter(Mandatory)][string]$What
    )

    $attempt = 1
    while ($true) {
        Write-WizardDebug "$What : sending (attempt $attempt of $script:RetryMaxAttempts)"
        try {
            $result = (& $Call)
            # Logged even on attempt 1 so a clean run's log still shows every
            # Graph call that happened, not just the ones that had trouble.
            Write-WizardDebug "$What : Graph returned success on attempt $attempt"
            return $result
        } catch {
            # Full status/body for the log, regardless of whether this is
            # going to retry - this is the actual Graph response, and it is
            # what tells apart "the write never landed" from "it landed and
            # something after it failed", which the console warning alone
            # does not carry.
            $status = Get-WizardGraphStatusCode -ErrorRecord $_
            Write-WizardDebug "$What : attempt $attempt failed (status=$status): $(Get-WizardErrorSummary -ErrorRecord $_)"

            # Out of attempts, or not the kind of failure that waiting fixes:
            # let the caller's own error handling describe it.
            if ($attempt -ge $script:RetryMaxAttempts -or -not (Test-WizardRetryableFailure -ErrorRecord $_)) {
                if ($attempt -gt 1) {
                    Write-WizardDebug "$What still failing after $attempt attempt(s); giving up."
                }
                throw
            }

            $delay = Get-WizardRetryDelaySeconds -ErrorRecord $_ -Attempt $attempt
            # Written to the host, not just the log: an operator watching a run
            # pause for half a minute deserves to know why it is paused.
            Write-Warning "$What was throttled or unavailable ($(Get-WizardErrorSummary -ErrorRecord $_)). Waiting $([Math]::Round($delay, 1))s and retrying (attempt $($attempt + 1) of $script:RetryMaxAttempts)."
            Write-WizardDebug "$What : waiting $([Math]::Round($delay, 1))s before attempt $($attempt + 1) (status=$status)"
            Start-Sleep -Milliseconds ([int]($delay * 1000))
            $attempt++
        }
    }
}
