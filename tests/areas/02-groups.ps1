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
