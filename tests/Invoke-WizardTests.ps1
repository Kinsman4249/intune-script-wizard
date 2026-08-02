#Requires -Version 7.0
<#
.SYNOPSIS
    Offline regression tests for Deploy-IntuneScripts.ps1.

.DESCRIPTION
    Injects stub Microsoft.Graph.Authentication and
    Microsoft.Graph.Beta.DeviceManagement modules via PSModulePath, so the real
    entry point runs end to end against an in-memory tenant with no network,
    credentials or Intune licence involved. Each scenario runs in its own pwsh
    process because the wizard calls exit on some paths.

    Run:  pwsh -NoProfile -File tests/Invoke-WizardTests.ps1
    Exits with the number of failed checks.

.PARAMETER WorkRoot
    Where scratch workspaces are created. Defaults to a temp folder, removed
    on exit unless -KeepWorkspaces is passed.

.PARAMETER KeepWorkspaces
    Leave the generated workspaces on disk for inspection after a failure.
#>
[CmdletBinding()]
param(
    [string]$WorkRoot,
    [switch]$KeepWorkspaces
)

$ErrorActionPreference = 'Stop'
$repo  = Split-Path -Parent $PSScriptRoot
$stubs = Join-Path $PSScriptRoot 'stub-modules'

if (-not $WorkRoot) {
    $WorkRoot = Join-Path ([System.IO.Path]::GetTempPath()) "wizard-tests-$([guid]::NewGuid().ToString('N').Substring(0,8))"
}
New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null
$scratch = $WorkRoot

# Retries are real waits, and the suite drives the throttle path deliberately.
# The wizard reads this to shrink its backoff base so a retry test costs
# milliseconds instead of half a minute; nothing in normal use sets it.
$env:WIZARD_RETRY_BASE_SECONDS = '0.05'

$pass = 0; $fail = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { Write-Host "PASS  $Name" -ForegroundColor Green; $script:pass++ }
    else     { Write-Host "FAIL  $Name  $Detail" -ForegroundColor Red;  $script:fail++ }
}

function New-Workspace {
    param([array]$Scripts)
    $ws = Join-Path $scratch "ws-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $ws -Force | Out-Null
    foreach ($s in $Scripts) {
        $full = Join-Path $ws $s.Rel
        New-Item -ItemType Directory -Path (Split-Path $full) -Force | Out-Null
        Set-Content -LiteralPath $full -Value $s.Body -NoNewline
    }
    return $ws
}

function Invoke-Wizard {
    param([string]$Workspace, [hashtable]$State, [string[]]$WizardArgs = @())
    $statePath = Join-Path $Workspace '_state.json'
    $callsPath = Join-Path $Workspace '_calls.jsonl'
    ($State | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $statePath
    Set-Content -LiteralPath $callsPath -Value '' -NoNewline

    $env:WIZTEST_STATE = $statePath
    $env:WIZTEST_CALLS = $callsPath
    $env:PSModulePath  = $stubs

    $out = & pwsh -NoProfile -File (Join-Path $repo 'Deploy-IntuneScripts.ps1') -Path $Workspace @WizardArgs 2>&1
    $calls = @()
    $rawCalls = Get-Content -LiteralPath $callsPath -Raw
    if ($rawCalls -and $rawCalls.Trim()) {
        $calls = Get-Content -LiteralPath $callsPath | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable }
    }
    return [pscustomobject]@{
        Output   = ($out | Out-String)
        ExitCode = $LASTEXITCODE
        Calls    = $calls
        State    = (Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable)
    }
}

$bodyA = "# device script A`nWrite-Host 'a'`n"
$bodyB = "# user script B`nWrite-Host 'b'`n"

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

# --------------------------------------------------------------- Test 10
# Custom group assignment: names resolved, GUIDs passed through, exclusion added.
$guid = '6f9a1c22-6b7e-4a11-9f3d-2c8e5b7a1d40'
$helpdeskId = '11111111-2222-3333-4444-555555555555'
$pilotId    = '99999999-8888-7777-6666-555555555555'
# Deliberately absent from $directory below: an #excludegroup: carrying this
# guid must be passed straight to Graph. If the wizard ever tried to look it up
# by name the whole run would abort with 'No group found', failing these checks.
$exclGuid   = '0a7c4d13-5e26-4f38-8b90-1d2e3f4a5b6c'
$directory = @(
    @{ id = $helpdeskId; displayName = 'Helpdesk Laptops' }
    @{ id = $pilotId;    displayName = 'Pilot Ring' }
    @{ id = 'dupe-a';    displayName = 'Ambiguous Name' }
    @{ id = 'dupe-b';    displayName = 'Ambiguous Name' }
)

$ws = New-Workspace -Scripts @(
    @{ Rel = 'device/By-Name.ps1'; Body = "#group:`"Helpdesk Laptops`"`n#excludegroup:`"Pilot Ring`"`n$bodyA" }
    @{ Rel = 'device/By-Guid.ps1'; Body = "#group:$guid`n$bodyB" }
    @{ Rel = 'device/Excl-Only.ps1'; Body = "#excludegroup:`"Pilot Ring`"`nWrite-Host 'c'`n" }
    @{ Rel = 'device/Excl-Guid.ps1'; Body = "#excludegroup:$exclGuid`nWrite-Host 'd'`n" }
    @{ Rel = 'device/Mixed-Refs.ps1'; Body = "#group:`"Helpdesk Laptops`"`n#excludegroup:$exclGuid`nWrite-Host 'e'`n" }
)
$r = Invoke-Wizard -Workspace $ws -State @{ scripts = @(); groups = $directory }

function Get-TargetsFor {
    param($State, $Name)
    $s = $State['scripts'] | Where-Object { $_['displayName'] -eq $Name }
    # Unary comma keeps this an array even for 0 or 1 targets. Without it a
    # single target arrives as a bare hashtable, whose .Count is its key count.
    return ,@($s['assignments'] | ForEach-Object { $_['target'] })
}

$byName = Get-TargetsFor $r.State 'By-Name'
Check 'Named group resolved to an id' (
    ($byName | Where-Object { $_['@odata.type'] -eq '#microsoft.graph.groupAssignmentTarget' }).groupId -eq $helpdeskId
) ($byName | ConvertTo-Json -Compress)
Check 'Exclusion target emitted' (
    ($byName | Where-Object { $_['@odata.type'] -eq '#microsoft.graph.exclusionGroupAssignmentTarget' }).groupId -eq $pilotId
) ($byName | ConvertTo-Json -Compress)
Check 'Named-group script has exactly 2 targets' ($byName.Count -eq 2) "got $($byName.Count)"

$byGuid = Get-TargetsFor $r.State 'By-Guid'
Check 'Bare GUID passed straight through' (
    $byGuid.Count -eq 1 -and $byGuid[0]['groupId'] -eq $guid -and
    $byGuid[0]['@odata.type'] -eq '#microsoft.graph.groupAssignmentTarget'
) ($byGuid | ConvertTo-Json -Compress)

$exclOnly = Get-TargetsFor $r.State 'Excl-Only'
$types = @($exclOnly | ForEach-Object { $_['@odata.type'] }) | Sort-Object
Check 'Exclude-only keeps the all-devices include' (
    ($types -join ',') -eq '#microsoft.graph.allDevicesAssignmentTarget,#microsoft.graph.exclusionGroupAssignmentTarget'
) ($types -join ',')

# Same shape as Excl-Only above, but the exclusion is a bare guid rather than a
# display name: it must reach Graph verbatim, with the all-devices include intact.
$exclGuidOnly = Get-TargetsFor $r.State 'Excl-Guid'
$exclTarget = @($exclGuidOnly | Where-Object { $_['@odata.type'] -eq '#microsoft.graph.exclusionGroupAssignmentTarget' })
$types = @($exclGuidOnly | ForEach-Object { $_['@odata.type'] }) | Sort-Object
Check 'Bare GUID exclusion passed straight through' (
    $exclTarget.Count -eq 1 -and $exclTarget[0]['groupId'] -eq $exclGuid
) ($exclGuidOnly | ConvertTo-Json -Compress)
Check 'GUID exclude-only keeps the all-devices include' (
    ($types -join ',') -eq '#microsoft.graph.allDevicesAssignmentTarget,#microsoft.graph.exclusionGroupAssignmentTarget'
) ($types -join ',')

# A named include and a bare-guid exclude in one script: both reference forms
# have to survive the same resolution pass.
$mixed = Get-TargetsFor $r.State 'Mixed-Refs'
Check 'Named include + GUID exclude both land' (
    $mixed.Count -eq 2 -and
    ($mixed | Where-Object { $_['@odata.type'] -eq '#microsoft.graph.groupAssignmentTarget' }).groupId -eq $helpdeskId -and
    ($mixed | Where-Object { $_['@odata.type'] -eq '#microsoft.graph.exclusionGroupAssignmentTarget' }).groupId -eq $exclGuid
) ($mixed | ConvertTo-Json -Compress)

# --------------------------------------------------------------- Test 11
# Unresolvable and ambiguous group names abort the whole run.
foreach ($case in @(
    @{ Name = 'Unknown group name aborts';   Tag = '#group:"No Such Group"'; Expect = 'No group found' }
    @{ Name = 'Ambiguous group name aborts'; Tag = '#group:"Ambiguous Name"'; Expect = 'is ambiguous' }
)) {
    $ws = New-Workspace -Scripts @(
        @{ Rel = 'device/Bad.ps1';  Body = "$($case.Tag)`n$bodyA" }
        @{ Rel = 'device/Good.ps1'; Body = $bodyB }
    )
    $r = Invoke-Wizard -Workspace $ws -State @{ scripts = @(); groups = $directory }
    $created = @($r.Calls | Where-Object { $_['call'] -eq 'New-MgBetaDeviceManagementScript' })
    Check $case.Name ($r.Output -match $case.Expect) $r.Output
    Check "$($case.Name) - nothing deployed" ($created.Count -eq 0) "got $($created.Count)"
}

# --------------------------------------------------------------- Test 12
# Contradictory tags are rejected at parse time.
$ws = New-Workspace -Scripts @(@{ Rel = 'device/Bad.ps1'; Body = "#noassignments`n#group:`"Helpdesk Laptops`"`n$bodyA" })
$r = Invoke-Wizard -Workspace $ws -State @{ scripts = @(); groups = $directory }
Check '#noassignments + #group: rejected' ($r.Output -match 'cannot be combined') $r.Output

$ws = New-Workspace -Scripts @(@{ Rel = 'device/Bad.ps1'; Body = "#group:`"Pilot Ring`"`n#excludegroup:`"Pilot Ring`"`n$bodyA" })
$r = Invoke-Wizard -Workspace $ws -State @{ scripts = @(); groups = $directory }
Check 'Same group included and excluded rejected' ($r.Output -match 'both #group: and #excludegroup:') $r.Output

# The parse-time check above only catches refs that are the same string. A name
# on one line and that same group's guid on the other are different strings, so
# the clash only surfaces after resolution - and it must still abort the run.
$ws = New-Workspace -Scripts @(
    @{ Rel = 'device/Bad.ps1';  Body = "#group:`"Pilot Ring`"`n#excludegroup:$pilotId`n$bodyA" }
    @{ Rel = 'device/Good.ps1'; Body = $bodyB }
)
$r = Invoke-Wizard -Workspace $ws -State @{ scripts = @(); groups = $directory }
$created = @($r.Calls | Where-Object { $_['call'] -eq 'New-MgBetaDeviceManagementScript' })
Check 'Name-and-GUID for one group rejected after resolution' (
    $r.Output -match 'resolves to both an include and an exclude target'
) $r.Output
Check 'Name-and-GUID clash deploys nothing' ($created.Count -eq 0) "got $($created.Count)"

# --------------------------------------------------------------- Test 13
# The directory-read scope is requested only when a name needs resolving.
$ws = New-Workspace -Scripts @(@{ Rel = 'device/By-Guid.ps1'; Body = "#group:$guid`n$bodyA" })
$r = Invoke-Wizard -Workspace $ws -State @{ scripts = @(); groups = $directory }
$connect = @($r.Calls | Where-Object { $_['call'] -eq 'Connect-MgGraph' })
Check 'GUID-only run does not request group scope' (
    $connect.Count -eq 0 -or -not (@($connect[0]['data']['scopes']) -contains 'GroupMember.Read.All')
) ($connect | ConvertTo-Json -Compress)

# An exclusion is a group reference like any other: a bare guid there must not
# drag the directory-read scope in either.
$ws = New-Workspace -Scripts @(@{ Rel = 'device/Excl-Guid.ps1'; Body = "#excludegroup:$exclGuid`n$bodyA" })
$r = Invoke-Wizard -Workspace $ws -State @{ scripts = @(); groups = $directory }
$connect = @($r.Calls | Where-Object { $_['call'] -eq 'Connect-MgGraph' })
Check 'GUID-only exclusion does not request group scope' (
    $connect.Count -eq 0 -or -not (@($connect[0]['data']['scopes']) -contains 'GroupMember.Read.All')
) ($connect | ConvertTo-Json -Compress)

$ws = New-Workspace -Scripts @(@{ Rel = 'device/By-Name.ps1'; Body = "#group:`"Helpdesk Laptops`"`n$bodyA" })
$r = Invoke-Wizard -Workspace $ws -State @{ scripts = @(); groups = $directory }
Check 'Name-based run announces the extra scope' ($r.Output -match 'GroupMember\.Read\.All') $r.Output

$ws = New-Workspace -Scripts @(@{ Rel = 'device/Excl-Name.ps1'; Body = "#excludegroup:`"Pilot Ring`"`n$bodyA" })
$r = Invoke-Wizard -Workspace $ws -State @{ scripts = @(); groups = $directory }
Check 'Name-based exclusion announces the extra scope' ($r.Output -match 'GroupMember\.Read\.All') $r.Output

# --------------------------------------------------------------- Test 14
# Switching an existing script from all-devices to a group replaces the set.
$ws = New-Workspace -Scripts @(@{ Rel = 'device/Script-A.ps1'; Body = "#group:`"Helpdesk Laptops`"`n$bodyA# v2`n" })
$state = @{
    groups = $directory
    scripts = @(@{
        id = 'existing-9'; displayName = 'Script-A'; description = ''
        fileName = 'Script-A.ps1'
        scriptContent = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($bodyA))
        runAsAccount = 'system'; enforceSignatureCheck = $false; runAs32Bit = $true
        roleScopeTagIds = @('0'); lastModifiedDateTime = (Get-Date).ToString('o')
        assignments = @(@{ id = 'a1'; target = @{ '@odata.type' = '#microsoft.graph.allDevicesAssignmentTarget' } })
    })
}
$r = Invoke-Wizard -Workspace $ws -State $state
$t = Get-TargetsFor $r.State 'Script-A'
Check 'all-devices replaced by group target' (
    $t.Count -eq 1 -and $t[0]['@odata.type'] -eq '#microsoft.graph.groupAssignmentTarget' -and $t[0]['groupId'] -eq $helpdeskId
) ($t | ConvertTo-Json -Compress)

# --------------------------------------------------------------- Test 15
# A conflicting #type: comment loses to the folder the script sits in.
$ws = New-Workspace -Scripts @(@{ Rel = 'device/Script-A.ps1'; Body = "#type:user`n$bodyA" })
$r = Invoke-Wizard -Workspace $ws -State @{ scripts = @() }
$created = @($r.Calls | Where-Object { $_['call'] -eq 'New-MgBetaDeviceManagementScript' })
Check 'Folder wins over conflicting #type: comment' (
    $created.Count -eq 1 -and $created[0]['data']['runAsAccount'] -eq 'system'
) "got $($created | ConvertTo-Json -Compress -Depth 5)"
Check 'Folder-vs-comment conflict warns' ($r.Output -match 'conflicts with its .device. folder') $r.Output

# --------------------------------------------------------------- Test 16
# #typeoverride:yes lets the comment win over the folder instead.
$ws = New-Workspace -Scripts @(@{ Rel = 'device/Script-A.ps1'; Body = "#type:user`n#typeoverride:yes`n$bodyA" })
$r = Invoke-Wizard -Workspace $ws -State @{ scripts = @() }
$created = @($r.Calls | Where-Object { $_['call'] -eq 'New-MgBetaDeviceManagementScript' })
Check '#typeoverride:yes honours the #type: comment' (
    $created.Count -eq 1 -and $created[0]['data']['runAsAccount'] -eq 'user'
) "got $($created | ConvertTo-Json -Compress -Depth 5)"

# --------------------------------------------------------------- Test 17
# Loose (unsorted) scripts and folder-sorted scripts are deployed together.
$ws = New-Workspace -Scripts @(
    @{ Rel = 'device/Script-A.ps1'; Body = $bodyA },
    @{ Rel = 'Loose-Script.ps1';    Body = "#type:user`n$bodyB" }
)
$r = Invoke-Wizard -Workspace $ws -State @{ scripts = @() }
$created = @($r.Calls | Where-Object { $_['call'] -eq 'New-MgBetaDeviceManagementScript' })
Check 'Loose script deploys alongside folder-sorted script' ($created.Count -eq 2) "got $($created.Count)"

# --------------------------------------------------------------- Test 18
# -AllowTypeOverride does the same as #typeoverride:yes, for every script.
$ws = New-Workspace -Scripts @(@{ Rel = 'device/Script-A.ps1'; Body = "#type:user`n$bodyA" })
$r = Invoke-Wizard -Workspace $ws -State @{ scripts = @() } -WizardArgs @('-AllowTypeOverride')
$created = @($r.Calls | Where-Object { $_['call'] -eq 'New-MgBetaDeviceManagementScript' })
Check '-AllowTypeOverride honours the #type: comment' (
    $created.Count -eq 1 -and $created[0]['data']['runAsAccount'] -eq 'user'
) "got $($created | ConvertTo-Json -Compress -Depth 5)"

# --------------------------------------------------------------- Test 19
# A single script failing does not stop the others, and the run exits 2.
$ws = New-Workspace -Scripts @(
    @{ Rel = 'device/Doomed.ps1';  Body = $bodyA }
    @{ Rel = 'device/Healthy.ps1'; Body = $bodyB }
)
$r = Invoke-Wizard -Workspace $ws -State @{ scripts = @(); failCreate = 'Doomed' }
$created = @($r.Calls | Where-Object { $_['call'] -eq 'New-MgBetaDeviceManagementScript' })
Check 'Failing script does not stop the run' (
    @($r.State['scripts'] | Where-Object { $_['displayName'] -eq 'Healthy' }).Count -eq 1
) ($r.Output)
Check 'Both scripts were attempted'   ($created.Count -eq 2) "got $($created.Count)"
Check 'Partial failure exits 2'       ($r.ExitCode -eq 2) "got $($r.ExitCode)"
Check 'Failure is named in a summary' ($r.Output -match '(?s)Failed:.*Doomed') $r.Output
Check 'Graph error text is surfaced'  ($r.Output -match 'BadRequest') $r.Output

# --------------------------------------------------------------- Test 20
# -StopOnError abandons the rest of the run and exits 1 instead. The doomed
# script is put in user/ because Find-WizardScripts scans user/ before device/,
# so it is guaranteed to be the one attempted first.
$ws = New-Workspace -Scripts @(
    @{ Rel = 'user/Doomed.ps1';    Body = $bodyA }
    @{ Rel = 'device/Healthy.ps1'; Body = $bodyB }
)
$r = Invoke-Wizard -Workspace $ws -State @{ scripts = @(); failCreate = 'Doomed' } -WizardArgs @('-StopOnError')
$created = @($r.Calls | Where-Object { $_['call'] -eq 'New-MgBetaDeviceManagementScript' })
Check '-StopOnError stops after the first failure' ($created.Count -eq 1) "got $($created.Count)"
Check '-StopOnError exits 1'                       ($r.ExitCode -eq 1) "got $($r.ExitCode)"
Check '-StopOnError says it stopped early'         ($r.Output -match 'not attempted') $r.Output

# --------------------------------------------------------------- Test 21
# Fatal pre-flight failures exit 1 and reach stderr, not just the host.
$env:PSModulePath = $stubs
# Stderr goes to its own file: merging it into the success stream would prove
# only that the message exists somewhere, not that an unattended caller watching
# stderr alone would see it.
$errFile = Join-Path $scratch 'fatal-stderr.txt'
& pwsh -NoProfile -File (Join-Path $repo 'Deploy-IntuneScripts.ps1') `
    -Path (Join-Path $scratch 'does-not-exist') 2>$errFile | Out-Null
$code = $LASTEXITCODE
$stderr = (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)
Check 'Fatal error exits 1'          ($code -eq 1) "got $code"
Check 'Fatal error reaches stderr'   ($stderr -match 'does not exist or is not a folder') "[$stderr]"

# --------------------------------------------------------------- Test 22
# A tenant that withholds a requested scope is caught at sign-in, not later.
$ws = New-Workspace -Scripts @(@{ Rel = 'device/By-Name.ps1'; Body = "#group:`"Helpdesk Laptops`"`n$bodyA" })
$r = Invoke-Wizard -Workspace $ws -State @{
    scripts = @(); groups = $directory; denyScopes = @('GroupMember.Read.All')
}
$created = @($r.Calls | Where-Object { $_['call'] -eq 'New-MgBetaDeviceManagementScript' })
Check 'Ungranted scope aborts the run' ($r.Output -match 'did not grant') $r.Output
Check 'Ungranted scope deploys nothing' ($created.Count -eq 0) "got $($created.Count)"
Check 'Ungranted scope exits 1'         ($r.ExitCode -eq 1) "got $($r.ExitCode)"

# --------------------------------------------------------------- Test 23
# A near-duplicate with no -OnFuzzyMatch must fail in a session that cannot
# prompt, rather than silently skipping or silently creating a duplicate.
$ws = New-Workspace -Scripts @(@{ Rel = 'device/Script-A.ps1'; Body = "$bodyA# v2`n" })
$state = @{ groups = @(); scripts = @(@{
    id = 'existing-fuzzy'; displayName = 'Script-B'; description = ''
    fileName = 'Script-B.ps1'
    scriptContent = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($bodyB))
    runAsAccount = 'system'; enforceSignatureCheck = $false; runAs32Bit = $true
    roleScopeTagIds = @('0'); lastModifiedDateTime = (Get-Date).ToString('o'); assignments = @()
}) }
$r = Invoke-Wizard -Workspace $ws -State $state
$created = @($r.Calls | Where-Object { $_['call'] -eq 'New-MgBetaDeviceManagementScript' })
Check 'Unattended fuzzy match fails loudly' ($r.Output -match 'cannot prompt') $r.Output
Check 'Unattended fuzzy match creates nothing' ($created.Count -eq 0) "got $($created.Count)"

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
# Helpers for the restore-edge-case tests below: they all need a workspace with
# a hand-written backup file in it, rather than one produced by a deploy run.
function New-BackupWorkspace {
    param([hashtable]$State, [hashtable[]]$Backups)
    $ws = Join-Path $scratch "ws-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path (Join-Path $ws 'backups') -Force | Out-Null
    foreach ($b in $Backups) {
        ($b.Content | ConvertTo-Json -Depth 20) |
            Set-Content -LiteralPath (Join-Path $ws "backups/$($b.Name)")
    }
    ($State | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath (Join-Path $ws '_state.json')
    Set-Content -LiteralPath (Join-Path $ws '_calls.jsonl') -Value '' -NoNewline
    return $ws
}
function Invoke-Restore {
    param([string]$Workspace, [string[]]$WizardArgs)
    $env:WIZTEST_STATE = Join-Path $Workspace '_state.json'
    $env:WIZTEST_CALLS = Join-Path $Workspace '_calls.jsonl'
    $env:PSModulePath  = $stubs
    $out = & pwsh -NoProfile -File (Join-Path $repo 'Deploy-IntuneScripts.ps1') -Path $Workspace @WizardArgs 2>&1 | Out-String
    $code = $LASTEXITCODE
    $calls = @()
    foreach ($line in (Get-Content -LiteralPath $env:WIZTEST_CALLS | Where-Object { $_ })) {
        $calls += ($line | ConvertFrom-Json -AsHashtable)
    }
    return [pscustomobject]@{
        Output = $out; ExitCode = $code; Calls = $calls
        State = (Get-Content -LiteralPath $env:WIZTEST_STATE -Raw | ConvertFrom-Json -AsHashtable)
    }
}
function New-BackupContent {
    param([string]$Id, [string]$Name, [string]$Body, $Tags = @('0'), $Stamp = $null, [bool]$Run32 = $true)
    $content = @{
        SchemaVersion = 3; Id = $Id; DisplayName = $Name; Description = 'd'
        FileName = 'x.ps1'
        ScriptContent = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Body))
        RunAsAccount = 'system'; EnforceSignatureCheck = $false; RunAs32Bit = $Run32
        Assignments = @(); ReplacedByDisplayName = ''; ReplacedByContentHash = ''
    }
    if ($null -ne $Tags)  { $content['RoleScopeTagIds'] = $Tags }
    if ($Stamp)           { $content['BackedUpAt'] = $Stamp }
    return $content
}
function New-TenantScript {
    param([string]$Id, [string]$Name, [string]$Body, $Tags = @('0'), [bool]$Run32 = $true, $Assignments = @())
    return @{
        id = $Id; displayName = $Name; description = 'd'; fileName = 'x.ps1'
        scriptContent = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Body))
        runAsAccount = 'system'; enforceSignatureCheck = $false; runAs32Bit = $Run32
        roleScopeTagIds = $Tags; lastModifiedDateTime = (Get-Date).ToString('o')
        assignments = $Assignments
    }
}

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
. (Join-Path $repo 'lib/GraphOps.ps1')
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

# --------------------------------------------------------------- Test 40
# -Backup snapshots one existing script by name, with no local scan or Graph
# write - a plain workspace with no user/device folders is enough to prove it.
$ws = New-Workspace -Scripts @()
$state = @{ scripts = @(
    (New-TenantScript -Id 'backup-1' -Name 'Payroll Script' -Body $bodyA)
    (New-TenantScript -Id 'backup-2' -Name 'Other Script'   -Body $bodyB)
) }
$r = Invoke-Wizard -Workspace $ws -State $state -WizardArgs @('-Backup', 'Payroll Script')
$backupFiles = @(Get-ChildItem -LiteralPath (Join-Path $ws 'backups') -Filter '*.json' -ErrorAction SilentlyContinue)
Check '-Backup by name exits 0'          ($r.ExitCode -eq 0) "got $($r.ExitCode)`n$($r.Output)"
Check '-Backup by name wrote one file'   ($backupFiles.Count -eq 1) "got $($backupFiles.Count)"
$backedUp = Get-Content -LiteralPath $backupFiles[0].FullName -Raw | ConvertFrom-Json -AsHashtable
Check '-Backup by name backed up the right script' ($backedUp['Id'] -eq 'backup-1') "got $($backedUp['Id'])"
Check '-Backup made no create/update call' (@($r.Calls | Where-Object { $_['call'] -in @('New-MgBetaDeviceManagementScript', 'Update-MgBetaDeviceManagementScript') }).Count -eq 0) 'a write call was made'

# -Backup by Id takes the same path. Needs a GUID-shaped Id: that is what
# tells Resolve-WizardBackupTargets to match on Id rather than display name.
$guidState = @{ scripts = @((New-TenantScript -Id 'aaaaaaaa-1111-2222-3333-444444444444' -Name 'Guid Script' -Body $bodyA)) }
$ws = New-Workspace -Scripts @()
$r = Invoke-Wizard -Workspace $ws -State $guidState -WizardArgs @('-Backup', 'aaaaaaaa-1111-2222-3333-444444444444')
$backupFiles = @(Get-ChildItem -LiteralPath (Join-Path $ws 'backups') -Filter '*.json' -ErrorAction SilentlyContinue)
Check '-Backup by Id exits 0'        ($r.ExitCode -eq 0) "got $($r.ExitCode)`n$($r.Output)"
Check '-Backup by Id wrote one file' ($backupFiles.Count -eq 1) "got $($backupFiles.Count)"
$backedUp = Get-Content -LiteralPath $backupFiles[0].FullName -Raw | ConvertFrom-Json -AsHashtable
Check '-Backup by Id backed up the right script' ($backedUp['Id'] -eq 'aaaaaaaa-1111-2222-3333-444444444444') "got $($backedUp['Id'])"

# --------------------------------------------------------------- Test 41
# -BackupAll snapshots every script in the tenant in one run.
$ws = New-Workspace -Scripts @()
$r = Invoke-Wizard -Workspace $ws -State $state -WizardArgs @('-BackupAll')
$backupFiles = @(Get-ChildItem -LiteralPath (Join-Path $ws 'backups') -Filter '*.json' -ErrorAction SilentlyContinue)
Check '-BackupAll exits 0'            ($r.ExitCode -eq 0) "got $($r.ExitCode)`n$($r.Output)"
Check '-BackupAll backed up both'     ($backupFiles.Count -eq 2) "got $($backupFiles.Count)"

# --------------------------------------------------------------- Test 42
# -Backup usage errors: unknown name, ambiguous name, mutually exclusive flags.
$r = Invoke-Wizard -Workspace $ws -State $state -WizardArgs @('-Backup', 'No Such Script')
Check '-Backup unknown name fails'   ($r.ExitCode -eq 1) "got $($r.ExitCode)"
Check '-Backup unknown name says so' ($r.Output -match 'No script named') $r.Output

$dupeState = @{ scripts = @(
    (New-TenantScript -Id 'dupe-a' -Name 'Same Name' -Body $bodyA)
    (New-TenantScript -Id 'dupe-b' -Name 'Same Name' -Body $bodyB)
) }
$r = Invoke-Wizard -Workspace $ws -State $dupeState -WizardArgs @('-Backup', 'Same Name')
Check '-Backup ambiguous name fails'   ($r.ExitCode -eq 1) "got $($r.ExitCode)"
Check '-Backup ambiguous name says so' ($r.Output -match 'is ambiguous') $r.Output

$r = Invoke-Wizard -Workspace $ws -State @{ scripts = @() } -WizardArgs @('-Backup', 'X', '-BackupAll')
Check '-Backup with -BackupAll is refused' ($r.Output -match 'mutually exclusive') $r.Output
Check '-Backup with -BackupAll exits 1'    ($r.ExitCode -eq 1) "got $($r.ExitCode)"

$r = Invoke-Wizard -Workspace $ws -State @{ scripts = @() } -WizardArgs @('-BackupAll', '-Restore', 'anything.json')
Check '-BackupAll with -Restore is refused' ($r.Output -match 'cannot be combined with -Restore') $r.Output
Check '-BackupAll with -Restore exits 1'    ($r.ExitCode -eq 1) "got $($r.ExitCode)"

# -DryRun with -Backup lists the target and writes nothing.
$ws = New-Workspace -Scripts @()
$r = Invoke-Wizard -Workspace $ws -State $state -WizardArgs @('-Backup', 'Payroll Script', '-DryRun')
$backupFiles = @(Get-ChildItem -LiteralPath (Join-Path $ws 'backups') -Filter '*.json' -ErrorAction SilentlyContinue)
Check '-DryRun with -Backup exits 0'       ($r.ExitCode -eq 0) "got $($r.ExitCode)`n$($r.Output)"
Check '-DryRun with -Backup writes nothing' ($backupFiles.Count -eq 0) "got $($backupFiles.Count)"
Check '-DryRun with -Backup names the target' ($r.Output -match '(?s)Would back up.*Payroll Script') $r.Output

Write-Host ""
Write-Host "$pass passed, $fail failed" -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })

if ($KeepWorkspaces) {
    Write-Host "Workspaces kept at $WorkRoot"
} else {
    Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
}

exit $fail
