# GraphOps.ps1
# Reading the tenant's existing scripts (with a local content-hash cache) and
# creating/updating/deleting a deviceManagementScript. The pieces this builds
# on live in sibling files:
#   GraphCore.ps1  - Get-WizardScriptContentBytes, Invoke-WizardGraphRetry
#   GraphAuth.ps1  - Connect-WizardGraph and group resolution
#   Assignments.ps1 - Set-WizardAssignments and the assign-action shape
#   Backup.ps1     - Backup-WizardScript (called before every update)
#
# Cmdlet naming: Get/New/Update-MgBetaDeviceManagementScript are documented and
# stable.

function Get-WizardExistingScripts {
    # Returns all existing deviceManagementScripts with a content SHA256 hash,
    # using a local cache (keyed by LastModifiedDateTime) so unchanged scripts
    # don't need their content re-downloaded on every run.
    # (deviceManagementScript is Intune's Graph object type for a PowerShell
    # script uploaded for devices to run.)
    param(
        [Parameter(Mandatory)][string]$CachePath
    )

    $cache = @{}
    try {
        $cached = Read-WizardJsonFile -Path $CachePath
        foreach ($entry in @($cached)) {
            if ($entry -and $entry.Id) { $cache[$entry.Id] = $entry }
        }
        if ($cache.Count -gt 0) {
            Write-WizardDebug "Loaded $($cache.Count) cached script hashes from $CachePath"
        }
    } catch {
        # The cache is a pure optimisation, so a damaged one costs a slower run
        # and nothing else.
        Write-Warning "Could not read cache file '$CachePath' ($($_.Exception.Message)), rebuilding it."
    }

    try {
        # A typed SDK cmdlet (as opposed to Invoke-MgGraphRequest above): it
        # knows the deviceManagementScript shape and returns .NET objects.
        # -All follows pagination automatically; -Property limits which fields
        # come back, so full script content isn't downloaded for every item.
        $existing = Invoke-WizardGraphRetry -What 'Reading the existing scripts' -Call {
            Get-MgBetaDeviceManagementScript -All -Property id, displayName, description, lastModifiedDateTime
        }
    } catch {
        throw "Could not read the existing scripts from Intune: $(Get-WizardErrorSummary -ErrorRecord $_). Without that list the wizard cannot tell a new script from an existing one, so it will not deploy anything."
    }
    Write-WizardDebug "Tenant returned $(@($existing).Count) existing scripts"

    # A List rather than repeated '$results += ...': the latter rebuilds the
    # whole array on every iteration (O(n^2) over the tenant's script count).
    # Piping a List to ConvertTo-Json in Save-WizardJsonFile unrolls it exactly
    # as it did the old array, so the cache file on disk is byte-for-byte the same.
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $existing) {
        # Guard against a null timestamp: without it the cache key is meaningless,
        # so fall back to always re-hashing that one script.
        $modified = if ($item.LastModifiedDateTime) { $item.LastModifiedDateTime.ToString('o') } else { $null }

        $cached = $cache[$item.Id]
        # A cached entry with no hash is one a previous run could not read;
        # retry it rather than caching the failure forever.
        if ($modified -and $cached -and $cached.ContentHash -and $cached.LastModifiedDateTime -eq $modified) {
            $hash = ([string]$cached.ContentHash).ToLowerInvariant()
            Write-WizardDebug "  cache hit for $($item.Id) '$($item.DisplayName)'"
        } else {
            # One unreadable script in the tenant must not stop the whole run:
            # its hash is left null, which matches nothing, so the worst case is
            # that a local script is treated as new and matched by name instead.
            $hash = $null
            try {
                Write-WizardDebug "  downloading content for $($item.Id) '$($item.DisplayName)'"
                $full = Invoke-WizardGraphRetry -What "Reading the content of '$($item.DisplayName)'" -Call {
                    Get-MgBetaDeviceManagementScript -DeviceManagementScriptId $item.Id -Property scriptContent
                }
                # See Get-WizardScriptContentBytes for why this cannot just
                # base64-decode the property directly.
                $bytes = Get-WizardScriptContentBytes -Content $full.ScriptContent
                if (-not $bytes) { throw "the tenant returned no script content" }
                $hash = Get-WizardBytesHash -Bytes $bytes
            } catch {
                Write-Warning "Could not hash existing script '$($item.DisplayName)' ($($item.Id)): $(Get-WizardErrorSummary -ErrorRecord $_). It will not be matched by content this run."
                Write-WizardDebug (Get-WizardErrorDetail -ErrorRecord $_)
            }
        }

        $results.Add([pscustomobject]@{
            Id                   = $item.Id
            DisplayName          = $item.DisplayName
            Description          = $item.Description
            LastModifiedDateTime = $modified
            ContentHash          = $hash
        })
    }

    try {
        Save-WizardJsonFile -Path $CachePath -Value $results -Depth 5
    } catch {
        # A read-only -Path is a perfectly valid way to run this tool; losing the
        # cache only means the next run re-downloads content.
        Write-Warning "Could not write the hash cache to '$CachePath': $($_.Exception.Message). The next run will rebuild it."
    }
    return $results
}

# Creates a brand-new deviceManagementScript in Intune from local script
# metadata, then assigns it.
function New-WizardScript {
    param([Parameter(Mandatory)]$Meta)

    Write-Host "Creating '$($Meta.DisplayName)' ($($Meta.Type))..."
    Write-WizardDebug "New script: file=$($Meta.FileName) runAs=$($Meta.RunAsAccount) 32bit=$($Meta.RunAs32Bit) sigCheck=$($Meta.EnforceSignatureCheck) noAssign=$($Meta.NoAssignments)"

    try {
        # -ScriptContentInputFile lets the cmdlet read and base64-encode the
        # script file itself, so this code never has to do that by hand.
        $script = Invoke-WizardGraphRetry -What "Creating '$($Meta.DisplayName)'" -Call {
            New-MgBetaDeviceManagementScript `
            -DisplayName $Meta.DisplayName `
            -Description $Meta.Description `
            -FileName $Meta.FileName `
            -ScriptContentInputFile $Meta.Path `
            -RunAsAccount $Meta.RunAsAccount `
            -EnforceSignatureCheck:$Meta.EnforceSignatureCheck `
            -RunAs32Bit:$Meta.RunAs32Bit
        }
    } catch {
        throw "Creating '$($Meta.DisplayName)' failed: $(Get-WizardErrorSummary -ErrorRecord $_)"
    }

    if (-not $script -or -not $script.Id) {
        throw "Creating '$($Meta.DisplayName)' returned no script id, so its assignments cannot be set. Check the script in the Intune portal before re-running."
    }

    Write-WizardDebug "Created $($script.Id)"

    # Create and assign are two calls with no transaction between them. If the
    # second fails the script exists but reaches nobody, which looks exactly like
    # a script that has not deployed yet - so the id goes in the message, because
    # the next run will not find it by content hash if the file changes again.
    try {
        Set-WizardAssignments -Id $script.Id -Meta $Meta
    } catch {
        throw "'$($Meta.DisplayName)' was created in Intune as $($script.Id) but its assignments could not be set: $(Get-WizardErrorSummary -ErrorRecord $_). The script exists and is assigned to nobody; re-run to finish it, or delete it in the portal."
    }

    return $script
}

# Updates an existing deviceManagementScript's content/settings in place, after
# backing it up first, then re-applies its assignments.
function Update-WizardScript {
    param(
        [Parameter(Mandatory)]$Meta,
        [Parameter(Mandatory)][string]$ExistingId,
        [Parameter(Mandatory)][string]$BackupDir
    )

    # Deliberately not wrapped: if the backup cannot be taken, the update must
    # not happen either. That is the whole point of taking one.
    $backupPath = Backup-WizardScript -Id $ExistingId -BackupDir $BackupDir `
        -ReplacementDisplayName $Meta.DisplayName -ReplacementContentHash (Get-WizardFileHash -Path $Meta.Path)

    Write-Host "Updating '$($Meta.DisplayName)' ($($Meta.Type))..."
    Write-WizardDebug "Update $ExistingId from $($Meta.Path)"

    # Every failure from here on leaves the existing script in some intermediate
    # state, so the backup path travels with the error - restoring it is the one
    # action that always puts the tenant back the way it was.
    $restoreHint = "Restore the previous state with: -Restore '$backupPath'"

    try {
        Invoke-WizardGraphRetry -What "Updating '$($Meta.DisplayName)'" -Call {
            Update-MgBetaDeviceManagementScript `
            -DeviceManagementScriptId $ExistingId `
            -DisplayName $Meta.DisplayName `
            -Description $Meta.Description `
            -FileName $Meta.FileName `
            -ScriptContentInputFile $Meta.Path `
            -RunAsAccount $Meta.RunAsAccount `
            -EnforceSignatureCheck:$Meta.EnforceSignatureCheck `
            -RunAs32Bit:$Meta.RunAs32Bit | Out-Null
        }
    } catch {
        throw "Updating '$($Meta.DisplayName)' ($ExistingId) failed: $(Get-WizardErrorSummary -ErrorRecord $_). $restoreHint"
    }

    try {
        Set-WizardAssignments -Id $ExistingId -Meta $Meta
    } catch {
        throw "'$($Meta.DisplayName)' ($ExistingId) was updated but its assignments were not: $(Get-WizardErrorSummary -ErrorRecord $_). The new script content is live against the old assignments. $restoreHint"
    }
}

# Deletes a deviceManagementScript from Intune entirely.
function Remove-WizardScript {
    # No caller in Deploy-IntuneScripts.ps1 itself - the wizard never deletes
    # anything on its own. Used by e2e-tests/Remove-E2ETestSet.ps1 to tear
    # down scripts it created, and by hand for one-off cleanup.
    param([Parameter(Mandatory)][string]$Id)

    Write-WizardDebug "Deleting $Id"
    try {
        Invoke-WizardGraphRetry -What "Deleting script $Id" -Call {
            Remove-MgBetaDeviceManagementScript -DeviceManagementScriptId $Id
        }
    } catch {
        throw "Could not delete script $Id : $(Get-WizardErrorSummary -ErrorRecord $_)"
    }
}
