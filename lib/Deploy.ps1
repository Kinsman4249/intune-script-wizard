# Deploy.ps1
# The per-script deploy decisions and the two standalone modes (-Backup/
# -BackupAll and -Restore/-RestoreAll). Split out of Deploy-IntuneScripts.ps1
# so the entry script keeps only its comment-based help, parameter block, the
# library loader, Invoke-WizardRun, and the process entry point.
#
# These functions read the wizard's script parameters ($OnFuzzyMatch and the
# rest) through PowerShell's scope chain: the call always originates from the
# entry script, so its parameters are in scope here even though the code lives
# in a dot-sourced file. The two mode functions instead take everything they
# need as explicit parameters, because they are the boundary the entry script
# hands control to.

# "Fuzzy match" means a local script's name/description looks a lot like (but
# not exactly like) a script that already exists in Intune. This function
# decides what to do about that: skip it, replace the existing one, or create
# a second, side-by-side copy. If the caller already told us what to do via
# -OnFuzzyMatch, we just use that; otherwise we ask interactively.
function Resolve-FuzzyAction {
    param(
        [Parameter(Mandatory)]$Local,
        [Parameter(Mandatory)]$Existing,
        [Parameter(Mandatory)][double]$Similarity
    )

    if ($OnFuzzyMatch) { return $OnFuzzyMatch }

    # Read-Host against a redirected stdin returns an empty string rather than
    # failing, which the switch below would read as "Skip". Silently skipping a
    # script in an unattended run is the kind of non-failure that gets noticed
    # weeks later, so refuse to guess.
    if (-not (Test-WizardInteractive)) {
        throw "'$($Local.DisplayName)' looks like a near-duplicate of the existing script '$($Existing.DisplayName)' ($([Math]::Round($Similarity * 100))% similar), and this session cannot prompt. Re-run with -OnFuzzyMatch Skip|Replace|SideBySide."
    }

    Write-Host ""
    Write-Host "Possible duplicate (similarity $([Math]::Round($Similarity * 100))%):" -ForegroundColor Yellow
    Write-Host "  Local:    $($Local.DisplayName)"
    Write-Host "  Existing: $($Existing.DisplayName)"
    # [string] is load-bearing. Read-Host returns $null at end-of-input (Ctrl+D,
    # or a console that closes under the prompt), and 'switch' skips a $null
    # input entirely - including its default branch - so the function returned
    # nothing and the caller fell through to creating a duplicate. Coercing to a
    # string makes end-of-input land on the documented default of Skip.
    $choice = [string](Read-Host "[S]kip / [R]eplace existing / [C]reate side-by-side?")
    # See ConvertTo-WizardFuzzyChoice in lib/Matching.ps1 for how an answer is
    # read. The prompt used to end "create [side-by-side]?" while only
    # accepting an answer starting 'si', so typing the word it asked for -
    # "create" - fell through to the default and silently skipped the script.
    return (ConvertTo-WizardFuzzyChoice -Choice $choice)
}

# After we create or update a script in Intune, we record that fact in $Registry
# (an in-memory list standing in for "everything currently in the tenant"). This
# keeps the in-memory view of the tenant accurate within a single run, so a
# script created or updated early on is visible to the matching logic for
# every later script. The list is passed in rather than reached for through
# the scope chain, so the dependency is visible at the call site.
function Register-DeployedScript {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Registry,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)]$Meta,
        [Parameter(Mandatory)][string]$ContentHash
    )

    # Where-Object filters the list down to items matching the condition; piping
    # that into Select-Object -First 1 keeps just the first match (or $null if
    # there were none). This is PowerShell's usual way of doing a "find" lookup.
    $existing = $Registry | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if ($existing) {
        # Already in the list (from an earlier read of the tenant) - update its
        # fields in place rather than adding a duplicate entry.
        $existing.DisplayName = $Meta.DisplayName
        $existing.Description = $Meta.Description
        $existing.ContentHash = $ContentHash
    } else {
        # Brand new to this run - [pscustomobject]@{...} builds a simple record
        # (like a dictionary/struct) with these named fields, and we add it to
        # the list.
        $Registry.Add([pscustomobject]@{
            Id                   = $Id
            DisplayName          = $Meta.DisplayName
            Description          = $Meta.Description
            LastModifiedDateTime = (Get-Date).ToString('o')
            ContentHash          = $ContentHash
        })
    }
    Write-WizardDebug "In-run state updated for $Id ($($Meta.DisplayName))"
}

# Decides what one local script needs and does it, returning an outcome for
# the run summary. Everything here used to live in the deploy loop with
# 'continue nextScript' at each exit; as a function each of those becomes a
# plain 'return', which removes the labelled-continue-inside-switch trap the
# old loop had to carry a warning about, and makes the whole body wrappable
# in a single try/catch by the caller.
function Invoke-WizardScriptDeployment {
    param(
        [Parameter(Mandatory)]$Meta,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Registry,
        [Parameter(Mandatory)][string]$BackupDir,
        [switch]$DryRun,
        # When set (only by a -DryRun -SavePlan/-ReportCsv run), every outcome
        # below is also recorded here as a concrete action (Create/Update/
        # Skip/UpToDate) - see lib/Plan.ps1. $null on a normal run: cheapest
        # possible no-op for the common case.
        [System.Collections.Generic.List[object]]$PlanActions
    )

    # A hash is a short fingerprint calculated from the file's contents: two
    # files with the exact same text produce the exact same hash, and any
    # change at all produces a completely different one. Comparing hashes lets
    # us tell "identical content" apart from "same name, different content"
    # without downloading and diffing the full text of every existing script.
    $localHash = Get-WizardFileHash -Path $Meta.Path
    Write-WizardDebug "Local hash $localHash for $($Meta.Path)"
    $contentMatch = $Registry | Where-Object { $_.ContentHash -eq $localHash } | Select-Object -First 1

    if ($contentMatch -and $contentMatch.DisplayName -eq $Meta.DisplayName) {
        Write-Host "  Already up to date (content and name match existing script $($contentMatch.Id))."
        Add-WizardPlanAction -PlanActions $PlanActions -Path $Meta.Path -DisplayName $Meta.DisplayName -Action 'UpToDate'
        return 'UpToDate'
    }

    if ($contentMatch) {
        # Same content, different display name. Similarity 1.0 (100%) is passed
        # even though this isn't going through the fuzzy-name scoring below,
        # because "identical content" is as sure a match as it gets.
        Write-Host "  Identical content already exists in Intune as '$($contentMatch.DisplayName)' ($($contentMatch.Id))." -ForegroundColor Yellow
        $action = Resolve-FuzzyAction -Local $Meta -Existing $contentMatch -Similarity 1.0
        switch ($action) {
            'Skip' {
                Write-Host "  Skipped."
                Add-WizardPlanAction -PlanActions $PlanActions -Path $Meta.Path -DisplayName $Meta.DisplayName -Action 'Skip'
                return 'Skipped'
            }
            'Replace' {
                if ($DryRun) {
                    Write-Host "  [DryRun] Would rename/update $($contentMatch.Id) to match local metadata."
                    Add-WizardPlanAction -PlanActions $PlanActions -Path $Meta.Path -DisplayName $Meta.DisplayName -Action 'Update' -TargetId $contentMatch.Id
                    return 'Planned'
                }
                Update-WizardScript -Meta $Meta -ExistingId $contentMatch.Id -BackupDir $BackupDir
                Register-DeployedScript -Registry $Registry -Id $contentMatch.Id -Meta $Meta -ContentHash $localHash
                return 'Updated'
            }
            'SideBySide' { } # fall through to normal create below
            # Anything else means Resolve-FuzzyAction returned something the
            # caller does not understand. Falling through would quietly create a
            # duplicate, so make it a failure instead.
            default { throw "Internal error: unrecognised duplicate-handling choice '$action'." }
        }
    }

    # No content match. Next check: is there already a script with this exact
    # display name (different content)? If so it's an update, not a new script.
    $nameMatch = $Registry | Where-Object { $_.DisplayName -eq $Meta.DisplayName } | Select-Object -First 1
    if ($nameMatch) {
        if ($DryRun) {
            Write-Host "  [DryRun] Would back up and update existing script $($nameMatch.Id)."
            Add-WizardPlanAction -PlanActions $PlanActions -Path $Meta.Path -DisplayName $Meta.DisplayName -Action 'Update' -TargetId $nameMatch.Id
            return 'Planned'
        }
        Update-WizardScript -Meta $Meta -ExistingId $nameMatch.Id -BackupDir $BackupDir
        Register-DeployedScript -Registry $Registry -Id $nameMatch.Id -Meta $Meta -ContentHash $localHash
        return 'Updated'
    }

    # Neither exact match hit, so scan every existing script and score how
    # similar its name/description are to this local one (0.0 = nothing alike,
    # 1.0 = identical text), keeping track of whichever scores highest.
    $best = $null
    $bestScore = 0.0
    foreach ($ex in $Registry) {
        $score = Get-WizardMatchScore `
            -LocalName $Meta.DisplayName -LocalDescription $Meta.Description `
            -ExistingName $ex.DisplayName -ExistingDescription ([string]$ex.Description)
        if ($score -gt $bestScore) { $bestScore = $score; $best = $ex }
    }
    if ($best) {
        Write-WizardDebug "Best fuzzy candidate '$($best.DisplayName)' scored $([Math]::Round($bestScore, 3))"
    }

    # Only treat it as a possible duplicate if the best score clears the
    # configured threshold (defined in lib/Matching.ps1) - a weak resemblance
    # isn't worth interrupting the run to ask about.
    if ($best -and $bestScore -ge $script:FuzzyMatchThreshold) {
        $action = Resolve-FuzzyAction -Local $Meta -Existing $best -Similarity $bestScore
        switch ($action) {
            'Skip' {
                Write-Host "  Skipped."
                Add-WizardPlanAction -PlanActions $PlanActions -Path $Meta.Path -DisplayName $Meta.DisplayName -Action 'Skip'
                return 'Skipped'
            }
            'Replace' {
                if ($DryRun) {
                    Write-Host "  [DryRun] Would back up and replace $($best.Id) with local script."
                    Add-WizardPlanAction -PlanActions $PlanActions -Path $Meta.Path -DisplayName $Meta.DisplayName -Action 'Update' -TargetId $best.Id
                    return 'Planned'
                }
                Update-WizardScript -Meta $Meta -ExistingId $best.Id -BackupDir $BackupDir
                Register-DeployedScript -Registry $Registry -Id $best.Id -Meta $Meta -ContentHash $localHash
                return 'Updated'
            }
            'SideBySide' { } # fall through
            default { throw "Internal error: unrecognised duplicate-handling choice '$action'." }
        }
    }

    # Nothing matched at all (or it did, and the user chose SideBySide) - this
    # is a genuinely new script.
    if ($DryRun) {
        Write-Host "  [DryRun] Would create new script '$($Meta.DisplayName)'."
        Add-WizardPlanAction -PlanActions $PlanActions -Path $Meta.Path -DisplayName $Meta.DisplayName -Action 'Create'
        return 'Planned'
    }
    $created = New-WizardScript -Meta $Meta
    Register-DeployedScript -Registry $Registry -Id $created.Id -Meta $Meta -ContentHash $localHash
    return 'Created'
}

# Replays one already-decided plan action (from -ApplyPlan) against the
# tenant, without re-running any duplicate/fuzzy-match detection - that
# decision was made and recorded when the plan was saved. The signature check
# in lib/Plan.ps1 is what makes skipping that re-detection safe.
function Invoke-WizardPlanAction {
    param(
        [Parameter(Mandatory)]$PlanEntry,
        [Parameter(Mandatory)]$Meta,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Registry,
        [Parameter(Mandatory)][string]$BackupDir
    )

    $localHash = Get-WizardFileHash -Path $Meta.Path
    switch ($PlanEntry['Action']) {
        'Create' {
            $created = New-WizardScript -Meta $Meta
            Register-DeployedScript -Registry $Registry -Id $created.Id -Meta $Meta -ContentHash $localHash
            return 'Created'
        }
        'Update' {
            $targetId = $PlanEntry['TargetId']
            if ([string]::IsNullOrWhiteSpace($targetId)) {
                throw "Internal error: plan entry for '$($Meta.Path)' is an Update with no TargetId."
            }
            Update-WizardScript -Meta $Meta -ExistingId $targetId -BackupDir $BackupDir
            Register-DeployedScript -Registry $Registry -Id $targetId -Meta $Meta -ContentHash $localHash
            return 'Updated'
        }
        'Skip'     { Write-Host "  Skipped (per plan)."; return 'Skipped' }
        'UpToDate' { Write-Host "  Already up to date (per plan)."; return 'UpToDate' }
        default { throw "Internal error: plan entry for '$($Meta.Path)' has an unrecognised action '$($PlanEntry['Action'])'." }
    }
}

# Prints the final tally at the end of a run (how many scripts were created,
# updated, skipped, etc) and the details of any failures.
function Write-WizardRunSummary {
    param(
        [Parameter(Mandatory)][hashtable]$Outcomes,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Failures,
        # Printed at the end of any run that updated something, because that is
        # the only way a backup gets written and "where did it put the backup?"
        # is the next question - most often asked when the update was wrong and
        # the answer is needed in a hurry.
        [string]$BackupDir,
        [switch]$Aborted
    )

    $counts = @(
        "$($Outcomes['Created']) created"
        "$($Outcomes['Updated']) updated"
        "$($Outcomes['UpToDate']) already up to date"
        "$($Outcomes['Skipped']) skipped"
    )
    if ($Outcomes['Planned'] -gt 0) { $counts += "$($Outcomes['Planned']) planned (dry run)" }
    if ($Failures.Count -gt 0)      { $counts += "$($Failures.Count) failed" }

    Write-Host ""
    if ($Failures.Count -gt 0) {
        Write-Host ($counts -join ', ') -ForegroundColor Yellow
        Write-Host "Failed:" -ForegroundColor Red
        foreach ($failure in $Failures) {
            Write-Host "  $($failure.DisplayName)  [$($failure.Path)]" -ForegroundColor Red
            Write-Host "    $($failure.Reason)" -ForegroundColor Red
        }
        if ($Aborted) {
            Write-Host "Stopped at the first failure (-StopOnError); the remaining scripts were not attempted." -ForegroundColor Yellow
        }
    } else {
        Write-Host ($counts -join ', ')
        Write-Host "Done." -ForegroundColor Green
    }

    # Only when something was actually backed up: pointing at an empty or
    # non-existent folder after a create-only run would be noise.
    if ($Outcomes['Updated'] -gt 0 -and $BackupDir -and (Test-Path -LiteralPath $BackupDir)) {
        Write-Host ""
        Write-Host "Backups of everything updated this run: $BackupDir" -ForegroundColor Cyan
        Write-Host "  Undo one with: ./Deploy-IntuneScripts.ps1 -Restore '<file>'" -ForegroundColor DarkGray
        Write-Host "  List them with: ./Deploy-IntuneScripts.ps1 -ListBackups" -ForegroundColor DarkGray
    }
}

# The standalone -Backup/-BackupAll mode: reads the tenant and writes local
# snapshot(s), same as Update-WizardScript takes before an update - but on
# demand, with no local -Path scan and nothing pushed to Intune. Also exports
# a .ps1 template per script (see lib/Template.ps1) unless -NoTemplates was
# given. Returns the process exit code.
function Invoke-WizardBackupMode {
    param(
        [Parameter(Mandatory)][string]$ResolvedPath,
        [Parameter(Mandatory)][string]$BackupDir,
        [Parameter(Mandatory)][string]$TemplateDir,
        [string]$Backup,
        [switch]$BackupAll,
        [switch]$NoTemplates,
        [switch]$DryRun
    )

    $templateState = $null
    if ($NoTemplates) {
        Connect-WizardGraph
    } else {
        # GroupMember.Read.All is optional here: declined, it degrades to
        # bare GUIDs in the exported templates rather than failing sign-in.
        Connect-WizardGraph -OptionalScopes @($script:GroupReadScope)
        $templateState = New-WizardTemplateRunState
        $templateState.GroupScopeOk = Test-WizardGroupScopeGranted
    }

    $targets = @(Resolve-WizardBackupTargets -NameOrId $Backup -All:$BackupAll)
    if ($targets.Count -eq 0) {
        Write-Host "No scripts found in this tenant to back up."
        return $script:WizardExitOk
    }

    if ($DryRun) {
        Write-Host "Would back up $($targets.Count) script(s):"
        foreach ($target in $targets) { Write-Host "  $($target.DisplayName) ($($target.Id))" }
        if (-not $NoTemplates) {
            # Resolve-WizardBackupTargets only reads id/displayName, so which
            # targets are user/ vs device/ isn't known without the full
            # per-script read - print the root and count rather than pretending
            # to list paths that aren't known yet.
            Write-Host "Would also export $($targets.Count) template(s) to $TemplateDir"
        }
        return $script:WizardExitOk
    }

    Write-Host "Backing up $($targets.Count) script(s) to $BackupDir..."
    $backupFailures = @()
    foreach ($target in $targets) {
        try {
            if ($NoTemplates) {
                Backup-WizardScript -Id $target.Id -BackupDir $BackupDir | Out-Null
            } else {
                Backup-WizardScript -Id $target.Id -BackupDir $BackupDir `
                    -TemplateRoot $TemplateDir -TemplateState $templateState | Out-Null
            }
        } catch {
            # One script's failure says nothing about the next one's, so the
            # run keeps going and reports everything at the end - same as
            # the deploy loop and -RestoreAll.
            $reason = Write-WizardFailure -Context "Backing up '$($target.DisplayName)' failed." -ErrorRecord $_
            $backupFailures += [pscustomobject]@{ Name = $target.DisplayName; Reason = $reason }
        }
    }

    Write-Host ""
    $backedUpCount = $targets.Count - $backupFailures.Count
    if ($backedUpCount -gt 0) {
        Push-WizardBackupsToRepo -BackupDir $BackupDir
        if (-not $NoTemplates) {
            Write-WizardTemplateSummary -State $templateState -TemplateRoot $TemplateDir
            Push-WizardTemplatesToRepo -TemplateDir $TemplateDir
        }
    }
    # Template failures warn (see Backup-WizardScript) and never change this
    # exit code - the JSON backup is the safety net and it already succeeded;
    # failing a -BackupAll because one group was deleted is the wrong trade.
    if ($backupFailures.Count -gt 0) {
        Write-Host "$backedUpCount backed up, $($backupFailures.Count) failed" -ForegroundColor Yellow
        Write-Host "Failed:" -ForegroundColor Red
        foreach ($failure in $backupFailures) {
            Write-Host "  $($failure.Name)" -ForegroundColor Red
            Write-Host "    $($failure.Reason)" -ForegroundColor Red
        }
        return $script:WizardExitPartial
    }
    Write-Host "$backedUpCount backed up, all succeeded." -ForegroundColor Green
    return $script:WizardExitOk
}

# The standalone -Restore/-RestoreAll mode. Returns the process exit code.
function Invoke-WizardRestoreMode {
    param(
        [Parameter(Mandatory)][string]$Restore,
        [switch]$RestoreAll,
        [switch]$SkipAssignments,
        [switch]$DryRun
    )

    # -DryRun cannot be honoured here - a restore is a single write with
    # nothing to preview - and silently ignoring it would mutate the tenant
    # for someone who explicitly asked for no changes.
    if ($DryRun) {
        throw "-DryRun cannot be combined with -Restore: a restore has nothing to preview, and running it anyway would change the tenant. Drop one of the two."
    }

    if (-not $RestoreAll) {
        Connect-WizardGraph
        Restore-WizardBackup -BackupFile $Restore -SkipAssignments:$SkipAssignments | Out-Null
        return $script:WizardExitOk
    }

    if (-not (Test-Path -LiteralPath $Restore -PathType Container)) {
        throw "-RestoreAll needs -Restore to be a folder, but '$Restore' is not one."
    }
    # Not -Recurse: backup-restored/ sits directly under here and holds
    # already-restored backups, which must not be restored a second time.
    $files = @(Get-ChildItem -LiteralPath $Restore -Filter '*.json' -File)
    if ($files.Count -eq 0) {
        Write-Host "No backup files found directly under $Restore"
        return $script:WizardExitOk
    }

    # Several backups of one script is the normal state of a backups/ folder,
    # and restoring all of them just replays that script's history in an order
    # nobody chose - see Select-WizardRestoreSet.
    $plan = Select-WizardRestoreSet -Files $files
    foreach ($file in $plan.Ignored) {
        Write-Warning "Skipping '$($file.Name)': it is not a wizard backup (no Id/ScriptContent/SchemaVersion in it)."
    }
    foreach ($entry in $plan.Superseded) {
        Write-Warning "Skipping '$($entry.File.Name)': a later backup of the same script ($($entry.Id)), and restoring the oldest is what undoes the whole folder. Restore this one on its own with -Restore if that is the state you want."
    }
    if ($plan.Restore.Count -eq 0) {
        Write-Host "Nothing to restore: none of the $($files.Count) .json file(s) directly under $Restore is a wizard backup."
        return $script:WizardExitOk
    }

    Connect-WizardGraph
    Write-Host "Restoring $($plan.Restore.Count) backup(s) from $Restore..."
    $restoreFailures = @()
    foreach ($file in ($plan.Restore | ForEach-Object { $_.File })) {
        Write-Host ""
        Write-Host "== $($file.Name) ==" -ForegroundColor Cyan
        try {
            Restore-WizardBackup -BackupFile $file.FullName -SkipAssignments:$SkipAssignments | Out-Null
        } catch {
            # One backup's failure says nothing about the next one's, so the
            # run keeps going and reports everything at the end - same as
            # the normal deploy loop.
            $reason = Write-WizardFailure -Context "Restoring '$($file.Name)' failed." -ErrorRecord $_
            $restoreFailures += [pscustomobject]@{ Name = $file.Name; Reason = $reason }
        }
    }

    Write-Host ""
    $restoredCount = $plan.Restore.Count - $restoreFailures.Count
    if ($restoreFailures.Count -gt 0) {
        Write-Host "$restoredCount restored, $($restoreFailures.Count) failed" -ForegroundColor Yellow
        Write-Host "Failed:" -ForegroundColor Red
        foreach ($failure in $restoreFailures) {
            Write-Host "  $($failure.Name)" -ForegroundColor Red
            Write-Host "    $($failure.Reason)" -ForegroundColor Red
        }
        return $script:WizardExitPartial
    }
    Write-Host "$restoredCount restored, all succeeded." -ForegroundColor Green
    return $script:WizardExitOk
}
