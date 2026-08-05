# --------------------------------------------------------------- Test 24
# A corrupt or hand-edited backup is rejected before anything reaches Graph.
$ws = New-Workspace -Scripts @()
$badBackups = @(
    @{ Name = 'not-json';     Content = 'this is not json at all'; Expect = 'Could not parse' }
    @{ Name = 'missing-keys'; Content = '{"SchemaVersion":2,"Id":"x"}'; Expect = 'missing required field' }
    @{ Name = 'bad-base64';   Expect = 'not valid base64'
       Content = '{"SchemaVersion":2,"Id":"x","DisplayName":"X","FileName":"x.ps1","RunAsAccount":"system","ScriptContent":"not base 64!!"}' }
    @{ Name = 'bad-runas';    Expect = "accepts only 'user' or 'system'"
       Content = '{"SchemaVersion":2,"Id":"x","DisplayName":"X","FileName":"x.ps1","RunAsAccount":"root","ScriptContent":"YQ=="}' }
)
foreach ($case in $badBackups) {
    $file = Join-Path $ws "$($case.Name).json"
    Set-Content -LiteralPath $file -Value $case.Content
    $env:WIZTEST_STATE = Join-Path $ws '_state.json'
    $env:WIZTEST_CALLS = Join-Path $ws '_calls.jsonl'
    (@{ scripts = @() } | ConvertTo-Json) | Set-Content -LiteralPath $env:WIZTEST_STATE
    Set-Content -LiteralPath $env:WIZTEST_CALLS -Value '' -NoNewline
    $env:PSModulePath = $stubs
    $out = & pwsh -NoProfile -File (Join-Path $repo 'Deploy-IntuneScripts.ps1') -Path $ws -Restore $file 2>&1 | Out-String
    $code = $LASTEXITCODE
    $calls = @(Get-Content -LiteralPath $env:WIZTEST_CALLS | Where-Object { $_ })
    Check "Bad backup ($($case.Name)) is rejected" ($out -match [regex]::Escape($case.Expect)) $out
    Check "Bad backup ($($case.Name)) exits 1"     ($code -eq 1) "got $code"
    Check "Bad backup ($($case.Name)) writes nothing" (
        -not (@($calls) -match 'MgBetaDeviceManagementScript')
    ) ($calls -join ' | ')
}

# --------------------------------------------------------------- Test 25
# -DryRun with -Restore is a contradiction and must not touch the tenant.
$r = Invoke-Wizard -Workspace $ws -State @{ scripts = @() } -WizardArgs @('-Restore', 'anything.json', '-DryRun')
Check '-DryRun with -Restore is refused' ($r.Output -match 'cannot be combined with -Restore') $r.Output
Check '-DryRun with -Restore exits 1'    ($r.ExitCode -eq 1) "got $($r.ExitCode)"

# --------------------------------------------------------------- Test 26
# -RestoreAll restores every backup directly under a folder in one command,
# and each one gets moved into backup-restored/ afterwards.
$bodyA2 = "# device script A v2`nWrite-Host 'a2'`n"
$bodyB2 = "# user script B v2`nWrite-Host 'b2'`n"
$ws = New-Workspace -Scripts @(
    @{ Rel = 'device/Script-A.ps1'; Body = $bodyA2 }
    @{ Rel = 'user/Script-B.ps1'; Body = $bodyB2 }
)
$state = @{ groups = @(); scripts = @(
    @{
        id = 'existing-a'; displayName = 'Script-A'; description = ''
        fileName = 'Script-A.ps1'
        scriptContent = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($bodyA))
        runAsAccount = 'system'; enforceSignatureCheck = $false; runAs32Bit = $true
        roleScopeTagIds = @('0'); lastModifiedDateTime = (Get-Date).ToString('o'); assignments = @()
    }
    @{
        id = 'existing-b'; displayName = 'Script-B'; description = ''
        fileName = 'Script-B.ps1'
        scriptContent = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($bodyB))
        runAsAccount = 'user'; enforceSignatureCheck = $false; runAs32Bit = $false
        roleScopeTagIds = @('0'); lastModifiedDateTime = (Get-Date).ToString('o'); assignments = @()
    }
) }
$r = Invoke-Wizard -Workspace $ws -State $state
Check '-RestoreAll setup: both scripts updated' ($r.ExitCode -eq 0) $r.Output
$backupsDir = Join-Path $ws 'backups'
$backupFiles = @(Get-ChildItem -LiteralPath $backupsDir -Filter '*.json')
Check '-RestoreAll setup: two backups written' ($backupFiles.Count -eq 2) "got $($backupFiles.Count)"

$env:WIZTEST_STATE = Join-Path $ws '_state.json'
$env:WIZTEST_CALLS = Join-Path $ws '_calls.jsonl'
$env:PSModulePath  = $stubs
$out = & pwsh -NoProfile -File (Join-Path $repo 'Deploy-IntuneScripts.ps1') -Path $ws -Restore $backupsDir -RestoreAll 2>&1 | Out-String
$code = $LASTEXITCODE
Check '-RestoreAll exits 0'   ($code -eq 0) "got $code`n$out"
Check '-RestoreAll restored both' ($out -match 'Restoring 2 backup') $out

$after = Get-Content -LiteralPath $env:WIZTEST_STATE -Raw | ConvertFrom-Json -AsHashtable
$restoredA = $after['scripts'] | Where-Object { $_['id'] -eq 'existing-a' }
$restoredB = $after['scripts'] | Where-Object { $_['id'] -eq 'existing-b' }
Check '-RestoreAll reinstated script A content' (
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($restoredA['scriptContent'])) -eq $bodyA
) "got $($restoredA['scriptContent'])"
Check '-RestoreAll reinstated script B content' (
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($restoredB['scriptContent'])) -eq $bodyB
) "got $($restoredB['scriptContent'])"

$movedFiles = @(Get-ChildItem -LiteralPath (Join-Path $backupsDir 'backup-restored') -Filter '*.json' -ErrorAction SilentlyContinue)
Check '-RestoreAll moved both backups to backup-restored/' ($movedFiles.Count -eq 2) "got $($movedFiles.Count)"
Check '-RestoreAll left backups/ empty of json'  ((@(Get-ChildItem -LiteralPath $backupsDir -Filter '*.json')).Count -eq 0) 'files still directly under backups/'

# -RestoreAll without -Restore is a usage error, not a silent no-op.
$r = Invoke-Wizard -Workspace $ws -State @{ scripts = @() } -WizardArgs @('-RestoreAll')
Check '-RestoreAll without -Restore is refused' ($r.Output -match "needs -Restore") $r.Output
Check '-RestoreAll without -Restore exits 1'    ($r.ExitCode -eq 1) "got $($r.ExitCode)"

# --------------------------------------------------------------- Test 27
# The restore-edge-case helpers (New-BackupWorkspace, Invoke-Restore,
# New-BackupContent, New-TenantScript) live in support/TestHelpers.ps1.
#
# A transient Graph failure on the "does this script still exist?" check must
# NOT be read as a deletion. Doing so recreates a script that is still live,
# leaving two copies of it in the tenant and the backup filed away as used.
$ws = New-BackupWorkspace -Backups @(@{ Name = 'live.json'; Content = (New-BackupContent -Id 'existing-t' -Name 'Throttled' -Body $bodyA) }) -State @{
    scripts = @((New-TenantScript -Id 'existing-t' -Name 'Throttled' -Body "$bodyA# v2`n"))
    getError = 'Response status code does not indicate success: 403 (Forbidden).'
}
$r = Invoke-Restore -Workspace $ws -WizardArgs @('-Restore', (Join-Path $ws 'backups/live.json'))
$made = @($r.Calls | Where-Object { $_['call'] -eq 'New-MgBetaDeviceManagementScript' })
Check 'Throttled existence check does not recreate' ($made.Count -eq 0) "New called $($made.Count) time(s)"
Check 'Throttled existence check fails loudly'      ($r.Output -match 'Could not check whether script') $r.Output
Check 'Throttled existence check exits 1'           ($r.ExitCode -eq 1) "got $($r.ExitCode)"
Check 'Throttled restore leaves the backup in place' (Test-Path -LiteralPath (Join-Path $ws 'backups/live.json')) 'backup was moved despite failing'
Check 'Throttled restore leaves one script'         (@($r.State['scripts']).Count -eq 1) "got $(@($r.State['scripts']).Count)"

# A genuine "not found" still recreates - the branch above must not swallow it.
$ws = New-BackupWorkspace -Backups @(@{ Name = 'gone.json'; Content = (New-BackupContent -Id 'deleted-1' -Name 'Deleted Script' -Body $bodyA) }) -State @{ scripts = @() }
$r = Invoke-Restore -Workspace $ws -WizardArgs @('-Restore', (Join-Path $ws 'backups/gone.json'))
$made = @($r.Calls | Where-Object { $_['call'] -eq 'New-MgBetaDeviceManagementScript' })
Check 'Deleted script is still recreated' ($made.Count -eq 1) "New called $($made.Count) time(s): $($r.Output)"
Check 'Deleted script restore exits 0'    ($r.ExitCode -eq 0) "got $($r.ExitCode)`n$($r.Output)"

# --------------------------------------------------------------- Test 28
# A schema-1 backup has no RoleScopeTagIds key at all. @($null) is a ONE-element
# array, so the old .Count check read that as "one scope tag" and posted an
# empty id, which Graph rejects - the oldest backups were the unrestorable ones.
$schema1 = New-BackupContent -Id 'existing-s1' -Name 'Schema One' -Body $bodyA -Tags $null
$schema1['SchemaVersion'] = 1
$schema1.Remove('ReplacedByDisplayName'); $schema1.Remove('ReplacedByContentHash')
$ws = New-BackupWorkspace -Backups @(@{ Name = 'schema1.json'; Content = $schema1 }) -State @{
    scripts = @((New-TenantScript -Id 'existing-s1' -Name 'Schema One' -Body "$bodyA# v2`n"))
}
$r = Invoke-Restore -Workspace $ws -WizardArgs @('-Restore', (Join-Path $ws 'backups/schema1.json'))
$update = @($r.Calls | Where-Object { $_['call'] -eq 'Update-MgBetaDeviceManagementScript' })[0]
Check 'Schema-1 backup restores'                 ($r.ExitCode -eq 0) "got $($r.ExitCode)`n$($r.Output)"
Check 'Schema-1 backup sends the Default tag'    ((@($update['data']['roleScopeTagIds']) -join ',') -eq '0') "got '$(@($update['data']['roleScopeTagIds']) -join ',')'"

# --------------------------------------------------------------- Test 29
# Two display names that sanitise to the same file name, backed up in the same
# run: the second backup must not overwrite the first, or the first script is
# left updated with nothing to roll it back to.
$ws = New-Workspace -Scripts @(
    @{ Rel = 'device/a.ps1'; Body = "#scriptname:`"Payroll Script (v1)`"`n$bodyA# a`n" }
    @{ Rel = 'device/b.ps1'; Body = "#scriptname:`"Payroll Script [v1]`"`n$bodyA# b`n" }
)
$state = @{ groups = @(); scripts = @(
    (New-TenantScript -Id 'collide-a' -Name 'Payroll Script (v1)' -Body $bodyA)
    (New-TenantScript -Id 'collide-b' -Name 'Payroll Script [v1]' -Body $bodyB)
) }
$r = Invoke-Wizard -Workspace $ws -State $state
$collided = @(Get-ChildItem -LiteralPath (Join-Path $ws 'backups') -Filter '*.json')
Check 'Colliding backup names both written' ($collided.Count -eq 2) "got $($collided.Count): $($collided.Name -join ', ')"
$backedUpIds = @($collided | ForEach-Object {
    (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -AsHashtable)['Id']
} | Sort-Object)
Check 'Colliding backups cover both scripts' (($backedUpIds -join ',') -eq 'collide-a,collide-b') "got $($backedUpIds -join ',')"

# --------------------------------------------------------------- Test 30
# runAs32Bit must survive the round trip. The backup used to read a property
# name the SDK does not have, so every backup recorded $false and restoring a
# 32-bit script quietly moved it to the 64-bit host.
$ws = New-Workspace -Scripts @(@{ Rel = 'device/Script-A.ps1'; Body = "#host:64`n$bodyA# v2`n" })
$state = @{ groups = @(); scripts = @((New-TenantScript -Id 'bitness-1' -Name 'Script-A' -Body $bodyA -Run32 $true)) }
$r = Invoke-Wizard -Workspace $ws -State $state
$backupFile = Get-ChildItem -LiteralPath (Join-Path $ws 'backups') -Filter '*.json' | Select-Object -First 1
$backup = Get-Content -LiteralPath $backupFile.FullName -Raw | ConvertFrom-Json -AsHashtable
Check 'Backup captured runAs32Bit from the tenant' ($backup['RunAs32Bit'] -eq $true) "got $($backup['RunAs32Bit'])"
Check 'Update applied #host:64'                    ($r.State['scripts'][0]['runAs32Bit'] -eq $false) "got $($r.State['scripts'][0]['runAs32Bit'])"
$r = Invoke-Restore -Workspace $ws -WizardArgs @('-Restore', $backupFile.FullName)
$restored = $r.State['scripts'] | Where-Object { $_['id'] -eq 'bitness-1' }
Check 'Restore put runAs32Bit back'                ($restored['runAs32Bit'] -eq $true) "got $($restored['runAs32Bit'])"

# --------------------------------------------------------------- Test 31
# Several backups of the SAME script: -RestoreAll restores the oldest (the one
# that undoes the whole folder) and leaves the rest on disk, rather than
# replaying them in whatever order the file names happen to sort in.
$oldBody = "# original`nWrite-Host 'v1'`n"
$midBody = "# second`nWrite-Host 'v2'`n"
$ws = New-BackupWorkspace -Backups @(
    # Deliberately named so that restoring in file-name order ends on the NEWER
    # backup, which is what a script renamed between two backups produces and
    # what the old name-ordered loop would have left behind.
    @{ Name = 'Alpha_20260101-000000.json'; Content = (New-BackupContent -Id 'multi-1' -Name 'Alpha' -Body $oldBody -Stamp '2026-01-01T00:00:00.0000000+00:00') }
    @{ Name = 'Zulu_20260202-000000.json';  Content = (New-BackupContent -Id 'multi-1' -Name 'Zulu'  -Body $midBody -Stamp '2026-02-02T00:00:00.0000000+00:00') }
) -State @{ scripts = @((New-TenantScript -Id 'multi-1' -Name 'Zulu' -Body "# current`n")) }
$r = Invoke-Restore -Workspace $ws -WizardArgs @('-Restore', (Join-Path $ws 'backups'), '-RestoreAll')
$restored = $r.State['scripts'] | Where-Object { $_['id'] -eq 'multi-1' }
$restoredText = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($restored['scriptContent']))
Check '-RestoreAll restores the oldest backup per script' ($restoredText -eq $oldBody) "got '$restoredText'"
Check '-RestoreAll says which backups it passed over'     ($r.Output -match 'a later backup of the same script') $r.Output
Check '-RestoreAll restored exactly one'                  ($r.Output -match 'Restoring 1 backup') $r.Output
Check '-RestoreAll left the newer backup on disk' (Test-Path -LiteralPath (Join-Path $ws 'backups/Zulu_20260202-000000.json')) 'the newer backup was consumed too'
Check '-RestoreAll exits 0'                               ($r.ExitCode -eq 0) "got $($r.ExitCode)`n$($r.Output)"

# --------------------------------------------------------------- Test 32
# A stray .json in backups/ is somebody else's file, not a failed restore.
$ws = New-BackupWorkspace -Backups @(
    @{ Name = 'real.json';  Content = (New-BackupContent -Id 'stray-1' -Name 'Real' -Body $bodyA) }
    @{ Name = 'notes.json'; Content = @{ hello = 'world'; nothing = 'to do with backups' } }
) -State @{ scripts = @((New-TenantScript -Id 'stray-1' -Name 'Real' -Body "# current`n")) }
$r = Invoke-Restore -Workspace $ws -WizardArgs @('-Restore', (Join-Path $ws 'backups'), '-RestoreAll')
Check 'Stray json is skipped, not failed' ($r.ExitCode -eq 0) "got $($r.ExitCode)`n$($r.Output)"
Check 'Stray json is called out'          ($r.Output -match 'is not a wizard backup') $r.Output
Check 'Real backup still restored'        ($r.Output -match 'Restoring 1 backup') $r.Output

# --------------------------------------------------------------- Test 33
# -SkipAssignments restores the content and leaves the assign action alone, for
# a backup whose group targets no longer exist (or came from another tenant).
$liveAssignments = @(@{ id = 'a-1'; target = @{ '@odata.type' = '#microsoft.graph.allDevicesAssignmentTarget' } })
$withGroups = New-BackupContent -Id 'skip-1' -Name 'Skippy' -Body $bodyA
$withGroups['Assignments'] = @(@{
    '@odata.type' = '#microsoft.graph.deviceManagementScriptAssignment'
    target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = 'dead-group' }
})
$ws = New-BackupWorkspace -Backups @(@{ Name = 'skip.json'; Content = $withGroups }) -State @{
    scripts = @((New-TenantScript -Id 'skip-1' -Name 'Skippy' -Body "# current`n" -Assignments $liveAssignments))
}
$r = Invoke-Restore -Workspace $ws -WizardArgs @('-Restore', (Join-Path $ws 'backups/skip.json'), '-SkipAssignments')
$assignCalls = @($r.Calls | Where-Object { $_['call'] -eq 'Invoke-MgGraphRequest' -and $_['data']['method'] -eq 'POST' })
$restored = $r.State['scripts'] | Where-Object { $_['id'] -eq 'skip-1' }
$restoredText = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($restored['scriptContent']))
Check '-SkipAssignments exits 0'                ($r.ExitCode -eq 0) "got $($r.ExitCode)`n$($r.Output)"
Check '-SkipAssignments restored the content'   ($restoredText -eq $bodyA) "got '$restoredText'"
Check '-SkipAssignments made no assign call'    ($assignCalls.Count -eq 0) "got $($assignCalls.Count)"
Check '-SkipAssignments left assignments alone' (@($restored['assignments'])[0]['target']['@odata.type'] -eq '#microsoft.graph.allDevicesAssignmentTarget') "got $(@($restored['assignments']) | ConvertTo-Json -Compress)"
Check '-SkipAssignments says what it skipped'   ($r.Output -match 'keeps whatever assignments it has now') $r.Output

# -SkipAssignments outside a restore is a usage error, not a silent no-op.
$r = Invoke-Wizard -Workspace $ws -State @{ scripts = @() } -WizardArgs @('-SkipAssignments')
Check '-SkipAssignments without -Restore is refused' ($r.Output -match 'only applies to a restore') $r.Output
Check '-SkipAssignments without -Restore exits 1'    ($r.ExitCode -eq 1) "got $($r.ExitCode)"

# --------------------------------------------------------------- Test 34
# A scope tag that no longer exists must not take the whole restore down with
# it: the content matters, the tag does not.
$ws = New-BackupWorkspace -Backups @(@{ Name = 'tags.json'; Content = (New-BackupContent -Id 'tag-1' -Name 'Tagged' -Body $bodyA -Tags @('0', '7')) }) -State @{
    scripts = @((New-TenantScript -Id 'tag-1' -Name 'Tagged' -Body "# current`n" -Tags @('0')))
    rejectScopeTag = '7'
}
$r = Invoke-Restore -Workspace $ws -WizardArgs @('-Restore', (Join-Path $ws 'backups/tags.json'))
$restored = $r.State['scripts'] | Where-Object { $_['id'] -eq 'tag-1' }
$restoredText = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($restored['scriptContent']))
Check 'Dead scope tag does not fail the restore' ($r.ExitCode -eq 0) "got $($r.ExitCode)`n$($r.Output)"
Check 'Dead scope tag falls back to Default'     ((@($restored['roleScopeTagIds']) -join ',') -eq '0') "got $(@($restored['roleScopeTagIds']) -join ',')"
Check 'Dead scope tag is warned about'           ($r.Output -match 'rejected over its role scope tags') $r.Output
Check 'Dead scope tag restore kept the content'  ($restoredText -eq $bodyA) "got '$restoredText'"
