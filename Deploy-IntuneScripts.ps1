#Requires -Version 7.0
<#
.SYNOPSIS
    Deploys PowerShell platform scripts to Intune from local user/ and device/ folders.

.DESCRIPTION
    Scans -Path for .ps1 files under user/ and device/ subfolders (or loose files
    carrying a #type:user|device comment) and creates/updates matching Intune
    deviceManagementScript objects via Microsoft Graph beta.

    Meta comments recognised inside a script:
      #scriptname:"Override Name"   - display name override (else filename)
      #startdesc / #enddesc         - lines between these become the description
      #type:user|device             - required only if the script isn't under
                                       a user/ or device/ folder. If the script
                                       IS under one of those folders, the folder
                                       wins over a conflicting #type: comment
                                       unless #typeoverride:yes is also present,
                                       or the run used -AllowTypeOverride.
      #typeoverride:yes             - let a conflicting #type: comment win over
                                       the folder the script is sitting in
      #noassignments / #noassigments - do not assign this script to anyone
      #group:"Name" or #group:<guid> - assign to this group instead of all
                                       users/devices; repeatable
      #excludegroup:"Name"|<guid>   - exclude this group; repeatable, and usable
                                       on its own to mean "everyone except"
      #scriptcheck:yes              - enforce script signature check (default: off)
      #host:64                      - run in 64-bit PowerShell host (default: 32-bit)

    Group display names are resolved against Entra ID, which adds the
    GroupMember.Read.All scope to the sign-in - but only when a script actually
    names one. Values that parse as a GUID are used directly. Resolution runs
    as a pre-flight, so an unknown or ambiguous name aborts before any script
    is created or updated.

    Exit codes:
      0 - every script the run set out to deploy succeeded
      1 - the run stopped early: bad arguments, sign-in, a failed pre-flight,
          or -StopOnError tripping on the first script failure
      2 - the run finished, but one or more individual scripts failed

.PARAMETER Path
    Root folder containing user/ and/or device/ subfolders. Defaults to the
    current directory.

.PARAMETER OnFuzzyMatch
    How to resolve a near-duplicate (not exact) name/description match against
    an existing Intune script, without prompting: Skip, Replace, or SideBySide.
    If omitted, you're prompted interactively for each fuzzy match - and a
    session that cannot prompt (a pipeline or scheduled task) fails instead,
    rather than quietly skipping the script.

.PARAMETER AcceptModuleInstall
    Install missing required Graph modules without prompting.

.PARAMETER DryRun
    Print what would happen without making any Graph calls that change data.

.PARAMETER AllowTypeOverride
    Let a conflicting #type: comment win over its user/device folder for every
    script in this run, instead of adding #typeoverride:yes to each one.

.PARAMETER StopOnError
    Stop at the first script that fails instead of carrying on with the rest.
    By default one failing script is reported and the run continues, exiting
    with code 2 at the end; with this switch the run exits 1 immediately.

.PARAMETER Restore
    Path to a JSON backup file (see backups/) to restore in one command. All
    other parameters except -DebugLog are ignored in this mode. Combine with
    -RestoreAll to instead point this at a folder and restore every backup in
    it (each restored script is worked out independently, so one failing does
    not stop the rest - see the summary at the end for what did and didn't
    make it).

.PARAMETER RestoreAll
    Treats -Restore as a folder instead of a single file, and restores every
    *.json backup directly inside it (not recursive - restored ones already
    moved to backup-restored/ are skipped automatically). Where the folder
    holds more than one backup of the SAME script, only the oldest is restored
    - that is the one that undoes everything the folder recorded - and the
    others are named in a warning and left on disk for -Restore to take one at
    a time. Files that aren't wizard backups are skipped, not failed.

.PARAMETER SkipAssignments
    Restore the script itself and leave its current assignments alone. For when
    the assign step cannot succeed at all: groups named in the backup that have
    been deleted since, or a backup being restored into a different tenant.
    Only valid with -Restore.

.PARAMETER Backup
    Back up one existing Intune script by display name or Id, without scanning
    -Path or deploying anything. Writes the same snapshot Update-WizardScript
    would take before an update, into -Path/backups. Combine with -DryRun to
    see which script would be backed up without writing the file.

.PARAMETER BackupAll
    Back up every script currently in the tenant, one file each under
    -Path/backups. Takes no value; -Backup is ignored if also passed.

.PARAMETER ListBackups
    List available backup files under -Path/backups and exit.

.PARAMETER DebugLog
    Trace Graph URLs, request bodies and match scores. Console writes to the
    host, File writes to -Path/logs/wizard-<timestamp>.log, Both does each.
    The build stamp is printed whenever this is on, and any fatal error is
    recorded there in full.

.PARAMETER SourceRepo
    One or more git repos to pull user/device scripts from, in addition to
    whatever -Path itself contains. Each entry is
    '<git-url>[#<ref>][::<subpath>]' - #<ref> clones that branch/tag instead
    of the default, and ::<subpath> scans only that folder within the clone
    for user/ and device/ rather than the clone's root. Repeatable. Each repo
    is freshly, shallowly cloned into -Path/.repo-sources on every run (never
    an incremental fetch, so there's no local clone state to reconcile), and
    needs git installed and on PATH.

.PARAMETER SavePlan
    Only valid with -DryRun. Writes the exact plan this dry run produced -
    every script's decided action (create/update/skip), including which
    fuzzy-match choice was made - to the given JSON file. -ApplyPlan later
    replays it exactly, rather than recomputing and hoping nothing changed.

.PARAMETER ApplyPlan
    Replays a plan written by -SavePlan as a real deploy. Before doing
    anything, it re-checks the local scripts and the tenant against a
    signature captured when the plan was saved, and refuses to apply if
    either has changed since - so what gets applied is provably what was
    reviewed. Cannot be combined with -DryRun, -SavePlan, -ReportCsv,
    -Restore/-RestoreAll, -Backup/-BackupAll, or -OnFuzzyMatch (the plan
    already recorded every duplicate-handling decision).

.PARAMETER ReportCsv
    Only valid with -DryRun. Writes the planned changes to the given CSV file
    (display name, type, action, assignment target, existing script id where
    relevant) - a management-approval report that opens straight into Excel,
    in addition to the usual console summary.
#>
[CmdletBinding()]
param(
    [string]$Path = (Get-Location).Path,
    [ValidateSet('Skip', 'Replace', 'SideBySide')]
    [string]$OnFuzzyMatch,
    [switch]$AcceptModuleInstall,
    [switch]$DryRun,
    [switch]$AllowTypeOverride,
    [switch]$StopOnError,
    [string]$Restore,
    [switch]$RestoreAll,
    [switch]$SkipAssignments,
    [string]$Backup,
    [switch]$BackupAll,
    [switch]$ListBackups,
    [ValidateSet('None', 'Console', 'File', 'Both')]
    [string]$DebugLog = 'None',
    [string[]]$SourceRepo,
    [string]$SavePlan,
    [string]$ApplyPlan,
    [string]$ReportCsv
)

# Stop the whole script the instant any command raises an error, instead of
# limping on with bad data. Almost every well-behaved PowerShell script sets this.
$ErrorActionPreference = 'Stop'
# $PSScriptRoot is a built-in variable holding the folder this .ps1 file lives in,
# no matter where the user ran it from. We save it under our own name ($here) so
# it still reads correctly inside functions defined further down.
$here = $PSScriptRoot

# This script is split into several small files under lib/ (one topic each:
# errors, logging, parsing, etc). PowerShell's dot-source operator ". <path>"
# runs another script file as if its contents were pasted in right here, which
# is how all the Get-Wizard*/Write-Wizard*/etc functions used below become
# available. Loading the library is the one thing that happens before the
# wizard's own error reporting exists, so it gets its own plain try/catch.
try {
    foreach ($libFile in @('Errors.ps1', 'Logging.ps1', 'Storage.ps1', 'Prereqs.ps1',
                           'Parsing.ps1', 'Matching.ps1', 'GraphOps.ps1', 'Backup.ps1',
                           'RepoBackup.ps1', 'RepoSource.ps1', 'Plan.ps1', 'Telemetry.ps1')) {
        $libPath = Join-Path $here 'lib' $libFile
        if (-not (Test-Path -LiteralPath $libPath -PathType Leaf)) {
            throw "Required library file is missing: $libPath. Copy or clone the wizard folder in full, including lib/."
        }
        . $libPath
    }
} catch {
    # [Console]::Error.WriteLine writes straight to stderr, bypassing PowerShell's
    # own error formatting, since none of our nicer logging helpers exist yet.
    [Console]::Error.WriteLine("intune-script-wizard: $($_.Exception.Message)")
    exit 1
}

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

# The whole run, returning the process exit code. Written as a function so
# every early exit is a 'return' the outer handler can see, rather than an
# 'exit' that jumps out past the logging teardown.
function Invoke-WizardRun {

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "-Path '$Path' does not exist or is not a folder."
    }
    # Resolve-Path turns a relative or possibly-messy path (like ".") into the
    # full, canonical filesystem path, so the rest of the script always works
    # with an unambiguous location.
    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path

    Initialize-WizardLogging -Mode $DebugLog -LogRoot $resolvedPath
    Write-WizardDebug "Path=$resolvedPath DryRun=$DryRun OnFuzzyMatch=$OnFuzzyMatch AllowTypeOverride=$AllowTypeOverride StopOnError=$StopOnError"

    $backupDir = Join-Path $resolvedPath 'backups'
    $cachePath = Join-Path $resolvedPath '.intune-script-cache.json'

    if ($ListBackups) {
        if (-not (Test-Path -LiteralPath $backupDir)) {
            Write-Host "No backups directory yet at $backupDir"
            return $script:WizardExitOk
        }
        Get-ChildItem -LiteralPath $backupDir -Filter '*.json' | Sort-Object LastWriteTime -Descending |
            Format-Table Name, LastWriteTime -AutoSize
        return $script:WizardExitOk
    }

    # Make sure we're on a supported PowerShell version, that the Microsoft
    # Graph PowerShell modules this script depends on are installed (offering
    # to install them if not), and then load them into this session.
    Test-WizardPSVersion
    Install-WizardModules -AcceptInstall:$AcceptModuleInstall
    Import-WizardModules

    if ($RestoreAll -and -not $Restore) {
        throw "-RestoreAll needs -Restore to point at the folder of backups to restore."
    }
    # Silently ignoring it would leave someone believing a deploy had skipped
    # assignments when it had not.
    if ($SkipAssignments -and -not $Restore) {
        throw "-SkipAssignments only applies to a restore. Add -Restore <file|folder>, or drop the switch."
    }
    if ($Backup -and $BackupAll) {
        throw "-Backup and -BackupAll are mutually exclusive: -Backup backs up one script by name or Id, -BackupAll backs up every script in the tenant."
    }
    if (($Backup -or $BackupAll) -and $Restore) {
        throw "-Backup/-BackupAll cannot be combined with -Restore. Run them separately."
    }
    if ($SavePlan -and -not $DryRun) {
        throw "-SavePlan needs -DryRun: a plan is captured from a dry run, not a real deploy."
    }
    if ($ReportCsv -and -not $DryRun) {
        throw "-ReportCsv needs -DryRun: the approval report is a preview, not a record of a real deploy."
    }
    if ($ApplyPlan) {
        if ($DryRun) {
            throw "-ApplyPlan cannot be combined with -DryRun: a plan is already a dry run's output, and applying it is the real deploy."
        }
        if ($SavePlan) {
            throw "-ApplyPlan cannot be combined with -SavePlan. Save a plan first, then apply it in a separate run."
        }
        if ($ReportCsv) {
            throw "-ApplyPlan cannot be combined with -ReportCsv. Generate the report from the -DryRun that made the plan."
        }
        if ($Restore -or $RestoreAll -or $Backup -or $BackupAll) {
            throw "-ApplyPlan cannot be combined with -Restore/-RestoreAll/-Backup/-BackupAll. Run them separately."
        }
        if ($OnFuzzyMatch) {
            throw "-OnFuzzyMatch has no effect with -ApplyPlan: duplicate-handling decisions are already recorded in the plan from when it was saved. Drop it."
        }
    }

    if ($Backup -or $BackupAll) {
        # Standalone backup: reads the tenant and writes local snapshot(s),
        # same as Update-WizardScript takes before an update - but on demand,
        # with no local -Path scan and nothing pushed to Intune.
        Connect-WizardGraph
        $targets = @(Resolve-WizardBackupTargets -NameOrId $Backup -All:$BackupAll)
        if ($targets.Count -eq 0) {
            Write-Host "No scripts found in this tenant to back up."
            return $script:WizardExitOk
        }

        if ($DryRun) {
            Write-Host "Would back up $($targets.Count) script(s):"
            foreach ($target in $targets) { Write-Host "  $($target.DisplayName) ($($target.Id))" }
            return $script:WizardExitOk
        }

        Write-Host "Backing up $($targets.Count) script(s) to $backupDir..."
        $backupFailures = @()
        foreach ($target in $targets) {
            try {
                Backup-WizardScript -Id $target.Id -BackupDir $backupDir | Out-Null
            } catch {
                # One script's failure says nothing about the next one's, so the
                # run keeps going and reports everything at the end - same as
                # the deploy loop and -RestoreAll below.
                $reason = Write-WizardFailure -Context "Backing up '$($target.DisplayName)' failed." -ErrorRecord $_
                $backupFailures += [pscustomobject]@{ Name = $target.DisplayName; Reason = $reason }
            }
        }

        Write-Host ""
        $backedUpCount = $targets.Count - $backupFailures.Count
        if ($backedUpCount -gt 0) { Push-WizardBackupsToRepo -BackupDir $backupDir }
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

    if ($Restore) {
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

        # Several backups of one script is the normal state of a backups/
        # folder, and restoring all of them just replays that script's history
        # in an order nobody chose - see Select-WizardRestoreSet.
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
                # the normal deploy loop below.
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

    Write-Host "Scanning $resolvedPath for scripts..."

    # The wizard's own files are never deployable scripts. Build the exclude
    # list from this script itself ($PSCommandPath) plus every .ps1 in lib/,
    # in case the wizard is sitting inside the same -Path being scanned.
    $ownFiles = @($PSCommandPath) + @(
        Get-ChildItem -LiteralPath (Join-Path $here 'lib') -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
            ForEach-Object { $_.FullName }
    )

    # -SourceRepo scans layer on top of -Path, not instead of it: each is
    # cloned fresh into .repo-sources/ and scanned the same way $resolvedPath
    # is, and the results are combined into one local script set before the
    # usual duplicate-name check runs across all of them together.
    $scanTargets = [System.Collections.Generic.List[object]]::new()
    $scanTargets.Add([pscustomobject]@{ Root = $resolvedPath; Label = $resolvedPath })
    if ($SourceRepo -and $SourceRepo.Count -gt 0) {
        $repoCacheRoot = Join-Path $resolvedPath '.repo-sources'
        foreach ($rawSpec in $SourceRepo) {
            $spec = Get-WizardRepoSourceSpec -Raw $rawSpec
            $scanRoot = Sync-WizardRepoSource -Spec $spec -CacheRoot $repoCacheRoot
            $scanTargets.Add([pscustomobject]@{ Root = $scanRoot; Label = $spec.Label })
        }
    }

    # @(...) around a function call forces the result to always be treated as
    # an array/list, even if Find-WizardScripts happens to return exactly one
    # item (PowerShell would otherwise "unwrap" a single result), so
    # .Count below always works correctly.
    $localScripts = @()
    foreach ($target in $scanTargets) {
        $found = @(Find-WizardScripts -RootPath $target.Root -ExcludePath $ownFiles -AllowTypeOverride:$AllowTypeOverride)
        Write-WizardDebug "Found $($found.Count) script(s) under $($target.Label)"
        $localScripts += $found
    }
    if ($localScripts.Count -eq 0) {
        Write-Host "No scripts found under user/ or device/ (or loose scripts with #type:), across $($scanTargets.Count) source(s)."
        return $script:WizardExitOk
    }

    # Group-Object bundles the scripts by DisplayName, so each bundle with more
    # than one item ($_.Count -gt 1) means two or more local files want the same
    # name. Two local scripts sharing a display name would each miss the other's
    # freshly created Intune object and silently produce duplicates. Fail before
    # touching the tenant rather than half-deploying.
    $dupeNames = $localScripts | Group-Object DisplayName | Where-Object { $_.Count -gt 1 }
    if ($dupeNames) {
        $detail = $dupeNames | ForEach-Object {
            "  '$($_.Name)' <- " + (($_.Group | ForEach-Object { $_.Path }) -join ', ')
        }
        $joined = $detail -join [Environment]::NewLine
        throw @"
Duplicate display names in the local script set:
$joined
Rename the files, or use #scriptname:"Some Name" to disambiguate them.
"@
    }

    # Connecting only now, after the local scan, means the extra directory-read
    # scope is requested only when a script actually names a group by display name.
    $additionalScopes = @()
    if (Test-WizardNeedsGroupScope -Scripts $localScripts) {
        $additionalScopes += $script:GroupReadScope
        Write-Host "One or more scripts target a group by name; requesting $script:GroupReadScope to resolve it."
    }
    Connect-WizardGraph -AdditionalScopes $additionalScopes

    # Resolves every #group:/#excludegroup: reference up front. A name that doesn't
    # resolve aborts here, before any script has been created or updated.
    Resolve-WizardGroupReferences -Scripts $localScripts

    Write-Host "Reading existing Intune scripts..."
    $existingScripts = [System.Collections.Generic.List[object]]::new()
    foreach ($s in (Get-WizardExistingScripts -CachePath $cachePath)) { $existingScripts.Add($s) }

    # A hashtable (the @{ key = value; ... } syntax) is PowerShell's dictionary
    # type: a lookup table of names to values, here counting each outcome type.
    $outcomes = @{ Created = 0; Updated = 0; UpToDate = 0; Skipped = 0; Planned = 0 }
    $failures = @()
    $aborted = $false

    if ($ApplyPlan) {
        # Replaying a saved plan: no fuzzy-match prompting, no fresh
        # duplicate detection - just the actions already decided when the
        # plan was saved, and only once they are proven to still apply to
        # exactly this local/tenant state.
        $applyPlanData = Read-WizardPlan -PlanFile $ApplyPlan
        Assert-WizardPlanSignatureMatches -Plan $applyPlanData -LocalScripts $localScripts -ExistingScripts $existingScripts
        Write-Host "Plan signature matches; applying $(@($applyPlanData['Actions']).Count) recorded action(s) from $ApplyPlan." -ForegroundColor Cyan

        $planByPath = @{}
        foreach ($entry in $applyPlanData['Actions']) { $planByPath[$entry['Path']] = $entry }

        foreach ($meta in $localScripts) {
            $entry = $planByPath[$meta.Path]
            if (-not $entry) {
                throw "Internal error: no plan entry found for '$($meta.Path)' even though the plan signature matched."
            }

            Write-Host ""
            Write-Host "== $($meta.DisplayName) [$($meta.Type)] ==" -ForegroundColor Cyan
            Write-Host "   assignment: $(Get-WizardAssignmentSummary -Meta $meta)" -ForegroundColor DarkGray

            try {
                $outcome = Invoke-WizardPlanAction -PlanEntry $entry -Meta $meta -Registry $existingScripts -BackupDir $backupDir
                $outcomes[$outcome]++
            } catch {
                $reason = Write-WizardFailure -Context "Applying planned action for '$($meta.DisplayName)' failed." -ErrorRecord $_
                $failures += [pscustomobject]@{
                    DisplayName = $meta.DisplayName
                    Path        = $meta.Path
                    Reason      = $reason
                }
                if ($StopOnError) {
                    $aborted = $true
                    break
                }
            }
        }
    } else {
        # Only a -DryRun -SavePlan/-ReportCsv run needs every decided action
        # recorded; a normal run leaves this $null, which Add-WizardPlanAction
        # (called from inside Invoke-WizardScriptDeployment) treats as a no-op.
        # Assigned via an explicit if/else (not "$x = if (...) {...} else {...}")
        # because an empty List[object] returned as an if-expression's value gets
        # enumerated onto the pipeline - zero items in, so the assignment would
        # capture $null instead of the (still-empty) list.
        $planActions = $null
        if ($SavePlan -or $ReportCsv) { $planActions = [System.Collections.Generic.List[object]]::new() }

        foreach ($meta in $localScripts) {
            Write-Host ""
            Write-Host "== $($meta.DisplayName) [$($meta.Type)] ==" -ForegroundColor Cyan
            Write-Host "   assignment: $(Get-WizardAssignmentSummary -Meta $meta)" -ForegroundColor DarkGray

            try {
                $outcome = Invoke-WizardScriptDeployment -Meta $meta -Registry $existingScripts `
                    -BackupDir $backupDir -DryRun:$DryRun -PlanActions $planActions
                $outcomes[$outcome]++
            } catch {
                # One script's failure says nothing about the next one's, so by
                # default the run keeps going and reports everything at the end.
                $reason = Write-WizardFailure -Context "Deploying '$($meta.DisplayName)' failed." -ErrorRecord $_
                $failures += [pscustomobject]@{
                    DisplayName = $meta.DisplayName
                    Path        = $meta.Path
                    Reason      = $reason
                }
                if ($StopOnError) {
                    $aborted = $true
                    break
                }
            }
        }

        if ($SavePlan -and -not $aborted -and $failures.Count -eq 0) {
            $signature = Get-WizardPlanSignature -LocalScripts $localScripts -ExistingScripts $existingScripts
            Save-WizardPlan -PlanFile $SavePlan -ResolvedPath $resolvedPath -Signature $signature -Actions $planActions
        }
        if ($ReportCsv -and -not $aborted -and $failures.Count -eq 0) {
            Export-WizardPlanCsv -Actions $planActions -LocalScripts $localScripts -CsvFile $ReportCsv
        }
    }

    Write-WizardRunSummary -Outcomes $outcomes -Failures $failures -BackupDir $backupDir -Aborted:$aborted
    if (-not $DryRun -and $outcomes['Updated'] -gt 0) { Push-WizardBackupsToRepo -BackupDir $backupDir }

    if ($aborted)              { return $script:WizardExitFatal }
    if ($failures.Count -gt 0) { return $script:WizardExitPartial }
    return $script:WizardExitOk
}

# --- Script entry point ---
# Everything above this line just defined functions; nothing has actually run
# yet. This is where execution really starts. Nothing below this point is
# allowed to leave the process without an exit code or without closing out the
# log: an unattended caller has only those two things to go on.
#
# Default to the "something went badly wrong before we even got going" exit
# code, so that if Invoke-WizardRun throws before assigning anything, we still
# exit with a sensible failure code instead of an unset value.
$exitCode = $script:WizardExitFatal
try {
    $exitCode = Invoke-WizardRun
} catch {
    # Catches anything Invoke-WizardRun didn't handle itself - logs it as a
    # fatal error and makes sure we still exit with the fatal code.
    Write-WizardFatal -ErrorRecord $_
    $exitCode = $script:WizardExitFatal
} finally {
    # 'finally' always runs, whether the try block succeeded or threw, so the
    # Graph session is never left open for a later, unrelated run to inherit,
    # and the log file is always closed out cleanly.
    Disconnect-WizardGraph
    Close-WizardLogging -ExitCode $exitCode
}

# 'exit' ends the PowerShell process and hands this number back to whatever
# invoked it (a terminal, a scheduled task, a CI pipeline) as the exit code.
exit $exitCode
