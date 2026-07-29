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
$ws = New-Workspace -Scripts @(
    @{ Rel = 'device/Script-A.ps1'; Body = $bodyA },
    @{ Rel = 'user/Script-B.ps1';   Body = $bodyB }
)
$r = Invoke-Wizard -Workspace $ws -State @{ scripts = @() }
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
Check 'Backup schema version is 2'      ($backup['SchemaVersion'] -eq 2) "got $($backup['SchemaVersion'])"

# Restore that backup and confirm scope tags and the group target come back.
$env:WIZTEST_STATE = Join-Path $ws '_state.json'
$env:WIZTEST_CALLS = Join-Path $ws '_calls.jsonl'
$env:PSModulePath  = $stubs
& pwsh -NoProfile -File (Join-Path $repo 'Deploy-IntuneScripts.ps1') -Path $ws -Restore $backupFile.FullName *>&1 | Out-Null
$after = Get-Content -LiteralPath $env:WIZTEST_STATE -Raw | ConvertFrom-Json -AsHashtable
$restored = $after['scripts'] | Where-Object { $_['id'] -eq 'existing-2' }
Check 'Restore reinstated scope tags'   ((@($restored['roleScopeTagIds']) -join ',') -eq '0,7') "got $(@($restored['roleScopeTagIds']) -join ',')"
Check 'Restore reinstated groupId'      (@($restored['assignments'])[0]['target']['groupId'] -eq 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee') "got $(@($restored['assignments'])[0]['target'] | ConvertTo-Json -Compress)"

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
    $logText = Get-Content -LiteralPath $log.FullName -Raw
    Check 'Debug log carries build stamp' ($logText -match 'build 0\.2\.0\+') $logText
    Check 'Debug log traces Graph calls'  ($logText -match 'Graph context') $logText
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

# --------------------------------------------------------------- Test 13
# The directory-read scope is requested only when a name needs resolving.
$ws = New-Workspace -Scripts @(@{ Rel = 'device/By-Guid.ps1'; Body = "#group:$guid`n$bodyA" })
$r = Invoke-Wizard -Workspace $ws -State @{ scripts = @(); groups = $directory }
$connect = @($r.Calls | Where-Object { $_['call'] -eq 'Connect-MgGraph' })
Check 'GUID-only run does not request group scope' (
    $connect.Count -eq 0 -or -not (@($connect[0]['data']['scopes']) -contains 'GroupMember.Read.All')
) ($connect | ConvertTo-Json -Compress)

$ws = New-Workspace -Scripts @(@{ Rel = 'device/By-Name.ps1'; Body = "#group:`"Helpdesk Laptops`"`n$bodyA" })
$r = Invoke-Wizard -Workspace $ws -State @{ scripts = @(); groups = $directory }
Check 'Name-based run announces the extra scope' ($r.Output -match 'GroupMember\.Read\.All') $r.Output

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

Write-Host ""
Write-Host "$pass passed, $fail failed" -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })

if ($KeepWorkspaces) {
    Write-Host "Workspaces kept at $WorkRoot"
} else {
    Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
}

exit $fail
