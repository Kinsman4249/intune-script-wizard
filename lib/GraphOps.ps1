# GraphOps.ps1
# All Microsoft Graph (beta) interaction: auth, reading existing scripts,
# create/update, assignments, backup and restore.
#
# NOTE: cmdlet names below follow the standard Microsoft.Graph.Beta.DeviceManagement
# naming convention (Verb-MgBetaDeviceManagementScript*). If a future module
# version renames one of these, run:
#   Get-Command -Module Microsoft.Graph.Beta.DeviceManagement -Name '*Script*'
# and update this file accordingly.

$script:RequiredScopes = @('DeviceManagementConfiguration.ReadWrite.All')

function Connect-WizardGraph {
    $context = Get-MgContext
    if (-not $context -or ($script:RequiredScopes | Where-Object { $_ -notin $context.Scopes })) {
        Connect-MgGraph -Scopes $script:RequiredScopes -NoWelcome
    }
}

function Get-WizardAssignmentTargetType {
    param([Parameter(Mandatory)][ValidateSet('user', 'device')][string]$Type)
    if ($Type -eq 'user') { 'allLicensedUsersAssignmentTarget' } else { 'allDevicesAssignmentTarget' }
}

function Get-WizardExistingScripts {
    # Returns all existing deviceManagementScripts with a content SHA256 hash,
    # using a local cache (keyed by LastModifiedDateTime) so unchanged scripts
    # don't need their content re-downloaded on every run.
    param(
        [Parameter(Mandatory)][string]$CachePath
    )

    $cache = @{}
    if (Test-Path -LiteralPath $CachePath) {
        try {
            (Get-Content -LiteralPath $CachePath -Raw | ConvertFrom-Json) | ForEach-Object {
                $cache[$_.Id] = $_
            }
        } catch {
            Write-Warning "Could not read cache file '$CachePath', rebuilding it."
        }
    }

    $existing = Get-MgBetaDeviceManagementScript -All -Property id, displayName, description, lastModifiedDateTime

    $results = @()
    foreach ($item in $existing) {
        $cached = $cache[$item.Id]
        if ($cached -and $cached.LastModifiedDateTime -eq $item.LastModifiedDateTime.ToString('o')) {
            $hash = $cached.ContentHash
        } else {
            $full = Get-MgBetaDeviceManagementScript -DeviceManagementScriptId $item.Id -Property scriptContent
            $bytes = [System.Convert]::FromBase64String($full.ScriptContent)
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try {
                $hash = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
            } finally {
                $sha.Dispose()
            }
        }

        $results += [pscustomobject]@{
            Id                  = $item.Id
            DisplayName         = $item.DisplayName
            Description         = $item.Description
            LastModifiedDateTime = $item.LastModifiedDateTime.ToString('o')
            ContentHash         = $hash
        }
    }

    $results | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $CachePath
    return $results
}

function Get-WizardScriptAssignments {
    param([Parameter(Mandatory)][string]$Id)
    Get-MgBetaDeviceManagementScriptAssignment -DeviceManagementScriptId $Id -All
}

function Set-WizardAssignments {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('user', 'device')][string]$Type,
        [switch]$NoAssignments
    )

    $current = @(Get-WizardScriptAssignments -Id $Id)

    if ($NoAssignments) {
        foreach ($a in $current) {
            Remove-MgBetaDeviceManagementScriptAssignment -DeviceManagementScriptId $Id -DeviceManagementScriptAssignmentId $a.Id
        }
        return
    }

    $desiredType = "#microsoft.graph.$(Get-WizardAssignmentTargetType -Type $Type)"
    $alreadyAssigned = $current | Where-Object { $_.Target.AdditionalProperties['@odata.type'] -eq $desiredType }
    if (-not $alreadyAssigned) {
        New-MgBetaDeviceManagementScriptAssignment -DeviceManagementScriptId $Id -Target @{ '@odata.type' = $desiredType }
    }
}

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
    $assignments = @(Get-WizardScriptAssignments -Id $Id) | ForEach-Object {
        @{ Target = $_.Target.AdditionalProperties }
    }

    $backup = [ordered]@{
        Id                     = $full.Id
        DisplayName            = $full.DisplayName
        Description            = $full.Description
        FileName               = $full.FileName
        ScriptContent          = $full.ScriptContent
        RunAsAccount           = $full.RunAsAccount.ToString()
        EnforceSignatureCheck  = [bool]$full.EnforceSignatureCheck
        RunAs32Bit             = [bool]$full.RunAs32BitOnWindows64
        RoleScopeTagIds        = $full.RoleScopeTagIds
        Assignments            = $assignments
        BackedUpAt             = (Get-Date).ToString('o')
    }

    $safeName = ($full.DisplayName -replace '[^a-zA-Z0-9._-]', '_')
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $path = Join-Path $BackupDir "$safeName`_$stamp.json"
    $backup | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path
    Write-Host "  Backed up existing '$($full.DisplayName)' -> $path" -ForegroundColor DarkGray
    return $path
}

function New-WizardScript {
    param([Parameter(Mandatory)]$Meta)

    Write-Host "Creating '$($Meta.DisplayName)' ($($Meta.Type))..."
    $script = New-MgBetaDeviceManagementScript `
        -DisplayName $Meta.DisplayName `
        -Description $Meta.Description `
        -FileName $Meta.FileName `
        -ScriptContentInputFile $Meta.Path `
        -RunAsAccount $Meta.RunAsAccount `
        -EnforceSignatureCheck:$Meta.EnforceSignatureCheck `
        -RunAs32Bit:$Meta.RunAs32Bit

    if (-not $Meta.NoAssignments) {
        Set-WizardAssignments -Id $script.Id -Type $Meta.Type
    }
    return $script
}

function Update-WizardScript {
    param(
        [Parameter(Mandatory)]$Meta,
        [Parameter(Mandatory)][string]$ExistingId,
        [Parameter(Mandatory)][string]$BackupDir
    )

    Backup-WizardScript -Id $ExistingId -BackupDir $BackupDir | Out-Null

    Write-Host "Updating '$($Meta.DisplayName)' ($($Meta.Type))..."
    Update-MgBetaDeviceManagementScript `
        -DeviceManagementScriptId $ExistingId `
        -DisplayName $Meta.DisplayName `
        -Description $Meta.Description `
        -FileName $Meta.FileName `
        -ScriptContentInputFile $Meta.Path `
        -RunAsAccount $Meta.RunAsAccount `
        -EnforceSignatureCheck:$Meta.EnforceSignatureCheck `
        -RunAs32Bit:$Meta.RunAs32Bit | Out-Null

    Set-WizardAssignments -Id $ExistingId -Type $Meta.Type -NoAssignments:$Meta.NoAssignments
}

function Restore-WizardBackup {
    # One-command restore of a backup produced by Backup-WizardScript.
    param([Parameter(Mandatory)][string]$BackupFile)

    $backup = Get-Content -LiteralPath $BackupFile -Raw | ConvertFrom-Json
    $tempScript = Join-Path ([System.IO.Path]::GetTempPath()) $backup.FileName
    [System.IO.File]::WriteAllBytes($tempScript, [System.Convert]::FromBase64String($backup.ScriptContent))

    try {
        $exists = $null
        try { $exists = Get-MgBetaDeviceManagementScript -DeviceManagementScriptId $backup.Id } catch { $exists = $null }

        if ($exists) {
            Write-Host "Restoring '$($backup.DisplayName)' over existing script $($backup.Id)..."
            Update-MgBetaDeviceManagementScript `
                -DeviceManagementScriptId $backup.Id `
                -DisplayName $backup.DisplayName `
                -Description $backup.Description `
                -FileName $backup.FileName `
                -ScriptContentInputFile $tempScript `
                -RunAsAccount $backup.RunAsAccount `
                -EnforceSignatureCheck:$backup.EnforceSignatureCheck `
                -RunAs32Bit:$backup.RunAs32Bit | Out-Null
            $targetId = $backup.Id
        } else {
            Write-Host "Original script $($backup.Id) no longer exists - recreating '$($backup.DisplayName)' (new Id will be assigned)..."
            $created = New-MgBetaDeviceManagementScript `
                -DisplayName $backup.DisplayName `
                -Description $backup.Description `
                -FileName $backup.FileName `
                -ScriptContentInputFile $tempScript `
                -RunAsAccount $backup.RunAsAccount `
                -EnforceSignatureCheck:$backup.EnforceSignatureCheck `
                -RunAs32Bit:$backup.RunAs32Bit
            $targetId = $created.Id
        }

        # Reconcile assignments: wipe current, re-add whatever the backup had.
        @(Get-WizardScriptAssignments -Id $targetId) | ForEach-Object {
            Remove-MgBetaDeviceManagementScriptAssignment -DeviceManagementScriptId $targetId -DeviceManagementScriptAssignmentId $_.Id
        }
        foreach ($a in $backup.Assignments) {
            New-MgBetaDeviceManagementScriptAssignment -DeviceManagementScriptId $targetId -Target $a.Target
        }

        Write-Host "Restore complete: $targetId" -ForegroundColor Green
        return $targetId
    } finally {
        Remove-Item -LiteralPath $tempScript -ErrorAction SilentlyContinue
    }
}
