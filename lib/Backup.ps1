# Backup.ps1
# Snapshotting an existing Intune script before it is changed, and restoring
# one afterwards. Split out of GraphOps.ps1 because it is a self-contained
# concern with its own on-disk schema to version.

function Backup-WizardScript {
    # Snapshots an existing script's full state to disk before it is changed.
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$BackupDir
    )

    if (-not (Test-Path -LiteralPath $BackupDir)) {
        New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    }

    $full = Get-MgBetaDeviceManagementScript -DeviceManagementScriptId $Id
    $assignments = @(
        Get-WizardScriptAssignments -Id $Id |
            ForEach-Object { ConvertTo-WizardAssignmentPayload -Assignment $_ } |
            Where-Object { $_ }
    )

    $backup = [ordered]@{
        # Bumped when the on-disk shape changes; Restore branches on it so old
        # backups taken before the raw-target fix still restore.
        SchemaVersion          = 2
        Id                     = $full.Id
        DisplayName            = $full.DisplayName
        Description            = $full.Description
        FileName               = $full.FileName
        ScriptContent          = $full.ScriptContent
        RunAsAccount           = $full.RunAsAccount.ToString()
        EnforceSignatureCheck  = [bool]$full.EnforceSignatureCheck
        RunAs32Bit             = [bool]$full.RunAs32BitOnWindows64
        RoleScopeTagIds        = @($full.RoleScopeTagIds)
        Assignments            = $assignments
        BackedUpAt             = (Get-Date).ToString('o')
    }

    $safeName = ($full.DisplayName -replace '[^a-zA-Z0-9._-]', '_')
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $path = Join-Path $BackupDir "$safeName`_$stamp.json"
    $backup | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path
    Write-Host "  Backed up existing '$($full.DisplayName)' -> $path" -ForegroundColor DarkGray
    Write-WizardDebug "Backup wrote $($assignments.Count) assignment(s), $(@($full.RoleScopeTagIds).Count) scope tag(s)"
    return $path
}


function Get-WizardRestoreAssignments {
    # Normalises the Assignments block of a backup into assign-action payloads.
    # Schema 1 stored only the target's AdditionalProperties under 'Target',
    # which is lossy - warn rather than silently restoring a broken target.
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

function Restore-WizardBackup {
    # One-command restore of a backup produced by Backup-WizardScript.
    param([Parameter(Mandatory)][string]$BackupFile)

    if (-not (Test-Path -LiteralPath $BackupFile -PathType Leaf)) {
        throw "Backup file not found: $BackupFile"
    }

    # -AsHashtable keeps everything as plain hashtables, so nested assignment
    # targets can be posted straight back without PSCustomObject conversions.
    $backup = Get-Content -LiteralPath $BackupFile -Raw | ConvertFrom-Json -AsHashtable
    Write-WizardDebug "Restoring from $BackupFile (schema $($backup['SchemaVersion']))"

    # The temp file name is generated, never taken from the backup: FileName is
    # attacker-controlled data in a hand-edited backup and could contain path
    # separators or '..'. Only Graph gets the original name, via -FileName.
    $tempScript = Join-Path ([System.IO.Path]::GetTempPath()) "intune-wizard-$([guid]::NewGuid().ToString('N')).ps1"
    [System.IO.File]::WriteAllBytes($tempScript, [System.Convert]::FromBase64String($backup['ScriptContent']))

    try {
        $exists = $null
        try { $exists = Get-MgBetaDeviceManagementScript -DeviceManagementScriptId $backup['Id'] } catch { $exists = $null }

        $roleScopeTagIds = @($backup['RoleScopeTagIds'])
        if ($roleScopeTagIds.Count -eq 0) { $roleScopeTagIds = @('0') }  # '0' is the built-in Default tag

        if ($exists) {
            Write-Host "Restoring '$($backup['DisplayName'])' over existing script $($backup['Id'])..."
            Update-MgBetaDeviceManagementScript `
                -DeviceManagementScriptId $backup['Id'] `
                -DisplayName $backup['DisplayName'] `
                -Description $backup['Description'] `
                -FileName $backup['FileName'] `
                -ScriptContentInputFile $tempScript `
                -RunAsAccount $backup['RunAsAccount'] `
                -EnforceSignatureCheck:$backup['EnforceSignatureCheck'] `
                -RunAs32Bit:$backup['RunAs32Bit'] `
                -RoleScopeTagIds $roleScopeTagIds | Out-Null
            $targetId = $backup['Id']
        } else {
            Write-Host "Original script $($backup['Id']) no longer exists - recreating '$($backup['DisplayName'])' (new Id will be assigned)..."
            $created = New-MgBetaDeviceManagementScript `
                -DisplayName $backup['DisplayName'] `
                -Description $backup['Description'] `
                -FileName $backup['FileName'] `
                -ScriptContentInputFile $tempScript `
                -RunAsAccount $backup['RunAsAccount'] `
                -EnforceSignatureCheck:$backup['EnforceSignatureCheck'] `
                -RunAs32Bit:$backup['RunAs32Bit'] `
                -RoleScopeTagIds $roleScopeTagIds
            $targetId = $created.Id
        }

        # One full replacement: whatever the backup held becomes the whole set.
        # @(...) as above - a backup with no assignments must still post an
        # empty set rather than collapsing to $null.
        Set-WizardWholeAssignment -Id $targetId -Assignments @(Get-WizardRestoreAssignments -Backup $backup)

        Write-Host "Restore complete: $targetId" -ForegroundColor Green
        return $targetId
    } finally {
        Remove-Item -LiteralPath $tempScript -ErrorAction SilentlyContinue
    }
}
