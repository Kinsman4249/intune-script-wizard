# Backup.ps1
# Snapshotting an existing Intune script before it is changed, and restoring
# one afterwards. Split out of GraphOps.ps1 because it is a self-contained
# concern with its own on-disk schema to version.

function Get-WizardScriptRunAs32Bit {
    # Reads runAs32Bit off a script object returned by the SDK.
    #
    # Its own function because this property is easy to name wrongly and
    # impossible to notice when you do: PowerShell hands back $null for a
    # property that isn't there, [bool]$null is $false, and $false is itself a
    # legitimate value. A typo therefore writes "runs 64-bit" into every backup
    # and silently flips the setting on the way back in, which is exactly what
    # reading a non-existent RunAs32BitOnWindows64 used to do here.
    param([Parameter(Mandatory)]$Script)

    $property = $Script.PSObject.Properties['RunAs32Bit']
    if (-not $property) {
        throw "The Graph SDK returned script $($Script.Id) with no RunAs32Bit property, so a backup of it would restore under the wrong PowerShell host. Refusing to change it. This normally means the installed Microsoft.Graph.Beta.DeviceManagement module has renamed the property - check for a wizard update."
    }
    return [bool]$property.Value
}

function Backup-WizardScript {
    # Snapshots an existing script's full state to disk before it is changed.
    # param() declares this function's inputs; Mandatory means the caller must
    # supply them or PowerShell will prompt/error before the function body runs.
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$BackupDir,
        # What's about to be pushed in place of the script being backed up, i.e.
        # what "restore" would be undoing. Optional: Restore-WizardBackup only
        # uses this to spot an orphaned duplicate in the rare case where, by
        # restore time, $Id no longer exists and a brand-new script has to be
        # created for it instead of updating in place.
        [string]$ReplacementDisplayName,
        [string]$ReplacementContentHash
    )

    # try/catch runs the risky code in try{}; if it throws, catch{} handles the
    # error instead of the whole script crashing.
    try {
        if (-not (Test-Path -LiteralPath $BackupDir)) {
            New-Item -ItemType Directory -Path $BackupDir -Force -ErrorAction Stop | Out-Null
        }
    } catch {
        throw "Could not create the backup folder '$BackupDir': $($_.Exception.Message). No script is changed without a backup, so the run stops here."
    }

    try {
        $full = Invoke-WizardGraphRetry -What "Reading script $Id to back it up" -Call {
            Get-MgBetaDeviceManagementScript -DeviceManagementScriptId $Id
        }
    } catch {
        throw "Could not read script $Id to back it up: $(Get-WizardErrorSummary -ErrorRecord $_)"
    }
    if (-not $full -or -not $full.Id) {
        throw "Script $Id could not be backed up: the tenant returned nothing for it. It may have been deleted since the run started."
    }
    # Via the shared helper, because the SDK returns this as a byte[] rather
    # than the base64 text the backup file stores. Checking it with
    # IsNullOrWhiteSpace and writing it through unconverted (what this used to
    # do) wrote a JSON array of numbers into the backup, which then failed to
    # base64-decode on the way back in - an unrestorable backup that only
    # announced itself at restore time.
    $contentBytes = Get-WizardScriptContentBytes -Content $full.ScriptContent
    if (-not $contentBytes) {
        throw "Script $Id ('$($full.DisplayName)') came back without any content, so a backup of it would be unrestorable. Refusing to change it."
    }

    $assignments = @(
        Get-WizardScriptAssignments -Id $Id |
            ForEach-Object { ConvertTo-WizardAssignmentPayload -Assignment $_ } |
            Where-Object { $_ }
    )

    # [ordered]@{...} builds a hashtable that remembers key insertion order, so
    # the JSON written to disk lists fields in this same order (plain @{} would not).
    $backup = [ordered]@{
        # Bumped when the on-disk shape changes; Restore branches on it so old
        # backups taken before the raw-target fix still restore.
        SchemaVersion          = 3
        Id                     = $full.Id
        DisplayName            = $full.DisplayName
        Description            = $full.Description
        FileName               = $full.FileName
        ScriptContent          = [System.Convert]::ToBase64String($contentBytes)
        RunAsAccount           = $full.RunAsAccount.ToString()
        EnforceSignatureCheck  = [bool]$full.EnforceSignatureCheck
        RunAs32Bit             = Get-WizardScriptRunAs32Bit -Script $full
        RoleScopeTagIds        = @($full.RoleScopeTagIds)
        Assignments            = $assignments
        BackedUpAt             = (Get-Date).ToString('o')
        # Schema 3+: fingerprint of whatever is about to be pushed into this
        # script's place. Restore only needs this in the rare case where, by
        # restore time, this Id is gone and it has to recreate under a new one
        # - that leaves the script the backup's Id used to hold (now bearing
        # this fingerprint) as an orphan with nothing pointing at it. Empty
        # string rather than omitted, so old and new backups have the same shape.
        ReplacedByDisplayName  = [string]$ReplacementDisplayName
        ReplacedByContentHash  = [string]$ReplacementContentHash
    }

    # An empty or all-punctuation display name would collapse to '' and produce a
    # file called '_20260728-221500.json'; give it something searchable instead.
    $safeName = Get-WizardSafeFileName -Name $full.DisplayName -Fallback "script-$($full.Id)"

    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $path = Join-Path $BackupDir "$safeName`_$stamp.json"

    # The timestamp only resolves to the second, and the sanitising above maps
    # every awkward character to '_', so two scripts backed up by the same run
    # can easily want the same file name: 'Payroll Script (v1)' and 'Payroll
    # Script [v1]' both become 'Payroll_Script__v1_', as do any two names that
    # differ only past the 100-character truncation. Save-WizardJsonFile moves
    # into place with -Force, so without this the second backup would silently
    # overwrite the first - leaving that first script updated with nothing to
    # roll it back to, which only shows up on the day someone needs it.
    $attempt = 2
    while (Test-Path -LiteralPath $path) {
        if ($attempt -gt 99) {
            # Pathological (a folder already full of same-second collisions):
            # stop counting and take a random name rather than looping.
            $path = Join-Path $BackupDir "$safeName`_$stamp-$([guid]::NewGuid().ToString('N').Substring(0, 8)).json"
            break
        }
        $path = Join-Path $BackupDir "$safeName`_$stamp-$attempt.json"
        $attempt++
    }

    try {
        # Atomic: a backup that exists must be complete, because the update that
        # follows is about to rely on it.
        # Save-WizardJsonFile is this project's own helper (see JsonIO.ps1-style
        # files) that wraps ConvertTo-Json + Set-Content for writing JSON to disk.
        Save-WizardJsonFile -Path $path -Value $backup -Depth 10
    } catch {
        throw "Could not write the backup for '$($full.DisplayName)' to '$path': $($_.Exception.Message). Nothing was changed in the tenant."
    }
    Write-Host "  Backed up existing '$($full.DisplayName)' -> $path" -ForegroundColor DarkGray
    Write-WizardDebug "Backup wrote $($assignments.Count) assignment(s), $(@($full.RoleScopeTagIds).Count) scope tag(s)"
    return $path
}

function Resolve-WizardBackupTargets {
    # Works out which existing Intune script(s) a standalone -Backup/-BackupAll
    # run should snapshot. Only id + displayName are needed to pick the
    # target(s), so this stays a lightweight list call - the full read (and the
    # backup file itself) happens per-script in Backup-WizardScript.
    param(
        [string]$NameOrId,
        [switch]$All
    )

    $existing = @(Invoke-WizardGraphRetry -What 'Reading existing scripts to back up' -Call {
        Get-MgBetaDeviceManagementScript -All -Property id, displayName
    })

    if ($All) { return $existing }

    if ([string]::IsNullOrWhiteSpace($NameOrId)) {
        throw "Nothing to back up: pass -Backup <name-or-id> or -BackupAll."
    }

    # Same "GUID first, else display name" idiom used for #group:/#excludegroup:
    # references, so -Backup takes either form without a separate switch.
    $parsed = [guid]::Empty
    if ([guid]::TryParse($NameOrId, [ref]$parsed)) {
        $matched = @($existing | Where-Object { $_.Id -eq $parsed.ToString() })
        if ($matched.Count -eq 0) {
            throw "No script with Id '$NameOrId' found in this tenant."
        }
        return $matched
    }

    $matched = @($existing | Where-Object { $_.DisplayName -eq $NameOrId })
    if ($matched.Count -eq 0) {
        throw "No script named '$NameOrId' found in this tenant. Check the spelling, or pass its Id instead."
    }
    if ($matched.Count -gt 1) {
        $ids = ($matched | ForEach-Object { $_.Id }) -join ', '
        throw "'$NameOrId' is ambiguous - $($matched.Count) scripts share that name ($ids). Use the Id instead."
    }
    return $matched
}

function Get-WizardRestoreAssignments {
    # Turns the raw "Assignments" data from a backup file back into the shape
    # Graph expects when re-assigning the restored script to groups/users.
    # Normalises the Assignments block of a backup into assign-action payloads.
    # Schema 1 stored only the target's AdditionalProperties under 'Target',
    # which is lossy - warn rather than silently restoring a broken target.
    # AllowNull() lets $Backup legitimately be $null without PowerShell
    # rejecting it up front, so the checks below can produce a clearer error.
    param([Parameter(Mandatory)][AllowNull()]$Backup)

    $raw = @($Backup['Assignments'])
    if ($raw.Count -eq 0) { return @() }

    $schema = if ($Backup.ContainsKey('SchemaVersion')) { [int]$Backup['SchemaVersion'] } else { 1 }
    $result = @()

    foreach ($entry in $raw) {
        if (-not $entry) { continue }
        $target = $entry['target']
        if (-not $target) { continue }

        if ($schema -lt 2 -and -not $target['@odata.type']) {
            Write-Warning "Backup predates the assignment fix and one target has no @odata.type; skipping it. Re-check assignments in the portal after restore."
            continue
        }
        if ($schema -lt 2) {
            Write-Warning "Backup uses the old assignment format: group targets may be missing their groupId. Verify assignments in the portal after restore."
        }

        $result += @{
            '@odata.type' = '#microsoft.graph.deviceManagementScriptAssignment'
            'target'      = $target
        }
    }

    return $result
}

function Test-WizardBackupShape {
    # Checks that a loaded backup has all the fields a restore needs before
    # trusting any of it - catches broken/hand-edited backup files early.
    # Validates a backup before any of it reaches Graph. A backup is an ordinary
    # JSON file in a folder people poke around in, so "hand-edited and broken" is
    # a normal state for one to be in - and half-restoring a script is worse than
    # not starting.
    param(
        [Parameter(Mandatory)][AllowNull()]$Backup,
        [Parameter(Mandatory)][string]$Source
    )

    if ($Backup -isnot [hashtable]) {
        throw "'$Source' is not a wizard backup: expected a JSON object, got $(if ($null -eq $Backup) { 'nothing' } else { $Backup.GetType().Name })."
    }

    $required = @('Id', 'DisplayName', 'FileName', 'ScriptContent', 'RunAsAccount')
    $absent = @($required | Where-Object { -not $Backup.ContainsKey($_) -or [string]::IsNullOrWhiteSpace([string]$Backup[$_]) })
    if ($absent.Count -gt 0) {
        throw "'$Source' is missing required field(s): $($absent -join ', '). It is not a usable backup."
    }

    if ($Backup['RunAsAccount'] -notin @('user', 'system')) {
        throw "'$Source' has RunAsAccount '$($Backup['RunAsAccount'])'; Intune accepts only 'user' or 'system'."
    }

    try {
        # Intune stores script content as base64 text; decode it back to raw
        # bytes here just to prove it is valid and non-empty, not to use yet.
        # Shared with the Graph read path so that a backup written before the
        # byte[] handling was fixed - content stored as a JSON array of numbers
        # instead of base64 - still restores instead of being rejected.
        $bytes = Get-WizardScriptContentBytes -Content $Backup['ScriptContent']
    } catch {
        throw "'$Source' has a ScriptContent field that is not valid base64, so the original script cannot be reconstructed from it."
    }
    if (-not $bytes) {
        throw "'$Source' decodes to an empty script. Intune rejects empty script content, so there is nothing to restore."
    }

    # Unary comma: without it a returned array is enumerated onto the pipeline
    # and a one-byte script collapses to a single [byte], which the caller's
    # WriteAllBytes(string, byte[]) then has no overload for.
    return ,$bytes
}

function Remove-WizardOrphanReplacement {
    # Only relevant to the recreate branch of Restore-WizardBackup: the
    # original script's Id was gone by restore time, so a fresh Id was just
    # created above for it. If whatever had been pushed into that Id's place
    # (recorded at backup time as ReplacedByDisplayName/ReplacedByContentHash)
    # still exists elsewhere in the tenant under its own Id, it is now an
    # orphan - nothing local points at it anymore, since the original has just
    # been recreated instead. Deletion always waits for a human: matching by
    # name + content hash is a good guess, not proof, and a wrong guess deletes
    # someone's live script.
    param(
        [Parameter(Mandatory)][AllowNull()]$Backup,
        [Parameter(Mandatory)][string]$RecreatedId
    )

    $name = [string]$Backup['ReplacedByDisplayName']
    $hash = [string]$Backup['ReplacedByContentHash']
    if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($hash)) {
        return  # backup predates this check, or the script was never replaced before it vanished
    }

    try {
        $candidates = @(Invoke-WizardGraphRetry -What 'Checking for an orphaned duplicate' -Call {
            Get-MgBetaDeviceManagementScript -All -Property id, displayName
        } | Where-Object { $_.Id -ne $RecreatedId -and $_.DisplayName -eq $name })
    } catch {
        Write-Warning "Could not check the tenant for an orphaned duplicate of '$name': $(Get-WizardErrorSummary -ErrorRecord $_). Check the Intune portal by hand if you expect one."
        return
    }
    if ($candidates.Count -eq 0) { return }

    # Name alone is too weak a match to delete on; confirm content too before
    # this is even considered a candidate.
    $matches = @()
    foreach ($candidate in $candidates) {
        try {
            $full = Invoke-WizardGraphRetry -What "Reading candidate $($candidate.Id)" -Call {
                Get-MgBetaDeviceManagementScript -DeviceManagementScriptId $candidate.Id -Property scriptContent
            }
            $candidateBytes = Get-WizardScriptContentBytes -Content $full.ScriptContent
            if (-not $candidateBytes) { continue }
            $candidateHash = Get-WizardBytesHash -Bytes $candidateBytes
            if ($candidateHash -eq $hash) { $matches += $candidate }
        } catch {
            Write-WizardDebug "Could not hash candidate $($candidate.Id) while checking for an orphaned duplicate: $($_.Exception.Message)"
        }
    }
    if ($matches.Count -eq 0) { return }

    if ($matches.Count -gt 1) {
        $ids = ($matches | ForEach-Object { $_.Id }) -join ', '
        Write-Warning "Found $($matches.Count) scripts named '$name' matching what used to occupy this backup's slot; too ambiguous to guess which (if any) is the orphan. Check the Intune portal: $ids"
        return
    }

    $orphan = $matches[0]
    Write-Warning "'$name' ($($orphan.Id)) matches what this backup's script had been replaced with, and nothing local points at it anymore now that '$($Backup['DisplayName'])' has been recreated as $RecreatedId."
    if (Test-WizardInteractive) {
        $choice = [string](Read-Host "Delete the orphaned duplicate '$name' ($($orphan.Id))? [y/N]")
        if ($choice -match '^y') {
            try {
                Remove-WizardScript -Id $orphan.Id
                Write-Host "  Deleted orphaned duplicate $($orphan.Id)." -ForegroundColor DarkGray
            } catch {
                Write-Warning "Could not delete '$name' ($($orphan.Id)): $(Get-WizardErrorSummary -ErrorRecord $_). Remove it by hand if you don't want it kept."
            }
        } else {
            Write-Host "  Left in place. Delete it by hand in the Intune portal if you don't want it kept."
        }
    } else {
        Write-Warning "Not deleting automatically in a non-interactive session. Remove '$name' ($($orphan.Id)) by hand in the Intune portal if you don't want it kept."
    }
}

function Test-WizardScopeTagRejection {
    # True when Graph turned a write down over its role scope tags.
    #
    # A backup can carry scope tag ids that no longer mean anything: the tag
    # was deleted since, or the backup came from a different tenant. Graph
    # rejects the whole request for that, so the script's content never lands -
    # a total restore failure over metadata nobody was trying to restore, at
    # the exact moment someone needs the content back.
    param([Parameter(Mandatory)]$ErrorRecord)

    return ((Get-WizardErrorSummary -ErrorRecord $ErrorRecord) -match '(?i)scope\s*tag')
}

function Invoke-WizardScopeTagFallback {
    # Runs one restore write, and if the tenant rejects it over role scope
    # tags, runs it exactly once more with the built-in Default tag only.
    # Losing a scope tag assignment is a minute's work in the portal; losing
    # the restore itself, during whatever incident prompted it, is not.
    param(
        # Takes the scope tags to use and performs the write. A scriptblock is
        # a chunk of code held in a variable; '& $Write $tags' runs it.
        [Parameter(Mandatory)][scriptblock]$Write,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$RoleScopeTagIds,
        # Named in the warning, e.g. "Restoring 'Payroll script'".
        [Parameter(Mandatory)][string]$What
    )

    try {
        return (& $Write $RoleScopeTagIds)
    } catch {
        if (-not (Test-WizardScopeTagRejection -ErrorRecord $_)) { throw }
        # Already down to the Default tag: there is nothing left to fall back
        # to, so let the caller's own error message describe the failure.
        if (($RoleScopeTagIds -join ',') -eq '0') { throw }

        Write-Warning "$What was rejected over its role scope tags ($($RoleScopeTagIds -join ', ')): $(Get-WizardErrorSummary -ErrorRecord $_). Retrying with the built-in Default tag only - re-apply the original scope tags in the Intune portal if they still exist and you still need them."
        return (& $Write @('0'))
    }
}

function Restore-WizardBackup {
    # One-command restore of a backup produced by Backup-WizardScript.
    # Reads a backup JSON file back off disk and pushes it to Intune, either
    # updating the original script if it still exists or recreating it fresh.
    param(
        [Parameter(Mandatory)][string]$BackupFile,
        # Restore the script itself and leave its current assignments alone.
        # For the case the assign step cannot be made to work at all: groups
        # named in the backup that were deleted since, or a backup being
        # restored into a different tenant, where the content is recoverable
        # and the targets are not.
        [switch]$SkipAssignments
    )

    # -PathType Leaf means "must be a file, not a folder".
    if (-not (Test-Path -LiteralPath $BackupFile -PathType Leaf)) {
        throw "Backup file not found: $BackupFile"
    }

    # -AsHashtable keeps everything as plain hashtables, so nested assignment
    # targets can be posted straight back without PSCustomObject conversions.
    # Read-WizardJsonFile is this project's own helper around Get-Content +
    # ConvertFrom-Json for loading a JSON file into a PowerShell object.
    try {
        $backup = Read-WizardJsonFile -Path $BackupFile -AsHashtable
    } catch {
        throw "Could not parse '$BackupFile' as JSON: $($_.Exception.Message). If it was edited by hand, check for a trailing comma or a truncated file."
    }

    $bytes = Test-WizardBackupShape -Backup $backup -Source $BackupFile
    Write-WizardDebug "Restoring from $BackupFile (schema $($backup['SchemaVersion']), $($bytes.Length) content bytes)"

    # The temp file name is generated, never taken from the backup: FileName is
    # attacker-controlled data in a hand-edited backup and could contain path
    # separators or '..'. Only Graph gets the original name, via -FileName.
    # [guid]::NewGuid() makes a random unique id, used here so the temp
    # filename can't collide with another run and can't be guessed in advance.
    $tempScript = Join-Path ([System.IO.Path]::GetTempPath()) "intune-wizard-$([guid]::NewGuid().ToString('N')).ps1"
    [System.IO.File]::WriteAllBytes($tempScript, $bytes)

    # finally below always runs (success or error) so the temp file created
    # above is cleaned up either way.
    try {
        $exists = $null
        # Nested try/catch: a "not found" error here means the script really is
        # gone and this becomes a recreate. Nothing else does. Swallowing every
        # error (what this used to do) turned a throttle, an outage or an
        # expired token into a "deletion", which recreated a script that was
        # still live - two copies in the tenant, the assignments moved to the
        # copy, and the backup filed away as though it had all worked.
        try {
            $exists = Invoke-WizardGraphRetry -What "Checking whether script $($backup['Id']) still exists" -Call {
                Get-MgBetaDeviceManagementScript -DeviceManagementScriptId $backup['Id']
            }
        } catch {
            if (-not (Test-WizardGraphNotFound -ErrorRecord $_)) {
                throw "Could not check whether script $($backup['Id']) still exists: $(Get-WizardErrorSummary -ErrorRecord $_). Nothing was changed and '$BackupFile' is untouched, so this can be retried once the tenant is answering again."
            }
            $exists = $null
        }

        # Where-Object earns its place here: a backup written before scope tags
        # were captured at all (schema 1) has no RoleScopeTagIds key, and
        # @($null) is a ONE-element array, so a bare .Count test reads that as
        # "one scope tag" and posts an empty id that Graph rejects - making
        # precisely the oldest backups the ones that cannot be restored.
        # '0' is the built-in Default tag.
        $roleScopeTagIds = @(@($backup['RoleScopeTagIds']) |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($roleScopeTagIds.Count -eq 0) { $roleScopeTagIds = @('0') }

        if ($exists) {
            Write-Host "Restoring '$($backup['DisplayName'])' over existing script $($backup['Id'])..."
            try {
                Invoke-WizardScopeTagFallback -RoleScopeTagIds $roleScopeTagIds `
                    -What "Restoring '$($backup['DisplayName'])'" -Write {
                        param([string[]]$Tags)
                        Invoke-WizardGraphRetry -What "Restoring over script $($backup['Id'])" -Call {
                        Update-MgBetaDeviceManagementScript `
                            -DeviceManagementScriptId $backup['Id'] `
                            -DisplayName $backup['DisplayName'] `
                            -Description $backup['Description'] `
                            -FileName $backup['FileName'] `
                            -ScriptContentInputFile $tempScript `
                            -RunAsAccount $backup['RunAsAccount'] `
                            -EnforceSignatureCheck:$backup['EnforceSignatureCheck'] `
                            -RunAs32Bit:$backup['RunAs32Bit'] `
                            -RoleScopeTagIds $Tags | Out-Null
                        }
                    }
            } catch {
                throw "Restoring '$($backup['DisplayName'])' over $($backup['Id']) failed: $(Get-WizardErrorSummary -ErrorRecord $_). The script is unchanged or partly changed; the backup file is intact and can be retried."
            }
            $targetId = $backup['Id']
        } else {
            Write-Host "Original script $($backup['Id']) no longer exists - recreating '$($backup['DisplayName'])' (new Id will be assigned)..."
            try {
                $created = Invoke-WizardScopeTagFallback -RoleScopeTagIds $roleScopeTagIds `
                    -What "Recreating '$($backup['DisplayName'])'" -Write {
                        param([string[]]$Tags)
                        Invoke-WizardGraphRetry -What "Recreating '$($backup['DisplayName'])'" -Call {
                        New-MgBetaDeviceManagementScript `
                            -DisplayName $backup['DisplayName'] `
                            -Description $backup['Description'] `
                            -FileName $backup['FileName'] `
                            -ScriptContentInputFile $tempScript `
                            -RunAsAccount $backup['RunAsAccount'] `
                            -EnforceSignatureCheck:$backup['EnforceSignatureCheck'] `
                            -RunAs32Bit:$backup['RunAs32Bit'] `
                            -RoleScopeTagIds $Tags
                        }
                    }
            } catch {
                throw "Recreating '$($backup['DisplayName'])' from the backup failed: $(Get-WizardErrorSummary -ErrorRecord $_)"
            }
            if (-not $created -or -not $created.Id) {
                throw "Recreating '$($backup['DisplayName'])' returned no script id, so its assignments could not be restored. Check the Intune portal before retrying."
            }
            $targetId = $created.Id

            # Only reachable because the original Id was gone, so whatever this
            # backup's Id last held (recorded at backup time) may still be
            # sitting in the tenant under its own Id, orphaned now that we just
            # recreated the original instead of updating it in place.
            Remove-WizardOrphanReplacement -Backup $backup -RecreatedId $targetId
        }

        # One full replacement: whatever the backup held becomes the whole set.
        # @(...) as above - a backup with no assignments must still post an
        # empty set rather than collapsing to $null.
        $restoreAssignments = @(Get-WizardRestoreAssignments -Backup $backup)
        if ($SkipAssignments) {
            Write-Warning "-SkipAssignments: '$($backup['DisplayName'])' ($targetId) keeps whatever assignments it has now; the $($restoreAssignments.Count) assignment(s) in the backup were not applied. Set them in the Intune portal, or re-run the restore without the switch once the targets exist."
        } else {
            try {
                Set-WizardWholeAssignment -Id $targetId -Assignments $restoreAssignments
            } catch {
                throw "'$($backup['DisplayName'])' ($targetId) was restored but its assignments were not: $(Get-WizardErrorSummary -ErrorRecord $_). The restored content is live against whatever assignments the script had before. If those groups no longer exist (or this backup came from another tenant), re-run with -SkipAssignments to restore the script alone."
            }
        }

        Write-Host "Restore complete: $targetId" -ForegroundColor Green
        Move-WizardRestoredBackup -BackupFile $BackupFile
        return $targetId
    } finally {
        Remove-Item -LiteralPath $tempScript -ErrorAction SilentlyContinue
    }
}

function Move-WizardRestoredBackup {
    # Once a backup has been restored it is done - leaving it sitting next to
    # backups nobody has used yet makes it easy to lose track of which is
    # which. Moves it into a 'backup-restored' folder alongside itself rather
    # than deleting it, since the file is still the historical record of what
    # the script looked like at that point. Purely tidying up: a failure here
    # must not turn an already-successful restore into an error.
    param([Parameter(Mandatory)][string]$BackupFile)

    try {
        # GetFullPath first: for a backup named on the command line as a bare
        # file name in the current directory, Split-Path -Parent returns an
        # empty string, which Join-Path then refuses - turning a successful
        # restore into a warning about tidying up.
        $fullPath = [System.IO.Path]::GetFullPath($BackupFile)
        $sourceDir = Split-Path -Parent $fullPath
        $restoredDir = Join-Path $sourceDir 'backup-restored'
        if (-not (Test-Path -LiteralPath $restoredDir)) {
            New-Item -ItemType Directory -Path $restoredDir -Force -ErrorAction Stop | Out-Null
        }

        $destination = Join-Path $restoredDir (Split-Path -Leaf $fullPath)
        if (Test-Path -LiteralPath $destination) {
            # Same filename restored twice (backups are timestamped, but a
            # hand-copied file could still collide): don't clobber the earlier one.
            $destination = Join-Path $restoredDir "$([System.IO.Path]::GetFileNameWithoutExtension($BackupFile))_$((Get-Date).ToString('yyyyMMdd-HHmmss')).json"
        }

        Move-Item -LiteralPath $BackupFile -Destination $destination -Force -ErrorAction Stop
        Write-Host "  Moved restored backup -> $destination" -ForegroundColor DarkGray
    } catch {
        Write-Warning "Restore succeeded, but could not move '$BackupFile' into backup-restored/: $($_.Exception.Message). It's still in its original location."
    }
}

function Select-WizardRestoreSet {
    # Decides which of a folder's backups -RestoreAll should actually restore,
    # and in what order.
    #
    # A backups/ folder normally holds SEVERAL backups of the same script - one
    # per run that changed it. Restoring all of them just replays that history
    # against the tenant, and the file applied last is the one that sticks:
    # with Get-ChildItem's name ordering, and a file name that starts with the
    # display name, that is whichever NAME sorts later rather than whichever
    # backup is newer, so a script renamed between two backups lands on an
    # arbitrary revision with nothing reported. Restoring the OLDEST backup per
    # script is the only reading of "undo this folder" that holds up: it puts
    # each script back the way it was before these changes began. The newer
    # ones are left on disk and named in a warning, still restorable one at a
    # time with -Restore if that is the state someone actually wants.
    #
    # Returns three lists: what to restore (oldest per script, chronological),
    # what was passed over, and any file in the folder that is not a backup.
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Files)

    $entries = @()
    $ignored = @()

    foreach ($file in $Files) {
        $data = $null
        # A file that cannot be read or parsed is NOT skipped here: it stays in
        # the restore list so it fails loudly, with the shape checker's own
        # message, rather than disappearing from the run silently.
        try { $data = Read-WizardJsonFile -Path $file.FullName -AsHashtable } catch { $data = $null }

        if ($data -is [hashtable] -and
            -not $data.ContainsKey('Id') -and
            -not $data.ContainsKey('ScriptContent') -and
            -not $data.ContainsKey('SchemaVersion')) {
            # Valid JSON carrying none of a backup's identifying fields: it is
            # somebody else's file sharing the folder. Skipping it stops one
            # stray note.json from making an otherwise clean run exit 2.
            $ignored += $file
            continue
        }

        $id = if ($data -is [hashtable]) { [string]$data['Id'] } else { '' }

        # BackedUpAt is what the backup itself says; the file's own timestamp is
        # the fallback for a backup old enough to predate that field.
        $stamp = $file.LastWriteTimeUtc
        if ($data -is [hashtable] -and $data['BackedUpAt']) {
            $parsed = [datetimeoffset]::MinValue
            if ([datetimeoffset]::TryParse([string]$data['BackedUpAt'], [ref]$parsed)) {
                $stamp = $parsed.UtcDateTime
            }
        }

        $entries += [pscustomobject]@{ File = $file; Id = $id; BackedUpAt = $stamp }
    }

    $restore = @()
    $superseded = @()
    # Group by the script id inside each file. Entries with no readable id get
    # a group to themselves (keyed on their path) so that none of them is
    # dropped as a "duplicate" of another unreadable file.
    foreach ($group in ($entries | Group-Object { if ($_.Id) { $_.Id } else { "unreadable:$($_.File.FullName)" } })) {
        $ordered = @($group.Group | Sort-Object BackedUpAt)
        $restore += $ordered[0]
        if ($ordered.Count -gt 1) { $superseded += $ordered[1..($ordered.Count - 1)] }
    }

    return [pscustomobject]@{
        Restore    = @($restore | Sort-Object BackedUpAt)
        Superseded = @($superseded | Sort-Object BackedUpAt)
        Ignored    = @($ignored)
    }
}
