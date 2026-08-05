# --------------------------------------------------------------- Test 35
# The duplicate prompt offers "[C]reate side-by-side" - the word people type is
# 'create', which used to fall through to the default and silently skip.
. (Join-Path $repo 'lib/Matching.ps1')
$choiceCases = @(
    @{ In = 'create';        Want = 'SideBySide' }
    @{ In = 'c';             Want = 'SideBySide' }
    @{ In = 'C';             Want = 'SideBySide' }
    @{ In = ' create ';      Want = 'SideBySide' }
    @{ In = 'side-by-side';  Want = 'SideBySide' }
    @{ In = 'si';            Want = 'SideBySide' }
    @{ In = 'replace';       Want = 'Replace' }
    @{ In = 'r';             Want = 'Replace' }
    @{ In = 'skip';          Want = 'Skip' }
    @{ In = 's';             Want = 'Skip' }
    @{ In = '';              Want = 'Skip' }
    @{ In = 'nonsense';      Want = 'Skip' }
)
foreach ($case in $choiceCases) {
    $got = ConvertTo-WizardFuzzyChoice -Choice $case.In
    Check "Duplicate prompt: '$($case.In)' -> $($case.Want)" ($got -eq $case.Want) "got $got"
}

# --------------------------------------------------------------- Test 36
# A throttled tenant is waited out, not treated as a failure. Two 429s on the
# existence check, then success: the restore must complete against the original
# script and must not have recreated anything along the way.
$ws = New-BackupWorkspace -Backups @(@{ Name = 'busy.json'; Content = (New-BackupContent -Id 'busy-1' -Name 'Busy' -Body $bodyA) }) -State @{
    scripts = @((New-TenantScript -Id 'busy-1' -Name 'Busy' -Body "# current`n"))
    throttle = @{ calls = 2; operation = 'get' }
}
$r = Invoke-Restore -Workspace $ws -WizardArgs @('-Restore', (Join-Path $ws 'backups/busy.json'))
$made = @($r.Calls | Where-Object { $_['call'] -eq 'New-MgBetaDeviceManagementScript' })
$restored = $r.State['scripts'] | Where-Object { $_['id'] -eq 'busy-1' }
$restoredText = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($restored['scriptContent']))
Check 'Throttled restore succeeds after retrying' ($r.ExitCode -eq 0) "got $($r.ExitCode)`n$($r.Output)"
Check 'Throttled restore says it is waiting'      ($r.Output -match 'throttled or unavailable') $r.Output
Check 'Throttled restore names the attempt'       ($r.Output -match 'attempt 2 of 5') $r.Output
Check 'Throttled restore restored the content'    ($restoredText -eq $bodyA) "got '$restoredText'"
Check 'Throttled restore made no duplicate'       ($made.Count -eq 0) "New called $($made.Count) time(s)"

# --------------------------------------------------------------- Test 37
# A tenant that never stops throttling gives up rather than retrying forever,
# and still must not fall through into recreating the script.
$ws = New-BackupWorkspace -Backups @(@{ Name = 'busy.json'; Content = (New-BackupContent -Id 'busy-2' -Name 'Busy' -Body $bodyA) }) -State @{
    scripts = @((New-TenantScript -Id 'busy-2' -Name 'Busy' -Body "# current`n"))
    throttle = @{ calls = 99; operation = 'get' }
}
$r = Invoke-Restore -Workspace $ws -WizardArgs @('-Restore', (Join-Path $ws 'backups/busy.json'))
$made = @($r.Calls | Where-Object { $_['call'] -eq 'New-MgBetaDeviceManagementScript' })
Check 'Endless throttling gives up'            ($r.ExitCode -eq 1) "got $($r.ExitCode)`n$($r.Output)"
Check 'Endless throttling stops at the limit'  ($r.Output -match 'attempt 5 of 5') $r.Output
Check 'Endless throttling makes no duplicate'  ($made.Count -eq 0) "New called $($made.Count) time(s)"
Check 'Endless throttling keeps the backup'    (Test-Path -LiteralPath (Join-Path $ws 'backups/busy.json')) 'backup was moved despite failing'

# --------------------------------------------------------------- Test 38
# The same retry covers a deploy's writes, not just restores.
$ws = New-Workspace -Scripts @(@{ Rel = 'device/Script-A.ps1'; Body = "$bodyA# v2`n" })
$state = @{
    groups = @(); scripts = @((New-TenantScript -Id 'busy-3' -Name 'Script-A' -Body $bodyA))
    throttle = @{ calls = 2; operation = 'update' }
}
$r = Invoke-Wizard -Workspace $ws -State $state
$updates = @($r.Calls | Where-Object { $_['call'] -eq 'Update-MgBetaDeviceManagementScript' })
$deployed = $r.State['scripts'] | Where-Object { $_['id'] -eq 'busy-3' }
$deployedText = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($deployed['scriptContent']))
Check 'Throttled update still succeeds'   ($r.ExitCode -eq 0) "got $($r.ExitCode)`n$($r.Output)"
Check 'Throttled update was retried'      ($updates.Count -eq 3) "got $($updates.Count) update call(s)"
Check 'Throttled update applied the change' ($deployedText -eq "$bodyA# v2`n") "got '$deployedText'"

# --------------------------------------------------------------- Test 39
# Retry-After from the service wins over the calculated backoff, and only the
# statuses that mean "not processed" are retried at all.
. (Join-Path $repo 'lib/Errors.ps1')
. (Join-Path $repo 'lib/GraphCore.ps1')
function New-FakeError {
    param([int]$Status, $RetryAfterSeconds)
    $exception = [System.Exception]::new("Response status code does not indicate success: $Status.")
    $record = [System.Management.Automation.ErrorRecord]::new($exception, 'x', 'NotSpecified', $null)
    # Add-Member bolts a property onto an existing object, which is how the
    # real SDK's exception shapes are stood in for here.
    $headers = @{}
    if ($null -ne $RetryAfterSeconds) { $headers['Retry-After'] = @("$RetryAfterSeconds") }
    $exception | Add-Member -NotePropertyName 'StatusCode' -NotePropertyValue $Status -Force
    $exception | Add-Member -NotePropertyName 'ResponseHeaders' -NotePropertyValue $headers -Force
    return $record
}
Check 'Retryable: 429' (Test-WizardRetryableFailure -ErrorRecord (New-FakeError -Status 429)) 'not retryable'
Check 'Retryable: 503' (Test-WizardRetryableFailure -ErrorRecord (New-FakeError -Status 503)) 'not retryable'
Check 'Not retryable: 504 (request may have been applied)' (-not (Test-WizardRetryableFailure -ErrorRecord (New-FakeError -Status 504))) 'treated as retryable'
Check 'Not retryable: 400' (-not (Test-WizardRetryableFailure -ErrorRecord (New-FakeError -Status 400))) 'treated as retryable'
Check 'Not retryable: 403' (-not (Test-WizardRetryableFailure -ErrorRecord (New-FakeError -Status 403))) 'treated as retryable'
Check 'A 429 is not read as a deletion' (-not (Test-WizardGraphNotFound -ErrorRecord (New-FakeError -Status 429))) 'treated as not-found'
Check 'A 404 still reads as a deletion' (Test-WizardGraphNotFound -ErrorRecord (New-FakeError -Status 404)) 'not treated as not-found'

$withHeader = Get-WizardRetryDelaySeconds -ErrorRecord (New-FakeError -Status 429 -RetryAfterSeconds 37) -Attempt 1
Check 'Retry-After header wins over backoff' ($withHeader -eq 37) "got $withHeader"
$capped = Get-WizardRetryDelaySeconds -ErrorRecord (New-FakeError -Status 429 -RetryAfterSeconds 9999) -Attempt 1
Check 'Retry-After is capped'                ($capped -eq 120) "got $capped"
# The suite shrinks the backoff base, so compare against that rather than 2s.
# Each multiplication is parenthesised because PowerShell's comma binds tighter
# than '*': '$base, $base * 2' is the array ($base, $base) repeated twice.
$base = [double]$env:WIZARD_RETRY_BASE_SECONDS
$backoff = @(1, 2, 3, 4 | ForEach-Object { Get-WizardRetryDelaySeconds -ErrorRecord (New-FakeError -Status 429) -Attempt $_ })
$wantBackoff = @($base, ($base * 2), ($base * 4), ($base * 8))
Check 'Backoff doubles each attempt' (($backoff -join ',') -eq ($wantBackoff -join ',')) "got $($backoff -join ','), wanted $($wantBackoff -join ',')"
