# Backup.ps1
# Snapshotting an existing Intune script before it is changed. Split out of
# GraphOps.ps1 because it is a self-contained concern with its own on-disk
# schema to version; the matching restore side lives in Restore.ps1.

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
        [string]$ReplacementContentHash,
        # When given, also exports a .ps1 template for this script (see
        # Template.ps1). Both must be supplied together; deploy-triggered
        # backups deliberately never pass these, because exporting there would
        # write the pre-change version of the script.
        [string]$TemplateRoot,
        $TemplateState
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
        # Save-WizardJsonFile is this project's own helper (see Storage.ps1)
        # that wraps ConvertTo-Json + Set-Content for writing JSON to disk.
        Save-WizardJsonFile -Path $path -Value $backup -Depth 10
    } catch {
        throw "Could not write the backup for '$($full.DisplayName)' to '$path': $($_.Exception.Message). Nothing was changed in the tenant."
    }
    Write-Host "  Backed up existing '$($full.DisplayName)' -> $path" -ForegroundColor DarkGray
    Write-WizardDebug "Backup wrote $($assignments.Count) assignment(s), $(@($full.RoleScopeTagIds).Count) scope tag(s)"

    if ($TemplateRoot) {
        # A template failure must never fail the backup that's the actual
        # safety net - the JSON backup is what a restore depends on.
        try {
            Export-WizardScriptTemplate -Script $full -Assignments $assignments -TemplateRoot $TemplateRoot -State $TemplateState | Out-Null
        } catch {
            $TemplateState.Failed++
            Write-Warning "Backup of '$($full.DisplayName)' succeeded, but exporting its template failed: $($_.Exception.Message)."
        }
    }

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
