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
