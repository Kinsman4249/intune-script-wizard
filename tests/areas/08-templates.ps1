# --------------------------------------------------------------- Templates
# -BackupAll's .ps1 template export. Exercised end to end through the real
# entry point; New-WizardTemplateHeader and Format-WizardGroupDirective are
# pure enough to also unit-test directly - see the block near the end of this
# section. The header/byte helpers live in TemplateHeader.ps1, the export
# orchestration in Template.ps1.
. (Join-Path $repo 'lib/Logging.ps1')
. (Join-Path $repo 'lib/GraphAuth.ps1')
. (Join-Path $repo 'lib/Storage.ps1')
. (Join-Path $repo 'lib/Parsing.ps1')
. (Join-Path $repo 'lib/TemplateHeader.ps1')
. (Join-Path $repo 'lib/Template.ps1')

function Get-WizardTemplateBodyTail {
    # Everything after the end-marker line, read back out of an exported
    # template file - used to assert the original body survived untouched.
    param([string]$Path)
    $raw = Get-Content -LiteralPath $Path -Raw
    $marker = '# --- end intune-script-wizard template ---'
    $idx = $raw.IndexOf($marker)
    if ($idx -lt 0) { return $null }
    $eol = $raw.IndexOf("`n", $idx)
    if ($eol -lt 0) { return '' }
    return $raw.Substring($eol + 1)
}

$tplHelpdeskId = 'aaaa1111-2222-3333-4444-555566667777'
$tplPilotId    = 'bbbb1111-2222-3333-4444-555566667777'
$tplUnknownId  = 'cccc1111-2222-3333-4444-555566667777'
$tplGroups = @(
    @{ id = $tplHelpdeskId; displayName = 'Helpdesk Laptops' }
    @{ id = $tplPilotId;    displayName = 'Pilot Ring' }
)
$tplDeviceBody = "# device template source`nWrite-Host 'device'`n"
$tplUserBody   = "# user template source`nWrite-Host 'user'`n"
$tplAllBody    = "# all-devices template source`nWrite-Host 'all'`n"
$tplUnkBody    = "# unknown-group template source`nWrite-Host 'unknown'`n"

$tplState = @{
    groups = $tplGroups
    scripts = @(
        @{
            id = 'tpl-device-1'; displayName = 'Device Template Script'; description = 'd'
            fileName = 'd.ps1'
            scriptContent = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($tplDeviceBody))
            runAsAccount = 'system'; enforceSignatureCheck = $false; runAs32Bit = $true
            roleScopeTagIds = @('0'); lastModifiedDateTime = (Get-Date).ToString('o')
            assignments = @(
                @{ id = 'a1'; target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $tplHelpdeskId } }
                @{ id = 'a2'; target = @{ '@odata.type' = '#microsoft.graph.exclusionGroupAssignmentTarget'; groupId = $tplPilotId } }
            )
        }
        @{
            id = 'tpl-user-1'; displayName = 'User Template Script'; description = "Line one`nLine two"
            fileName = 'u.ps1'
            scriptContent = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($tplUserBody))
            runAsAccount = 'user'; enforceSignatureCheck = $true; runAs32Bit = $false
            roleScopeTagIds = @('0'); lastModifiedDateTime = (Get-Date).ToString('o')
            assignments = @()
        }
        @{
            id = 'tpl-alldevices-1'; displayName = 'AllDevices Template Script'; description = ''
            fileName = 'a.ps1'
            scriptContent = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($tplAllBody))
            runAsAccount = 'system'; enforceSignatureCheck = $false; runAs32Bit = $true
            roleScopeTagIds = @('0'); lastModifiedDateTime = (Get-Date).ToString('o')
            assignments = @(@{ id = 'a3'; target = @{ '@odata.type' = '#microsoft.graph.allDevicesAssignmentTarget' } })
        }
        @{
            id = 'tpl-unknown-1'; displayName = 'Unknown Group Script'; description = ''
            fileName = 'g.ps1'
            scriptContent = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($tplUnkBody))
            runAsAccount = 'system'; enforceSignatureCheck = $false; runAs32Bit = $true
            roleScopeTagIds = @('0'); lastModifiedDateTime = (Get-Date).ToString('o')
            assignments = @(@{ id = 'a4'; target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $tplUnknownId } })
        }
    )
}

$tplWs = New-Workspace -Scripts @()
$rTpl = Invoke-Wizard -Workspace $tplWs -State $tplState -WizardArgs @('-BackupAll')
Check 'Templates: -BackupAll (with export) exits 0' ($rTpl.ExitCode -eq 0) "got $($rTpl.ExitCode)`n$($rTpl.Output)"

$tplDeviceDir = Join-Path $tplWs 'templates/device'
$tplUserDir   = Join-Path $tplWs 'templates/user'
Check 'Templates: device/ folder created' (Test-Path -LiteralPath $tplDeviceDir) $rTpl.Output
Check 'Templates: user/ folder created'   (Test-Path -LiteralPath $tplUserDir) $rTpl.Output

$devicePath  = Join-Path $tplDeviceDir 'Device_Template_Script.ps1'
$userPath    = Join-Path $tplUserDir   'User_Template_Script.ps1'
$allPath     = Join-Path $tplDeviceDir 'AllDevices_Template_Script.ps1'
$unknownPath = Join-Path $tplDeviceDir 'Unknown_Group_Script.ps1'
Check 'Templates: device template file written'       (Test-Path -LiteralPath $devicePath) "dir: $(Get-ChildItem $tplDeviceDir -ErrorAction SilentlyContinue)"
Check 'Templates: user template file written'          (Test-Path -LiteralPath $userPath) "dir: $(Get-ChildItem $tplUserDir -ErrorAction SilentlyContinue)"
Check 'Templates: all-devices template file written'   (Test-Path -LiteralPath $allPath) $rTpl.Output
Check 'Templates: unknown-group template file written' (Test-Path -LiteralPath $unknownPath) $rTpl.Output

# The round-trip assertion the whole feature stands on: parsing an exported
# file back out must reproduce the tenant state that produced it.
$deviceMeta = Get-ScriptMetadata -Path $devicePath -FolderType 'device'
Check 'Round-trip: device DisplayName'           ($deviceMeta.DisplayName -eq 'Device Template Script') "got $($deviceMeta.DisplayName)"
Check 'Round-trip: device Description'           ($deviceMeta.Description -eq 'd') "got '$($deviceMeta.Description)'"
Check 'Round-trip: device Type'                  ($deviceMeta.Type -eq 'device') "got $($deviceMeta.Type)"
Check 'Round-trip: device EnforceSignatureCheck' ($deviceMeta.EnforceSignatureCheck -eq $false) "got $($deviceMeta.EnforceSignatureCheck)"
Check 'Round-trip: device RunAs32Bit'            ($deviceMeta.RunAs32Bit -eq $true) "got $($deviceMeta.RunAs32Bit)"
Check 'Round-trip: device GroupRefs'             (($deviceMeta.GroupRefs -join ',') -eq 'Helpdesk Laptops') "got $($deviceMeta.GroupRefs -join ',')"
Check 'Round-trip: device ExcludeGroupRefs'      (($deviceMeta.ExcludeGroupRefs -join ',') -eq 'Pilot Ring') "got $($deviceMeta.ExcludeGroupRefs -join ',')"
Check 'Round-trip: device NoAssignments'         ($deviceMeta.NoAssignments -eq $false) "got $($deviceMeta.NoAssignments)"

$userMeta = Get-ScriptMetadata -Path $userPath -FolderType 'user'
Check 'Round-trip: user DisplayName'                      ($userMeta.DisplayName -eq 'User Template Script') "got $($userMeta.DisplayName)"
Check 'Round-trip: user Description'                      ($userMeta.Description -eq "Line one`nLine two") "got '$($userMeta.Description)'"
Check 'Round-trip: user Type'                             ($userMeta.Type -eq 'user') "got $($userMeta.Type)"
Check 'Round-trip: user EnforceSignatureCheck'            ($userMeta.EnforceSignatureCheck -eq $true) "got $($userMeta.EnforceSignatureCheck)"
Check 'Round-trip: user RunAs32Bit'                       ($userMeta.RunAs32Bit -eq $false) "got $($userMeta.RunAs32Bit)"
Check 'Round-trip: user NoAssignments (zero assignments)' ($userMeta.NoAssignments -eq $true) "got $($userMeta.NoAssignments)"

$allMeta = Get-ScriptMetadata -Path $allPath -FolderType 'device'
Check 'Round-trip: all-devices target -> no #group:, no #noassignments' (
    $allMeta.GroupRefs.Count -eq 0 -and $allMeta.ExcludeGroupRefs.Count -eq 0 -and -not $allMeta.NoAssignments
) "GroupRefs=$($allMeta.GroupRefs -join ','); NoAssignments=$($allMeta.NoAssignments)"

# Body bytes after the end marker must be byte-identical to the original -
# proven at the text level here since every body in this section is plain ASCII.
Check 'Body tail unchanged: device' ((Get-WizardTemplateBodyTail $devicePath) -eq $tplDeviceBody) "got '$(Get-WizardTemplateBodyTail $devicePath)'"
Check 'Body tail unchanged: user'   ((Get-WizardTemplateBodyTail $userPath) -eq $tplUserBody) "got '$(Get-WizardTemplateBodyTail $userPath)'"

# Unknown group id: degrades to a bare GUID plus a warning, and the run still
# exits 0 rather than failing the whole backup over one deleted group.
$unknownText = Get-Content -LiteralPath $unknownPath -Raw
Check 'Unknown group: exported as bare GUID'  ($unknownText -match [regex]::Escape("#group:$tplUnknownId")) $unknownText
Check 'Unknown group: no quoted name emitted' (-not ($unknownText -match '#group:"')) $unknownText
Check 'Unknown group: warning explains why'   ($rTpl.Output -match 'could not be resolved to a display name') $rTpl.Output
Check 'Unknown group: run still exits 0'      ($rTpl.ExitCode -eq 0) "got $($rTpl.ExitCode)"

# ----------------------------------------------------- Templates: idempotence
$firstDeviceText = Get-Content -LiteralPath $devicePath -Raw
$rTpl2 = Invoke-Wizard -Workspace $tplWs -State $tplState -WizardArgs @('-BackupAll')
Check 'Templates: second -BackupAll exits 0'                   ($rTpl2.ExitCode -eq 0) "got $($rTpl2.ExitCode)`n$($rTpl2.Output)"
Check 'Templates: second run reports 0 written, all unchanged' ($rTpl2.Output -match 'Templates: 0 written, 4 unchanged, 0 excluded \(#notemplate\), 0 skipped, 0 failed') $rTpl2.Output
Check 'Templates: second run left the file with exactly one header' (
    ([regex]::Matches((Get-Content -LiteralPath $devicePath -Raw), [regex]::Escape('# --- intune-script-wizard template ---'))).Count -eq 1
) 'more than one header block found'
Check 'Templates: unchanged file is byte-identical' ((Get-Content -LiteralPath $devicePath -Raw) -eq $firstDeviceText) 'file content drifted on an unchanged export'

# A tenant script that changed since the last export cannot be silently
# overwritten in a non-interactive session: it must warn and skip (there is
# nobody to answer a prompt), and must not touch the file on disk either.
$tplStateMutated = @{ groups = $tplGroups; scripts = @($tplState['scripts'] | ForEach-Object {
    $copy = $_.Clone()
    if ($copy['id'] -eq 'tpl-device-1') { $copy['description'] = 'a changed description' }
    $copy
}) }
$rTpl3 = Invoke-Wizard -Workspace $tplWs -State $tplStateMutated -WizardArgs @('-BackupAll')
Check 'Templates: mutated tenant script is skipped, not overwritten' ($rTpl3.Output -match 'Templates: 0 written, 3 unchanged, 0 excluded \(#notemplate\), 1 skipped, 0 failed') $rTpl3.Output
Check 'Templates: skip is explained as cannot-prompt'                ($rTpl3.Output -match 'cannot prompt; skipping') $rTpl3.Output
Check 'Templates: skipped file is untouched'                        ((Get-Content -LiteralPath $devicePath -Raw) -eq $firstDeviceText) 'file was overwritten despite being skipped'

# ----------------------------------------------------- Templates: -NoTemplates
$noTplWs = New-Workspace -Scripts @()
$rNoTpl = Invoke-Wizard -Workspace $noTplWs -State $tplState -WizardArgs @('-BackupAll', '-NoTemplates')
Check '-NoTemplates: exits 0'                   ($rNoTpl.ExitCode -eq 0) "got $($rNoTpl.ExitCode)`n$($rNoTpl.Output)"
Check '-NoTemplates: creates no templates/ dir' (-not (Test-Path -LiteralPath (Join-Path $noTplWs 'templates'))) 'templates/ was created despite -NoTemplates'
$noTplBackups = @(Get-ChildItem -LiteralPath (Join-Path $noTplWs 'backups') -Filter '*.json' -ErrorAction SilentlyContinue)
Check '-NoTemplates: still writes JSON backups' ($noTplBackups.Count -eq 4) "got $($noTplBackups.Count)"

$r = Invoke-Wizard -Workspace (New-Workspace -Scripts @()) -State @{ scripts = @() } -WizardArgs @('-NoTemplates')
Check '-NoTemplates without -Backup/-BackupAll is refused' ($r.Output -match 'only applies to -Backup/-BackupAll') $r.Output
Check '-NoTemplates without -Backup/-BackupAll exits 1'    ($r.ExitCode -eq 1) "got $($r.ExitCode)"

# ----------------------------------------------------- Templates: #notemplate
$notplBody = "#notemplate`n$tplDeviceBody"
$notplState = @{ groups = @(); scripts = @(@{
    id = 'tpl-notpl-1'; displayName = 'Excluded Script'; description = ''
    fileName = 'e.ps1'
    scriptContent = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($notplBody))
    runAsAccount = 'system'; enforceSignatureCheck = $false; runAs32Bit = $true
    roleScopeTagIds = @('0'); lastModifiedDateTime = (Get-Date).ToString('o'); assignments = @()
}) }
$notplWs = New-Workspace -Scripts @()
$rNotpl = Invoke-Wizard -Workspace $notplWs -State $notplState -WizardArgs @('-BackupAll')
Check '#notemplate: run exits 0'               ($rNotpl.ExitCode -eq 0) "got $($rNotpl.ExitCode)`n$($rNotpl.Output)"
Check '#notemplate: JSON backup still written' ((@(Get-ChildItem -LiteralPath (Join-Path $notplWs 'backups') -Filter '*.json')).Count -eq 1) 'no JSON backup found'
Check '#notemplate: no template file written'  (-not (Test-Path -LiteralPath (Join-Path $notplWs 'templates/device/Excluded_Script.ps1'))) 'a template file was written despite #notemplate'
Check '#notemplate: counted as excluded'       ($rNotpl.Output -match 'Templates: 0 written, 0 unchanged, 1 excluded \(#notemplate\)') $rNotpl.Output

# The tag behind a previously-written header is still honoured: the header
# must be stripped BEFORE the #notemplate check runs, or a script re-exported
# after being tagged would slip through hidden behind its own old header.
$oldHeader = (New-WizardTemplateHeader -TenantId 'tenant-x' -ExportedAt (Get-Date) -DisplayName 'Excluded Script' -Type 'device').Text
$behindHeaderBody = "$oldHeader#notemplate`n$tplDeviceBody"
$notplState2 = @{ groups = @(); scripts = @(@{
    id = 'tpl-notpl-2'; displayName = 'Excluded Script 2'; description = ''
    fileName = 'e2.ps1'
    scriptContent = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($behindHeaderBody))
    runAsAccount = 'system'; enforceSignatureCheck = $false; runAs32Bit = $true
    roleScopeTagIds = @('0'); lastModifiedDateTime = (Get-Date).ToString('o'); assignments = @()
}) }
$notplWs2 = New-Workspace -Scripts @()
$rNotpl2 = Invoke-Wizard -Workspace $notplWs2 -State $notplState2 -WizardArgs @('-BackupAll')
Check '#notemplate behind an old header is still honoured' ($rNotpl2.Output -match 'Templates: 0 written, 0 unchanged, 1 excluded \(#notemplate\)') $rNotpl2.Output

# A stale template file left over from before the tag was added is never
# auto-deleted - that decision belongs to whoever curates the templates repo.
$staleDir = Join-Path $notplWs 'templates/device'
New-Item -ItemType Directory -Path $staleDir -Force | Out-Null
$stalePath = Join-Path $staleDir 'Excluded_Script.ps1'
Set-Content -LiteralPath $stalePath -Value 'stale content' -NoNewline
$rNotpl3 = Invoke-Wizard -Workspace $notplWs -State $notplState -WizardArgs @('-BackupAll')
Check '#notemplate: stale template file is not deleted' ((Get-Content -LiteralPath $stalePath -Raw) -eq 'stale content') 'the stale file was modified or removed'
Check '#notemplate: stale template file warns'           ($rNotpl3.Output -match 'template file still exists') $rNotpl3.Output

# Get-ScriptMetadata sets NoTemplate, and it never affects deployment - a
# local script carrying it deploys exactly like any other.
$localNotplWs = New-Workspace -Scripts @(@{ Rel = 'device/Local-Excluded.ps1'; Body = "#notemplate`n$bodyA" })
$localMeta = Get-ScriptMetadata -Path (Join-Path $localNotplWs 'device/Local-Excluded.ps1') -FolderType 'device'
Check '#notemplate: Get-ScriptMetadata sets NoTemplate' ($localMeta.NoTemplate -eq $true) "got $($localMeta.NoTemplate)"
$rLocalNotpl = Invoke-Wizard -Workspace $localNotplWs -State @{ scripts = @() }
$localCreated = @($rLocalNotpl.Calls | Where-Object { $_['call'] -eq 'New-MgBetaDeviceManagementScript' })
Check '#notemplate: local script still deploys' ($localCreated.Count -eq 1) "got $($localCreated.Count)"

# ------------------------------------------- Templates: inert ##typeoverride:yes
$deviceRaw = Get-Content -LiteralPath $devicePath -Raw
Check '##typeoverride:yes hint is present'   ($deviceRaw -match '##typeoverride:yes') $deviceRaw
Check 'No live #typeoverride:yes is stamped' (-not ($deviceRaw -match '(?m)^#typeoverride\s*:\s*yes\s*$')) $deviceRaw

# Move the exported device template into user/ and confirm the folder wins
# on the #type: conflict - the reclassification path stays open precisely
# because the hint is inert.
$movedDir = Join-Path $tplWs 'moved-user'
New-Item -ItemType Directory -Path $movedDir -Force | Out-Null
$movedPath = Join-Path $movedDir 'Moved.ps1'
Copy-Item -LiteralPath $devicePath -Destination $movedPath
$warnFile = Join-Path $scratch 'typeoverride-warn.txt'
$movedMeta = Get-ScriptMetadata -Path $movedPath -FolderType 'user' 3>$warnFile
$warnText = Get-Content -LiteralPath $warnFile -Raw -ErrorAction SilentlyContinue
Check 'Moved template: folder wins over the inert #type:device' ($movedMeta.Type -eq 'user') "got $($movedMeta.Type)"
Check 'Moved template: conflict is warned about'                ($warnText -match "conflicts with its 'user' folder") $warnText

# ----------------------------------------------------- Templates: scope degradation
$degradeState = @{
    groups = $tplGroups
    scripts = @(@{
        id = 'tpl-degrade-1'; displayName = 'Degrade Script'; description = ''
        fileName = 'de.ps1'
        scriptContent = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($tplDeviceBody))
        runAsAccount = 'system'; enforceSignatureCheck = $false; runAs32Bit = $true
        roleScopeTagIds = @('0'); lastModifiedDateTime = (Get-Date).ToString('o')
        assignments = @(@{ id = 'a1'; target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $tplHelpdeskId } })
    })
    denyScopes = @('GroupMember.Read.All')
}
$degradeWs = New-Workspace -Scripts @()
$rDegrade = Invoke-Wizard -Workspace $degradeWs -State $degradeState -WizardArgs @('-BackupAll')
Check 'Scope degradation: run still exits 0' ($rDegrade.ExitCode -eq 0) "got $($rDegrade.ExitCode)`n$($rDegrade.Output)"
$degradePath = Join-Path $degradeWs 'templates/device/Degrade_Script.ps1'
$degradeText = Get-Content -LiteralPath $degradePath -Raw
Check 'Scope degradation: exported as a bare GUID'        ($degradeText -match [regex]::Escape("#group:$tplHelpdeskId")) $degradeText
Check 'Scope degradation: no group name leaked in'         (-not ($degradeText -match 'Helpdesk Laptops')) $degradeText
Check 'Scope degradation: warns about the declined scope' ($rDegrade.Output -match 'could not be resolved to a display name') $rDegrade.Output

# ------------------------------------------ Templates: New-WizardTemplateHeader unit checks
$quoteResult = New-WizardTemplateHeader -TenantId 't' -ExportedAt (Get-Date) -DisplayName 'My "Special" Script' -Type 'device'
Check 'Header: quoted display name is stripped and warned' (
    $quoteResult.Text -match '#scriptname:"My Special Script"' -and $quoteResult.Warnings.Count -eq 1
) $quoteResult.Text

$enddescResult = New-WizardTemplateHeader -TenantId 't' -ExportedAt (Get-Date) -DisplayName 'Desc Script' -Type 'device' -Description "line one`nenddesc`nline three"
Check 'Header: a literal enddesc line falls back to plain comments' (
    -not ($enddescResult.Text -match '(?m)^#startdesc\s*$') -and $enddescResult.Text -match '(?m)^# enddesc\s*$' -and $enddescResult.Warnings.Count -eq 1
) $enddescResult.Text

$crlfResult = New-WizardTemplateHeader -TenantId 't' -ExportedAt (Get-Date) -DisplayName 'Crlf Script' -Type 'device' -NewLine "`r`n"
Check 'Header: CRLF NewLine is honoured throughout' (
    $crlfResult.Text -match "`r`n" -and -not ($crlfResult.Text -replace "`r`n", '' -match "`n")
) 'CRLF not found, or a bare LF slipped through'

$guidNameResult = Format-WizardGroupDirective -Entry @{ Id = $tplHelpdeskId; Name = $tplPilotId } -Directive 'group'
Check 'Header: a group display name that itself parses as a GUID falls back' (
    $guidNameResult.Line -eq "#group:$tplHelpdeskId" -and $guidNameResult.Warning -match 'looks like a GUID'
) $guidNameResult.Line

# ----------------------------------------------------- Templates: end-to-end promote
# Export from tenant-state A (above), then run the real entry point with
# -Path pointed at a fresh templates root holding just the one exported
# script, against an empty tenant, and confirm the promoted script lands
# with the same shape. A dedicated root (rather than pointing -Path at
# $tplDeviceDir, which also holds the other scenarios' exports) keeps this
# to exactly one create. Invoke-Wizard isn't used here because it always
# supplies its own -Path; this needs a different one.
$promoteRoot = Join-Path $scratch 'promote-templates'
New-Item -ItemType Directory -Path (Join-Path $promoteRoot 'device') -Force | Out-Null
Copy-Item -LiteralPath $devicePath -Destination (Join-Path $promoteRoot 'device/Device_Template_Script.ps1')

$promoteStatePath = Join-Path $scratch 'promote-state.json'
$promoteCallsPath = Join-Path $scratch 'promote-calls.jsonl'
(@{ scripts = @(); groups = $tplGroups } | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $promoteStatePath
Set-Content -LiteralPath $promoteCallsPath -Value '' -NoNewline
$env:WIZTEST_STATE = $promoteStatePath
$env:WIZTEST_CALLS = $promoteCallsPath
$env:PSModulePath  = $stubs
$promoteOut = & pwsh -NoProfile -File (Join-Path $repo 'Deploy-IntuneScripts.ps1') -Path $promoteRoot -OnFuzzyMatch SideBySide 2>&1 | Out-String
$promoteExit = $LASTEXITCODE
$promoteCalls = @(Get-Content -LiteralPath $promoteCallsPath | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable })
$promoteState = Get-Content -LiteralPath $promoteStatePath -Raw | ConvertFrom-Json -AsHashtable

$promoteCreated = @($promoteCalls | Where-Object { $_['call'] -eq 'New-MgBetaDeviceManagementScript' })
Check 'Promote: exited 0'                           ($promoteExit -eq 0) "got $promoteExit`n$promoteOut"
Check 'Promote: exported template deploys cleanly'  ($promoteCreated.Count -eq 1) "got $($promoteCreated.Count): $promoteOut"
Check 'Promote: displayName matches the original'   ($promoteCreated[0]['data']['displayName'] -eq 'Device Template Script') "got $($promoteCreated[0]['data']['displayName'])"
Check 'Promote: runAsAccount matches the original'  ($promoteCreated[0]['data']['runAsAccount'] -eq 'system') "got $($promoteCreated[0]['data']['runAsAccount'])"
Check 'Promote: enforceSignatureCheck matches'      ($promoteCreated[0]['data']['enforceSignatureCheck'] -eq $false) "got $($promoteCreated[0]['data']['enforceSignatureCheck'])"
Check 'Promote: runAs32Bit matches the original'    ($promoteCreated[0]['data']['runAs32Bit'] -eq $true) "got $($promoteCreated[0]['data']['runAs32Bit'])"

$promotedTargets = @($promoteState['scripts'] | Where-Object { $_['displayName'] -eq 'Device Template Script' } | ForEach-Object { $_['assignments'] } | ForEach-Object { $_['target'] })
$promotedTypes = @($promotedTargets | ForEach-Object { $_['@odata.type'] }) | Sort-Object
Check 'Promote: assignment targets match (include + exclude)' (
    ($promotedTypes -join ',') -eq '#microsoft.graph.exclusionGroupAssignmentTarget,#microsoft.graph.groupAssignmentTarget' -and
    ($promotedTargets | Where-Object { $_['@odata.type'] -eq '#microsoft.graph.groupAssignmentTarget' }).groupId -eq $tplHelpdeskId -and
    ($promotedTargets | Where-Object { $_['@odata.type'] -eq '#microsoft.graph.exclusionGroupAssignmentTarget' }).groupId -eq $tplPilotId
) ($promotedTargets | ConvertTo-Json -Compress)
