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

.PARAMETER Path
    Root folder containing user/ and/or device/ subfolders. Defaults to the
    current directory.

.PARAMETER OnFuzzyMatch
    How to resolve a near-duplicate (not exact) name/description match against
    an existing Intune script, without prompting: Skip, Replace, or SideBySide.
    If omitted, you're prompted interactively for each fuzzy match.

.PARAMETER AcceptModuleInstall
    Install missing required Graph modules without prompting.

.PARAMETER DryRun
    Print what would happen without making any Graph calls that change data.

.PARAMETER AllowTypeOverride
    Let a conflicting #type: comment win over its user/device folder for every
    script in this run, instead of adding #typeoverride:yes to each one.

.PARAMETER Restore
    Path to a JSON backup file (see backups/) to restore in one command. All
    other parameters except -DebugLog are ignored in this mode.

.PARAMETER ListBackups
    List available backup files under -Path/backups and exit.

.PARAMETER DebugLog
    Trace Graph URLs, request bodies and match scores. Console writes to the
    host, File writes to -Path/logs/wizard-<timestamp>.log, Both does each.
    The build stamp is printed whenever this is on.
#>
[CmdletBinding()]
param(
    [string]$Path = (Get-Location).Path,
    [ValidateSet('Skip', 'Replace', 'SideBySide')]
    [string]$OnFuzzyMatch,
    [switch]$AcceptModuleInstall,
    [switch]$DryRun,
    [switch]$AllowTypeOverride,
    [string]$Restore,
    [switch]$ListBackups,
    [ValidateSet('None', 'Console', 'File', 'Both')]
    [string]$DebugLog = 'None'
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
. (Join-Path $here 'lib/Logging.ps1')
. (Join-Path $here 'lib/Prereqs.ps1')
. (Join-Path $here 'lib/Parsing.ps1')
. (Join-Path $here 'lib/Matching.ps1')
. (Join-Path $here 'lib/GraphOps.ps1')
. (Join-Path $here 'lib/Backup.ps1')

if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    throw "-Path '$Path' does not exist or is not a folder."
}
$Path = (Resolve-Path -LiteralPath $Path).Path

Initialize-WizardLogging -Mode $DebugLog -LogRoot $Path
Write-WizardDebug "Path=$Path DryRun=$DryRun OnFuzzyMatch=$OnFuzzyMatch AllowTypeOverride=$AllowTypeOverride"

$backupDir = Join-Path $Path 'backups'
$cachePath = Join-Path $Path '.intune-script-cache.json'

if ($ListBackups) {
    if (-not (Test-Path -LiteralPath $backupDir)) {
        Write-Host "No backups directory yet at $backupDir"
        exit 0
    }
    Get-ChildItem -LiteralPath $backupDir -Filter '*.json' | Sort-Object LastWriteTime -Descending |
        Format-Table Name, LastWriteTime -AutoSize
    exit 0
}

Test-WizardPSVersion
Install-WizardModules -AcceptInstall:$AcceptModuleInstall
Import-WizardModules

if ($Restore) {
    Connect-WizardGraph
    Restore-WizardBackup -BackupFile $Restore
    exit 0
}

function Resolve-FuzzyAction {
    param(
        [Parameter(Mandatory)]$Local,
        [Parameter(Mandatory)]$Existing,
        [Parameter(Mandatory)][double]$Similarity
    )

    if ($OnFuzzyMatch) { return $OnFuzzyMatch }

    Write-Host ""
    Write-Host "Possible duplicate (similarity $([Math]::Round($Similarity * 100))%):" -ForegroundColor Yellow
    Write-Host "  Local:    $($Local.DisplayName)"
    Write-Host "  Existing: $($Existing.DisplayName)"
    $choice = Read-Host "[S]kip / [R]eplace existing / create [side-by-side]?"
    switch -Regex ($choice) {
        '^r'  { return 'Replace' }
        '^si' { return 'SideBySide' }
        default { return 'Skip' }
    }
}

Write-Host "Scanning $Path for scripts..."

# The wizard's own files are never deployable scripts.
$ownFiles = @($PSCommandPath) + @(
    Get-ChildItem -LiteralPath (Join-Path $here 'lib') -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
        ForEach-Object { $_.FullName }
)

$localScripts = @(Find-WizardScripts -RootPath $Path -ExcludePath $ownFiles -AllowTypeOverride:$AllowTypeOverride)
if ($localScripts.Count -eq 0) {
    Write-Host "No scripts found under user/ or device/ (or loose scripts with #type:)."
    exit 0
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

# Keeps $existingScripts accurate within a single run, so a script created or
# updated early on is visible to the matching logic for every later script.
function Register-DeployedScript {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)]$Meta,
        [Parameter(Mandatory)][string]$ContentHash
    )

    $existing = $existingScripts | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if ($existing) {
        $existing.DisplayName = $Meta.DisplayName
        $existing.Description = $Meta.Description
        $existing.ContentHash = $ContentHash
    } else {
        $existingScripts.Add([pscustomobject]@{
            Id                   = $Id
            DisplayName          = $Meta.DisplayName
            Description          = $Meta.Description
            LastModifiedDateTime = (Get-Date).ToString('o')
            ContentHash          = $ContentHash
        })
    }
    Write-WizardDebug "In-run state updated for $Id ($($Meta.DisplayName))"
}

# NOTE: the loop is labelled because 'continue' inside a switch exits the switch
# only - it does NOT advance the enclosing foreach. Without 'continue nextScript'
# a Skip decision would fall straight through into the code below it.
:nextScript foreach ($meta in $localScripts) {
    Write-Host ""
    Write-Host "== $($meta.DisplayName) [$($meta.Type)] ==" -ForegroundColor Cyan
    Write-Host "   assignment: $(Get-WizardAssignmentSummary -Meta $meta)" -ForegroundColor DarkGray

    $localHash = Get-WizardFileHash -Path $meta.Path
    Write-WizardDebug "Local hash $localHash for $($meta.Path)"
    $contentMatch = $existingScripts | Where-Object { $_.ContentHash -eq $localHash } | Select-Object -First 1

    if ($contentMatch -and $contentMatch.DisplayName -eq $meta.DisplayName) {
        Write-Host "  Already up to date (content and name match existing script $($contentMatch.Id))."
        continue nextScript
    }

    if ($contentMatch) {
        Write-Host "  Identical content already exists in Intune as '$($contentMatch.DisplayName)' ($($contentMatch.Id))." -ForegroundColor Yellow
        $action = Resolve-FuzzyAction -Local $meta -Existing $contentMatch -Similarity 1.0
        switch ($action) {
            'Skip' {
                Write-Host "  Skipped."
                continue nextScript
            }
            'Replace' {
                if ($DryRun) {
                    Write-Host "  [DryRun] Would rename/update $($contentMatch.Id) to match local metadata."
                    continue nextScript
                }
                Update-WizardScript -Meta $meta -ExistingId $contentMatch.Id -BackupDir $backupDir
                Register-DeployedScript -Id $contentMatch.Id -Meta $meta -ContentHash $localHash
                continue nextScript
            }
            'SideBySide' { } # fall through to normal create below
        }
    }

    $nameMatch = $existingScripts | Where-Object { $_.DisplayName -eq $meta.DisplayName } | Select-Object -First 1
    if ($nameMatch) {
        if ($DryRun) {
            Write-Host "  [DryRun] Would back up and update existing script $($nameMatch.Id)."
            continue nextScript
        }
        Update-WizardScript -Meta $meta -ExistingId $nameMatch.Id -BackupDir $backupDir
        Register-DeployedScript -Id $nameMatch.Id -Meta $meta -ContentHash $localHash
        continue nextScript
    }

    $best = $null
    $bestScore = 0.0
    foreach ($ex in $existingScripts) {
        $score = Get-WizardMatchScore `
            -LocalName $meta.DisplayName -LocalDescription $meta.Description `
            -ExistingName $ex.DisplayName -ExistingDescription ([string]$ex.Description)
        if ($score -gt $bestScore) { $bestScore = $score; $best = $ex }
    }
    if ($best) {
        Write-WizardDebug "Best fuzzy candidate '$($best.DisplayName)' scored $([Math]::Round($bestScore, 3))"
    }

    if ($best -and $bestScore -ge $script:FuzzyMatchThreshold) {
        $action = Resolve-FuzzyAction -Local $meta -Existing $best -Similarity $bestScore
        switch ($action) {
            'Skip' {
                Write-Host "  Skipped."
                continue nextScript
            }
            'Replace' {
                if ($DryRun) {
                    Write-Host "  [DryRun] Would back up and replace $($best.Id) with local script."
                    continue nextScript
                }
                Update-WizardScript -Meta $meta -ExistingId $best.Id -BackupDir $backupDir
                Register-DeployedScript -Id $best.Id -Meta $meta -ContentHash $localHash
                continue nextScript
            }
            'SideBySide' { } # fall through
        }
    }

    if ($DryRun) {
        Write-Host "  [DryRun] Would create new script '$($meta.DisplayName)'."
        continue nextScript
    }
    $created = New-WizardScript -Meta $meta
    Register-DeployedScript -Id $created.Id -Meta $meta -ContentHash $localHash
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
