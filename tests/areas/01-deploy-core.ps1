# ---------------------------------------------------------------- Test 1
# Content match + Skip must NOT fall through into update/create.
# This is the 'continue inside switch' regression.
$ws = New-Workspace -Scripts @(@{ Rel = 'device/Script-A.ps1'; Body = $bodyA })
$state = @{ groups = @(); scripts = @(@{
    id = 'existing-1'; displayName = 'Old Name For A'; description = ''
    fileName = 'Script-A.ps1'
    scriptContent = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($bodyA))
    runAsAccount = 'system'; enforceSignatureCheck = $false; runAs32Bit = $true
    roleScopeTagIds = @('0'); lastModifiedDateTime = (Get-Date).ToString('o'); assignments = @()
}) }
$r = Invoke-Wizard -Workspace $ws -State $state -WizardArgs @('-OnFuzzyMatch', 'Skip')
$mutations = @($r.Calls | Where-Object { $_['call'] -in @('New-MgBetaDeviceManagementScript', 'Update-MgBetaDeviceManagementScript') })
$assigns   = @($r.Calls | Where-Object { $_['call'] -eq 'Invoke-MgGraphRequest' -and $_['data']['method'] -eq 'POST' })
Check 'Skip on content match makes no create/update call' ($mutations.Count -eq 0) "got $($mutations.Count): $($mutations.call -join ',')"
Check 'Skip on content match makes no assign call'        ($assigns.Count -eq 0)   "got $($assigns.Count)"
Check 'Skip leaves tenant script count unchanged'         ($r.State['scripts'].Count -eq 1) "got $($r.State['scripts'].Count)"

# ---------------------------------------------------------------- Test 2
# Empty tenant: both scripts created, each with the correct assign target.
# -OnFuzzyMatch is required, not incidental: 'Script-A' and 'Script-B' are 88%
# similar, so the second one fuzzy-matches the first the moment it is created.
$ws = New-Workspace -Scripts @(
    @{ Rel = 'device/Script-A.ps1'; Body = $bodyA },
    @{ Rel = 'user/Script-B.ps1';   Body = $bodyB }
)
$r = Invoke-Wizard -Workspace $ws -State @{ scripts = @() } -WizardArgs @('-OnFuzzyMatch', 'SideBySide')
Check 'Successful run exits 0' ($r.ExitCode -eq 0) "got $($r.ExitCode)"
$created = @($r.Calls | Where-Object { $_['call'] -eq 'New-MgBetaDeviceManagementScript' })
Check 'Both scripts created' ($created.Count -eq 2) "got $($created.Count)"
$runAs = ($created | ForEach-Object { $_['data']['runAsAccount'] }) | Sort-Object
Check 'RunAsAccount set per folder' (($runAs -join ',') -eq 'system,user') "got $($runAs -join ',')"

$targets = @()
foreach ($s in $r.State['scripts']) { foreach ($a in @($s['assignments'])) { $targets += $a['target']['@odata.type'] } }
$targets = $targets | Sort-Object
$expected = '#microsoft.graph.allDevicesAssignmentTarget,#microsoft.graph.allLicensedUsersAssignmentTarget'
Check 'assign action set correct targets' (($targets -join ',') -eq $expected) "got $($targets -join ',')"

$assignPosts = @($r.Calls | Where-Object { $_['call'] -eq 'Invoke-MgGraphRequest' -and $_['data']['uri'] -match '/assign$' })
Check 'Assignments went through the assign action' ($assignPosts.Count -eq 2) "got $($assignPosts.Count)"
Check 'assign body uses deviceManagementScriptAssignments' ($assignPosts[0]['data']['body'] -match 'deviceManagementScriptAssignments') $assignPosts[0]['data']['body']

# ---------------------------------------------------------------- Test 3
# Duplicate local display names must abort before touching the tenant.
$ws = New-Workspace -Scripts @(
    @{ Rel = 'device/Dupe.ps1'; Body = $bodyA },
    @{ Rel = 'user/Dupe.ps1';   Body = $bodyB }
)
$r = Invoke-Wizard -Workspace $ws -State @{ scripts = @() }
$created = @($r.Calls | Where-Object { $_['call'] -eq 'New-MgBetaDeviceManagementScript' })
Check 'Duplicate display names abort'          ($r.Output -match 'Duplicate display names') $r.Output
Check 'Duplicate names create nothing'         ($created.Count -eq 0) "got $($created.Count)"

# ---------------------------------------------------------------- Test 4
# The wizard's own file sitting in the scanned folder is ignored silently.
$ws = New-Workspace -Scripts @(@{ Rel = 'device/Script-A.ps1'; Body = $bodyA })
Copy-Item (Join-Path $repo 'Deploy-IntuneScripts.ps1') (Join-Path $ws 'Deploy-IntuneScripts.ps1')
Copy-Item -Recurse (Join-Path $repo 'lib') (Join-Path $ws 'lib')
$r = Invoke-Wizard -Workspace $ws -State @{ scripts = @() }
Check 'Wizard own file produces no warning' (-not ($r.Output -match 'Skipping.*Deploy-IntuneScripts')) $r.Output
$created = @($r.Calls | Where-Object { $_['call'] -eq 'New-MgBetaDeviceManagementScript' })
Check 'Only the real script is deployed' ($created.Count -eq 1) "got $($created.Count)"

# ---------------------------------------------------------------- Test 5
# Backup then restore preserves a group target's groupId and the scope tags.
$ws = New-Workspace -Scripts @(@{ Rel = 'device/Script-A.ps1'; Body = "$bodyA# changed`n" })
$state = @{ groups = @(); scripts = @(@{
    id = 'existing-2'; displayName = 'Script-A'; description = 'desc'
    fileName = 'Script-A.ps1'
    scriptContent = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($bodyA))
    runAsAccount = 'system'; enforceSignatureCheck = $false; runAs32Bit = $true
    roleScopeTagIds = @('0', '7')
    lastModifiedDateTime = (Get-Date).ToString('o')
    assignments = @(@{
        id = 'assign-1'
        target = @{
            '@odata.type' = '#microsoft.graph.groupAssignmentTarget'
            groupId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
            deviceAndAppManagementAssignmentFilterId = 'filter-123'
        }
    })
}) }
$r = Invoke-Wizard -Workspace $ws -State $state
$backupFile = Get-ChildItem -LiteralPath (Join-Path $ws 'backups') -Filter '*.json' | Select-Object -First 1
Check 'Backup file written' ($null -ne $backupFile) $r.Output

$backup = Get-Content -LiteralPath $backupFile.FullName -Raw | ConvertFrom-Json -AsHashtable
$bt = $backup['Assignments'][0]['target']
Check 'Backup preserved groupId'        ($bt['groupId'] -eq 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee') "got $($bt['groupId'])"
Check 'Backup preserved filter id'      ($bt['deviceAndAppManagementAssignmentFilterId'] -eq 'filter-123') "got $($bt['deviceAndAppManagementAssignmentFilterId'])"
Check 'Backup preserved scope tags'     ((@($backup['RoleScopeTagIds']) -join ',') -eq '0,7') "got $(@($backup['RoleScopeTagIds']) -join ',')"
Check 'Backup dropped assignment id'    (-not $backup['Assignments'][0].ContainsKey('id')) 'id leaked into backup'
Check 'Backup schema version is 3'      ($backup['SchemaVersion'] -eq 3) "got $($backup['SchemaVersion'])"
Check 'Backup recorded replacement name' (-not [string]::IsNullOrWhiteSpace($backup['ReplacedByDisplayName'])) 'ReplacedByDisplayName was blank'
Check 'Backup recorded replacement hash' (-not [string]::IsNullOrWhiteSpace($backup['ReplacedByContentHash'])) 'ReplacedByContentHash was blank'

# The SDK hands back scriptContent as a byte[], so writing it into the backup
# unconverted stores a JSON array of numbers instead of base64 text. Restore can
# now recover such a file, which means a round-trip test alone would not notice
# - assert the stored shape itself, and that it decodes to the real script.
Check 'Backup stored content as base64 text' ($backup['ScriptContent'] -is [string]) `
    "ScriptContent came back as $(if ($null -eq $backup['ScriptContent']) { 'null' } else { $backup['ScriptContent'].GetType().Name })"
$decodedBackup = try { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String([string]$backup['ScriptContent'])) } catch { '' }
Check 'Backup content decodes to the script' ($decodedBackup -eq $bodyA) "decoded to '$decodedBackup'"

$backupFilePath = $backupFile.FullName

# Restore that backup and confirm scope tags and the group target come back.
$env:WIZTEST_STATE = Join-Path $ws '_state.json'
$env:WIZTEST_CALLS = Join-Path $ws '_calls.jsonl'
$env:PSModulePath  = $stubs
& pwsh -NoProfile -File (Join-Path $repo 'Deploy-IntuneScripts.ps1') -Path $ws -Restore $backupFilePath *>&1 | Out-Null
$after = Get-Content -LiteralPath $env:WIZTEST_STATE -Raw | ConvertFrom-Json -AsHashtable
$restored = $after['scripts'] | Where-Object { $_['id'] -eq 'existing-2' }
Check 'Restore reinstated scope tags'   ((@($restored['roleScopeTagIds']) -join ',') -eq '0,7') "got $(@($restored['roleScopeTagIds']) -join ',')"
Check 'Restore reinstated groupId'      (@($restored['assignments'])[0]['target']['groupId'] -eq 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee') "got $(@($restored['assignments'])[0]['target'] | ConvertTo-Json -Compress)"

$restoredCopy = Join-Path (Join-Path $ws 'backups' 'backup-restored') (Split-Path -Leaf $backupFilePath)
Check 'Restored backup moved to backup-restored/' (Test-Path -LiteralPath $restoredCopy) "expected $restoredCopy"
Check 'Restored backup no longer in backups/'     (-not (Test-Path -LiteralPath $backupFilePath)) "still at $backupFilePath"

# ---------------------------------------------------------------- Test 6
# #noassignments must clear assignments, not leave them in place.
$ws = New-Workspace -Scripts @(@{ Rel = 'device/Script-A.ps1'; Body = "#noassignments`n$bodyA# v2`n" })
$state = @{ groups = @(); scripts = @(@{
    id = 'existing-3'; displayName = 'Script-A'; description = ''
    fileName = 'Script-A.ps1'
    scriptContent = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($bodyA))
    runAsAccount = 'system'; enforceSignatureCheck = $false; runAs32Bit = $true
    roleScopeTagIds = @('0'); lastModifiedDateTime = (Get-Date).ToString('o')
    assignments = @(@{ id = 'a1'; target = @{ '@odata.type' = '#microsoft.graph.allDevicesAssignmentTarget' } })
}) }
$r = Invoke-Wizard -Workspace $ws -State $state
$s3 = $r.State['scripts'] | Where-Object { $_['id'] -eq 'existing-3' }
Check '#noassignments clears assignments' (@($s3['assignments']).Count -eq 0) "got $(@($s3['assignments']).Count)"

# ---------------------------------------------------------------- Test 7
# DryRun must make no mutating calls at all.
$ws = New-Workspace -Scripts @(@{ Rel = 'device/Script-A.ps1'; Body = $bodyA })
$r = Invoke-Wizard -Workspace $ws -State @{ scripts = @() } -WizardArgs @('-DryRun')
$mut = @($r.Calls | Where-Object {
    $_['call'] -in @('New-MgBetaDeviceManagementScript', 'Update-MgBetaDeviceManagementScript') -or
    ($_['call'] -eq 'Invoke-MgGraphRequest' -and $_['data']['method'] -eq 'POST')
})
Check 'DryRun makes no mutating calls' ($mut.Count -eq 0) "got $($mut.Count)"

# ---------------------------------------------------------------- Test 8
# Debug logging writes a file and stamps the build.
$ws = New-Workspace -Scripts @(@{ Rel = 'device/Script-A.ps1'; Body = $bodyA })
$r = Invoke-Wizard -Workspace $ws -State @{ scripts = @() } -WizardArgs @('-DryRun', '-DebugLog', 'Both')
$log = Get-ChildItem -LiteralPath (Join-Path $ws 'logs') -Filter '*.log' -ErrorAction SilentlyContinue | Select-Object -First 1
Check 'Debug log file created' ($null -ne $log) $r.Output
if ($log) {
    # The expected version is read from the source rather than hardcoded: the
    # assertion is "the log carries the build stamp", not "the version is 1.2.3",
    # and a hardcoded copy silently rots every time the version is bumped.
    $versionLine = Select-String -Path (Join-Path $repo 'lib/Logging.ps1') -Pattern "WizardVersion\s*=\s*'([^']+)'"
    $wizardVersion = $versionLine.Matches[0].Groups[1].Value
    $logText = Get-Content -LiteralPath $log.FullName -Raw
    Check 'Debug log carries build stamp' ($logText -match "build $([regex]::Escape($wizardVersion))\+") $logText
    Check 'Debug log traces Graph calls'  ($logText -match 'Graph context') $logText
    Check 'Debug log records the exit code' ($logText -match 'Run finished with exit code 0') $logText
}

# ---------------------------------------------------------------- Test 9
# Bad -Path fails loudly instead of reporting "no scripts found".
$env:PSModulePath = $stubs
$out = & pwsh -NoProfile -File (Join-Path $repo 'Deploy-IntuneScripts.ps1') -Path (Join-Path $scratch 'does-not-exist') 2>&1 | Out-String
Check 'Missing -Path throws' ($out -match "does not exist or is not a folder") $out
