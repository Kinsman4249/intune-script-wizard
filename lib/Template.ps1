# Template.ps1
# Tenant -> .ps1 template export orchestration: per-run state, the on-disk
# conflict prompt, exporting one script, and the end-of-run summary. This is
# wired into the wizard through Backup-WizardScript (lib/Backup.ps1), which
# calls Export-WizardScriptTemplate whenever a -Backup/-BackupAll run passes a
# -TemplateRoot. The pure header/byte helpers it builds on live in
# TemplateHeader.ps1.
#
# The point of the feature: regenerate the wizard's own meta-comment directives
# (#scriptname:, #type:, #group:, ...) from a live Intune script's Graph state,
# so a script edited in one tenant can be promoted into another via -SourceRepo.

# One of these is created per -BackupAll run (not per script), so the group
# name cache and the "apply to the rest" prompt answer survive the whole loop.
function New-WizardTemplateRunState {
    [pscustomobject]@{
        # id -> display name, $null included for a resolved-but-missing group.
        # Shared with Resolve-WizardGroupDisplayName's own cache contract.
        GroupNames     = @{}
        # Flipped to $false the first time a group lookup fails for a reason
        # other than "not found" (i.e. GroupMember.Read.All was declined), so
        # the rest of the run stops trying and degrades to GUIDs quietly.
        GroupScopeOk   = $true
        # Case-insensitive: two tenant scripts whose sanitised names collide
        # must be caught regardless of case, same as the filesystem they're
        # about to land on.
        WrittenThisRun = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        # $null until an "apply to the rest" answer ('Write' or 'Skip') is
        # given at a conflict prompt; every later conflict then reuses it
        # instead of asking again.
        BulkAnswer     = $null
        Written        = 0
        Unchanged      = 0
        Excluded       = 0
        Skipped        = 0
        Failed         = 0
        Warnings       = @()
    }
}

# Shows a diff between a template file already on disk and the bytes about to
# replace it, for the [D]iff option at a conflict prompt. Prefers `git diff
# --no-index` (works even outside a repo, and understands binary vs text
# better than a naive line compare); falls back to Compare-Object when git
# isn't available. A failing diff only warns - it must never abort the
# prompt loop it was called from.
function Show-WizardTemplateDiff {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][byte[]]$NewBytes
    )

    $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) "intune-wizard-diff-$([guid]::NewGuid().ToString('N')).ps1"
    try {
        [System.IO.File]::WriteAllBytes($tempFile, $NewBytes)

        $gitAvailable = $false
        try {
            $global:LASTEXITCODE = 0
            & git --version 2>$null | Out-Null
            $gitAvailable = ($LASTEXITCODE -eq 0)
        } catch {
            $gitAvailable = $false
        }

        if ($gitAvailable) {
            # git diff exits non-zero when the files differ, which is the
            # expected/normal case here - not a command failure.
            & git diff --no-index -- $Path $tempFile
        } else {
            Compare-Object -ReferenceObject (Get-Content -LiteralPath $Path) -DifferenceObject (Get-Content -LiteralPath $tempFile) |
                Format-Table -AutoSize | Out-Host
        }
    } catch {
        Write-Warning "Could not produce a diff for '$Path': $($_.Exception.Message)."
    } finally {
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    }
}

# Decides what to do about a template file that already exists on disk.
# Returns 'Write', 'Unchanged', or 'Skip'. Order matters as much as the
# prompt text: the unchanged check comes first so an untouched script never
# prompts, then the bulk answer, then the can't-prompt guard, then the prompt.
function Resolve-WizardTemplateConflict {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][byte[]]$NewBytes,
        [Parameter(Mandatory)]$State
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'Write' }

    $existing = [System.IO.File]::ReadAllBytes($Path)
    if (Test-WizardBytesEqual -A (Get-WizardTemplateComparisonBytes -Bytes $existing) -B (Get-WizardTemplateComparisonBytes -Bytes $NewBytes)) {
        # Without this, every -BackupAll would prompt once per script,
        # forever - most runs touch nothing that changed since the last one.
        $State.Unchanged++
        return 'Unchanged'
    }

    if ($State.BulkAnswer) { return $State.BulkAnswer }

    if (-not (Test-WizardInteractive)) {
        Write-Warning "'$Path' already exists and differs from the tenant's current script, but this session cannot prompt; skipping it. Re-run interactively, or delete the file, to update it."
        return 'Skip'
    }

    while ($true) {
        # [string](...) matters: Read-Host returns $null at end-of-input, and
        # PowerShell's switch skips a $null input entirely - including its
        # default branch - which would fall all the way out of this function
        # with no return value at all. Coercing to a string first makes
        # end-of-input land on the documented default of Skip, the same trap
        # documented at Deploy-IntuneScripts.ps1's fuzzy-match prompt.
        $choice = [string](Read-Host "'$Path' already exists and differs. [O]verwrite / [S]kip / [D]iff / overwrite [A]ll / skip a[L]l? (default: S)")
        switch -Regex ($choice) {
            '^[Oo]' { return 'Write' }
            '^[Dd]' { Show-WizardTemplateDiff -Path $Path -NewBytes $NewBytes; continue }
            '^[Aa]' { $State.BulkAnswer = 'Write'; return 'Write' }
            '^[Ll]' { $State.BulkAnswer = 'Skip'; return 'Skip' }
            default { return 'Skip' }
        }
    }
}

# Exports one tenant script's current state as a template file. The whole
# point of this function: everything it needs (the script object and its
# assignments) is already read by the time Backup-WizardScript calls it, so
# the only NEW Graph traffic this adds is reverse group lookups - capped at
# one per unique group per run via $State.GroupNames.
function Export-WizardScriptTemplate {
    param(
        [Parameter(Mandatory)]$Script,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Assignments,
        [Parameter(Mandatory)][string]$TemplateRoot,
        [Parameter(Mandatory)]$State
    )

    $type = if ($Script.RunAsAccount.ToString() -eq 'user') { 'user' } else { 'device' }
    $targetDir = Join-Path $TemplateRoot $type
    try {
        if (-not (Test-Path -LiteralPath $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir -Force -ErrorAction Stop | Out-Null
        }
    } catch {
        $State.Failed++
        Write-Warning "Could not create '$targetDir' to export a template for '$($Script.DisplayName)': $($_.Exception.Message)."
        return $null
    }

    $rawBytes = Get-WizardScriptContentBytes -Content $Script.ScriptContent
    if (-not $rawBytes) {
        $State.Failed++
        Write-Warning "'$($Script.DisplayName)' came back with no content; skipping its template export."
        return $null
    }

    # Strip any header this script already carries from an earlier export
    # BEFORE checking #notemplate, so a previously-written header can never
    # hide (or fake) the tag: a script re-exported after being tagged must not
    # slip through behind its own old header.
    $bodyBytes = Remove-WizardTemplateHeader -Bytes $rawBytes

    if (Test-WizardTemplateExcluded -Bytes $bodyBytes) {
        $State.Excluded++
        $safeName = Get-WizardSafeFileName -Name $Script.DisplayName -Fallback "script-$($Script.Id)"
        $existingPath = Join-Path $targetDir "$safeName.ps1"
        if (Test-Path -LiteralPath $existingPath -PathType Leaf) {
            # Never auto-deleted: silently removing a file from a directory
            # the user may have since put under git and hand-curated is the
            # wrong default.
            Write-Warning "'$($Script.DisplayName)' now carries #notemplate, but a template file still exists at '$existingPath' from an earlier export. It is not deleted automatically - remove it by hand once you're sure it should no longer be templated."
        }
        return $null
    }

    $includeGroups = @()
    $excludeGroups = @()
    $unsupportedWarnings = @()
    $noAssignments = ($Assignments.Count -eq 0)

    foreach ($assignment in $Assignments) {
        $target = $assignment['target']
        if (-not $target) { continue }
        switch ([string]$target['@odata.type']) {
            '#microsoft.graph.groupAssignmentTarget' {
                $groupId = [string]$target['groupId']
                $includeGroups += @{ Id = $groupId; Name = (Resolve-WizardGroupDisplayName -Id $groupId -State $State) }
            }
            '#microsoft.graph.exclusionGroupAssignmentTarget' {
                $groupId = [string]$target['groupId']
                $excludeGroups += @{ Id = $groupId; Name = (Resolve-WizardGroupDisplayName -Id $groupId -State $State) }
            }
            '#microsoft.graph.allLicensedUsersAssignmentTarget' { }
            '#microsoft.graph.allDevicesAssignmentTarget' { }
            default {
                $unsupportedWarnings += "Assignment target of type '$($target['@odata.type'])' on '$($Script.DisplayName)' cannot be expressed by any #group:/#excludegroup: directive; the JSON backup is the record of it."
            }
        }
    }

    $newLine = if (Test-WizardBodyUsesCrlf -Bytes $bodyBytes) { "`r`n" } else { "`n" }

    $headerResult = New-WizardTemplateHeader `
        -TenantId (Get-MgContext).TenantId `
        -ExportedAt (Get-Date) `
        -DisplayName $Script.DisplayName `
        -Description ([string]$Script.Description) `
        -Type $type `
        -EnforceSignatureCheck:([bool]$Script.EnforceSignatureCheck) `
        -RunAs32Bit (Get-WizardScriptRunAs32Bit -Script $Script) `
        -NoAssignments:$noAssignments `
        -IncludeGroups $includeGroups `
        -ExcludeGroups $excludeGroups `
        -UnsupportedTargetWarnings $unsupportedWarnings `
        -RoleScopeTagIds @($Script.RoleScopeTagIds) `
        -OriginalFileName $Script.FileName `
        -NewLine $newLine

    foreach ($w in $headerResult.Warnings) {
        Write-Warning "'$($Script.DisplayName)': $w"
        $State.Warnings += $w
    }

    $headerBytes = [System.Text.Encoding]::UTF8.GetBytes($headerResult.Text)
    $finalBytes = $headerBytes + $bodyBytes

    # No timestamp in the filename - a template's value is a stable path
    # across exports, unlike a backup's.
    $safeName = Get-WizardSafeFileName -Name $Script.DisplayName -Fallback "script-$($Script.Id)"
    $fileName = "$safeName.ps1"
    if ($State.WrittenThisRun.Contains($fileName)) {
        # Two tenant scripts sanitising to the same name: append -2, -3, ...
        # and warn. Never prompts - this is a naming collision within THIS
        # run, not a conflict with something already on disk.
        $attempt = 2
        while ($State.WrittenThisRun.Contains("$safeName-$attempt.ps1")) { $attempt++ }
        $fileName = "$safeName-$attempt.ps1"
        Write-Warning "Two tenant scripts sanitise to the same template filename '$safeName.ps1'; '$($Script.DisplayName)' was exported as '$fileName' instead."
    }
    $path = Join-Path $targetDir $fileName

    $action = Resolve-WizardTemplateConflict -Path $path -NewBytes $finalBytes -State $State
    if ($action -ne 'Write') {
        if ($action -eq 'Skip') { $State.Skipped++ }
        return $null
    }

    $temp = "$path.$([guid]::NewGuid().ToString('N').Substring(0, 8)).tmp"
    try {
        [System.IO.File]::WriteAllBytes($temp, $finalBytes)
        Move-Item -LiteralPath $temp -Destination $path -Force -ErrorAction Stop
    } catch {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        $State.Failed++
        Write-Warning "Could not write the template for '$($Script.DisplayName)' to '$path': $($_.Exception.Message)."
        return $null
    }

    [void]$State.WrittenThisRun.Add($fileName)
    $State.Written++
    Write-Host "  Exported template '$($Script.DisplayName)' -> $path" -ForegroundColor DarkGray
    return $path
}

# Prints the final tally at the end of a run that exported templates, in the
# style of Write-WizardRunSummary (Deploy-IntuneScripts.ps1).
function Write-WizardTemplateSummary {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$TemplateRoot
    )

    Write-Host ""
    Write-Host "Templates: $($State.Written) written, $($State.Unchanged) unchanged, $($State.Excluded) excluded (#notemplate), $($State.Skipped) skipped, $($State.Failed) failed"
    Write-Host "  -> $TemplateRoot" -ForegroundColor DarkGray
    Write-Host "  Deploy them to another tenant with: -SourceRepo <url>  (or -Path $TemplateRoot)" -ForegroundColor DarkGray
}
