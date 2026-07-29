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
                                       a user/ or device/ folder
      #noassignments / #noassigments - do not assign this script to anyone
      #scriptcheck:yes              - enforce script signature check (default: off)
      #host:64                      - run in 64-bit PowerShell host (default: 32-bit)

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

.PARAMETER Restore
    Path to a JSON backup file (see backups/) to restore in one command. All
    other parameters are ignored in this mode.

.PARAMETER ListBackups
    List available backup files under -Path/backups and exit.
#>
[CmdletBinding()]
param(
    [string]$Path = (Get-Location).Path,
    [ValidateSet('Skip', 'Replace', 'SideBySide')]
    [string]$OnFuzzyMatch,
    [switch]$AcceptModuleInstall,
    [switch]$DryRun,
    [string]$Restore,
    [switch]$ListBackups
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
. (Join-Path $here 'lib/Prereqs.ps1')
. (Join-Path $here 'lib/Parsing.ps1')
. (Join-Path $here 'lib/Matching.ps1')
. (Join-Path $here 'lib/GraphOps.ps1')

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
Connect-WizardGraph

if ($Restore) {
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
    Write-Host "Possible duplicate (name similarity $([Math]::Round($Similarity * 100))%):" -ForegroundColor Yellow
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
$localScripts = Find-WizardScripts -RootPath $Path
if ($localScripts.Count -eq 0) {
    Write-Host "No scripts found under user/ or device/ (or loose scripts with #type:)."
    exit 0
}

Write-Host "Reading existing Intune scripts..."
$existingScripts = Get-WizardExistingScripts -CachePath $cachePath

foreach ($meta in $localScripts) {
    Write-Host ""
    Write-Host "== $($meta.DisplayName) [$($meta.Type)] ==" -ForegroundColor Cyan

    $localHash = Get-WizardFileHash -Path $meta.Path
    $contentMatch = $existingScripts | Where-Object { $_.ContentHash -eq $localHash } | Select-Object -First 1

    if ($contentMatch -and $contentMatch.DisplayName -eq $meta.DisplayName) {
        Write-Host "  Already up to date (content and name match existing script $($contentMatch.Id))."
        continue
    }

    if ($contentMatch) {
        Write-Host "  Identical content already exists in Intune as '$($contentMatch.DisplayName)' ($($contentMatch.Id))." -ForegroundColor Yellow
        $action = Resolve-FuzzyAction -Local $meta -Existing $contentMatch -Similarity 1.0
        switch ($action) {
            'Skip' { Write-Host "  Skipped."; continue }
            'Replace' {
                if ($DryRun) { Write-Host "  [DryRun] Would rename/update $($contentMatch.Id) to match local metadata."; continue }
                Update-WizardScript -Meta $meta -ExistingId $contentMatch.Id -BackupDir $backupDir
                continue
            }
            'SideBySide' { } # fall through to normal create below
        }
    }

    $nameMatch = $existingScripts | Where-Object { $_.DisplayName -eq $meta.DisplayName } | Select-Object -First 1
    if ($nameMatch) {
        if ($DryRun) { Write-Host "  [DryRun] Would back up and update existing script $($nameMatch.Id)."; continue }
        Update-WizardScript -Meta $meta -ExistingId $nameMatch.Id -BackupDir $backupDir
        continue
    }

    $best = $null
    $bestScore = 0.0
    foreach ($ex in $existingScripts) {
        $score = Get-StringSimilarity -A $meta.DisplayName -B $ex.DisplayName
        if ($score -gt $bestScore) { $bestScore = $score; $best = $ex }
    }

    if ($best -and $bestScore -ge $script:FuzzyMatchThreshold) {
        $action = Resolve-FuzzyAction -Local $meta -Existing $best -Similarity $bestScore
        switch ($action) {
            'Skip' { Write-Host "  Skipped."; continue }
            'Replace' {
                if ($DryRun) { Write-Host "  [DryRun] Would back up and replace $($best.Id) with local script."; continue }
                Update-WizardScript -Meta $meta -ExistingId $best.Id -BackupDir $backupDir
                continue
            }
            'SideBySide' { } # fall through
        }
    }

    if ($DryRun) { Write-Host "  [DryRun] Would create new script '$($meta.DisplayName)'."; continue }
    New-WizardScript -Meta $meta | Out-Null
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
