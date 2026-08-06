# Restore.ps1
# Reading a backup produced by Backup.ps1 back off disk and pushing it into the
# tenant: validating the file, the scope-tag fallback, the orphan-duplicate
# check, the single-file restore itself, tidying the file away afterwards, and
# choosing which of a folder's backups -RestoreAll should replay. Split out of
# Backup.ps1 because take-a-snapshot and put-a-snapshot-back are independent
# concerns that share only the on-disk schema.

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
            # -ErrorAction Stop: without it, a 404 here writes a full error
            # record straight to the console (the SDK treats "not found" as a
            # non-terminating error before also throwing) even though this is
            # the expected, silently-handled path below - it would read as a
            # crash on every restore of a script the e2e/delete flow removed.
            $exists = Invoke-WizardGraphRetry -What "Checking whether script $($backup['Id']) still exists" -Call {
                Get-MgBetaDeviceManagementScript -DeviceManagementScriptId $backup['Id'] -ErrorAction Stop
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
