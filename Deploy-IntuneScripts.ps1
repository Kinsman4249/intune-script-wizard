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
    other parameters except -DebugLog are ignored in this mode.

.PARAMETER ListBackups
    List available backup files under -Path/backups and exit.

.PARAMETER DebugLog
    Trace Graph URLs, request bodies and match scores. Console writes to the
    host, File writes to -Path/logs/wizard-<timestamp>.log, Both does each.
    The build stamp is printed whenever this is on, and any fatal error is
    recorded there in full.
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
    [switch]$ListBackups,
    [ValidateSet('None', 'Console', 'File', 'Both')]
    [string]$DebugLog = 'None'
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

# Loading the library is the one thing that happens before the wizard's own
# error reporting exists, so it gets its own plain handler.
try {
    foreach ($libFile in @('Errors.ps1', 'Logging.ps1', 'Storage.ps1', 'Prereqs.ps1',
                           'Parsing.ps1', 'Matching.ps1', 'GraphOps.ps1', 'Backup.ps1')) {
        $libPath = Join-Path $here 'lib' $libFile
        if (-not (Test-Path -LiteralPath $libPath -PathType Leaf)) {
            throw "Required library file is missing: $libPath. Copy or clone the wizard folder in full, including lib/."
        }
        . $libPath
    }
} catch {
    [Console]::Error.WriteLine("intune-script-wizard: $($_.Exception.Message)")
    exit 1
}

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
    $choice = [string](Read-Host "[S]kip / [R]eplace existing / create [side-by-side]?")
    switch -Regex ($choice) {
        '^r'  { return 'Replace' }
        '^si' { return 'SideBySide' }
        default { return 'Skip' }
    }
}

function Register-DeployedScript {
    # Keeps the in-memory view of the tenant accurate within a single run, so a
    # script created or updated early on is visible to the matching logic for
    # every later script. The list is passed in rather than reached for through
    # the scope chain, so the dependency is visible at the call site.
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Registry,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)]$Meta,
        [Parameter(Mandatory)][string]$ContentHash
    )

    $existing = $Registry | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if ($existing) {
        $existing.DisplayName = $Meta.DisplayName
        $existing.Description = $Meta.Description
        $existing.ContentHash = $ContentHash
    } else {
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

function Invoke-WizardScriptDeployment {
    # Decides what one local script needs and does it, returning an outcome for
    # the run summary. Everything here used to live in the deploy loop with
    # 'continue nextScript' at each exit; as a function each of those becomes a
    # plain 'return', which removes the labelled-continue-inside-switch trap the
    # old loop had to carry a warning about, and makes the whole body wrappable
    # in a single try/catch by the caller.
    param(
        [Parameter(Mandatory)]$Meta,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Registry,
        [Parameter(Mandatory)][string]$BackupDir,
        [switch]$DryRun
    )

    $localHash = Get-WizardFileHash -Path $Meta.Path
    Write-WizardDebug "Local hash $localHash for $($Meta.Path)"
    $contentMatch = $Registry | Where-Object { $_.ContentHash -eq $localHash } | Select-Object -First 1

    if ($contentMatch -and $contentMatch.DisplayName -eq $Meta.DisplayName) {
        Write-Host "  Already up to date (content and name match existing script $($contentMatch.Id))."
        return 'UpToDate'
    }

    if ($contentMatch) {
        Write-Host "  Identical content already exists in Intune as '$($contentMatch.DisplayName)' ($($contentMatch.Id))." -ForegroundColor Yellow
        $action = Resolve-FuzzyAction -Local $Meta -Existing $contentMatch -Similarity 1.0
        switch ($action) {
            'Skip' {
                Write-Host "  Skipped."
                return 'Skipped'
            }
            'Replace' {
                if ($DryRun) {
                    Write-Host "  [DryRun] Would rename/update $($contentMatch.Id) to match local metadata."
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

    $nameMatch = $Registry | Where-Object { $_.DisplayName -eq $Meta.DisplayName } | Select-Object -First 1
    if ($nameMatch) {
        if ($DryRun) {
            Write-Host "  [DryRun] Would back up and update existing script $($nameMatch.Id)."
            return 'Planned'
        }
        Update-WizardScript -Meta $Meta -ExistingId $nameMatch.Id -BackupDir $BackupDir
        Register-DeployedScript -Registry $Registry -Id $nameMatch.Id -Meta $Meta -ContentHash $localHash
        return 'Updated'
    }

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

    if ($best -and $bestScore -ge $script:FuzzyMatchThreshold) {
        $action = Resolve-FuzzyAction -Local $Meta -Existing $best -Similarity $bestScore
        switch ($action) {
            'Skip' {
                Write-Host "  Skipped."
                return 'Skipped'
            }
            'Replace' {
                if ($DryRun) {
                    Write-Host "  [DryRun] Would back up and replace $($best.Id) with local script."
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

    if ($DryRun) {
        Write-Host "  [DryRun] Would create new script '$($Meta.DisplayName)'."
        return 'Planned'
    }
    $created = New-WizardScript -Meta $Meta
    Register-DeployedScript -Registry $Registry -Id $created.Id -Meta $Meta -ContentHash $localHash
    return 'Created'
}

function Write-WizardRunSummary {
    param(
        [Parameter(Mandatory)][hashtable]$Outcomes,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Failures,
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
}

function Invoke-WizardRun {
    # The whole run, returning the process exit code. Written as a function so
    # every early exit is a 'return' the outer handler can see, rather than an
    # 'exit' that jumps out past the logging teardown.

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "-Path '$Path' does not exist or is not a folder."
    }
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

    Test-WizardPSVersion
    Install-WizardModules -AcceptInstall:$AcceptModuleInstall
    Import-WizardModules

    if ($Restore) {
        # -DryRun cannot be honoured here - a restore is a single write with
        # nothing to preview - and silently ignoring it would mutate the tenant
        # for someone who explicitly asked for no changes.
        if ($DryRun) {
            throw "-DryRun cannot be combined with -Restore: a restore has nothing to preview, and running it anyway would change the tenant. Drop one of the two."
        }
        Connect-WizardGraph
        Restore-WizardBackup -BackupFile $Restore | Out-Null
        return $script:WizardExitOk
    }

    Write-Host "Scanning $resolvedPath for scripts..."

    # The wizard's own files are never deployable scripts.
    $ownFiles = @($PSCommandPath) + @(
        Get-ChildItem -LiteralPath (Join-Path $here 'lib') -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
            ForEach-Object { $_.FullName }
    )

    $localScripts = @(Find-WizardScripts -RootPath $resolvedPath -ExcludePath $ownFiles -AllowTypeOverride:$AllowTypeOverride)
    if ($localScripts.Count -eq 0) {
        Write-Host "No scripts found under user/ or device/ (or loose scripts with #type:)."
        return $script:WizardExitOk
    }

    # Two local scripts sharing a display name would each miss the other's freshly
    # created Intune object and silently produce duplicates. Fail before touching
    # the tenant rather than half-deploying.
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

    $outcomes = @{ Created = 0; Updated = 0; UpToDate = 0; Skipped = 0; Planned = 0 }
    $failures = @()
    $aborted = $false

    foreach ($meta in $localScripts) {
        Write-Host ""
        Write-Host "== $($meta.DisplayName) [$($meta.Type)] ==" -ForegroundColor Cyan
        Write-Host "   assignment: $(Get-WizardAssignmentSummary -Meta $meta)" -ForegroundColor DarkGray

        try {
            $outcome = Invoke-WizardScriptDeployment -Meta $meta -Registry $existingScripts `
                -BackupDir $backupDir -DryRun:$DryRun
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

    Write-WizardRunSummary -Outcomes $outcomes -Failures $failures -Aborted:$aborted

    if ($aborted)              { return $script:WizardExitFatal }
    if ($failures.Count -gt 0) { return $script:WizardExitPartial }
    return $script:WizardExitOk
}

# Nothing below this point is allowed to leave the process without an exit code
# or without closing out the log: an unattended caller has only those two things
# to go on.
$exitCode = $script:WizardExitFatal
try {
    $exitCode = Invoke-WizardRun
} catch {
    Write-WizardFatal -ErrorRecord $_
    $exitCode = $script:WizardExitFatal
} finally {
    Close-WizardLogging -ExitCode $exitCode
}

exit $exitCode
