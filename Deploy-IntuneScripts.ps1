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
    would take before an update, into -Path/backups, and also exports a .ps1
    template of it into -Path/templates unless -NoTemplates is given. Combine
    with -DryRun to see which script would be backed up without writing the
    file.

.PARAMETER BackupAll
    Back up every script currently in the tenant, one file each under
    -Path/backups (and, unless -NoTemplates is given, one template each under
    -Path/templates - see -NoTemplates). Takes no value; -Backup is ignored if
    also passed.

.PARAMETER NoTemplates
    Skip exporting .ps1 templates during -Backup/-BackupAll; only the JSON
    backups are written. Export is on by default because it's part of what
    -Backup/-BackupAll do, not a separate opt-in - use this switch if you only
    want the JSON safety net and would rather not pay for the group lookups
    (which optionally request GroupMember.Read.All) or the extra consent
    prompt that comes with them. Only valid with -Backup/-BackupAll.

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
    [switch]$NoTemplates,
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
# errors, logging, parsing, the per-script deploy decisions, etc). PowerShell's
# dot-source operator ". <path>" runs another file as if pasted in here, which
# is how all the Get-Wizard*/Write-Wizard*/etc functions used below become
# available. Loading the library happens before the wizard's own error
# reporting exists, so it gets its own plain try/catch.
try {
    foreach ($libFile in @('Errors.ps1', 'Logging.ps1', 'Storage.ps1', 'Prereqs.ps1',
                           'Parsing.ps1', 'Matching.ps1', 'GraphCore.ps1', 'GraphAuth.ps1',
                           'Assignments.ps1', 'GraphOps.ps1', 'Backup.ps1', 'Restore.ps1',
                           'TemplateHeader.ps1', 'Template.ps1', 'RepoBackup.ps1',
                           'RepoBackupSubpath.ps1', 'RepoSource.ps1', 'Plan.ps1',
                           'Deploy.ps1', 'Telemetry.ps1')) {
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

# The whole run, returning the process exit code. Written as a function so
# every early exit is a 'return' the outer handler can see, not an 'exit' that
# jumps past the logging teardown. Kept in this file rather than lib/Deploy.ps1
# because it reads $PSCommandPath (only resolvable to this script from a
# function defined here) to exclude the wizard's own file from the scan.
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
    $templateDir = Join-Path $resolvedPath 'templates'
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
    if ($NoTemplates -and -not ($Backup -or $BackupAll)) {
        throw "-NoTemplates only applies to -Backup/-BackupAll. Add one of those, or drop the switch."
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
        return (Invoke-WizardBackupMode -ResolvedPath $resolvedPath -BackupDir $backupDir `
            -TemplateDir $templateDir -Backup $Backup -BackupAll:$BackupAll `
            -NoTemplates:$NoTemplates -DryRun:$DryRun)
    }

    if ($Restore) {
        return (Invoke-WizardRestoreMode -Restore $Restore -RestoreAll:$RestoreAll `
            -SkipAssignments:$SkipAssignments -DryRun:$DryRun)
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
# log: an unattended caller has only those two things to go on. Default to the
# "something went badly wrong before we even got going" exit
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
