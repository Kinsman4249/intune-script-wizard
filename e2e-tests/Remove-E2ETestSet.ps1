#Requires -Version 7.0
<#
.SYNOPSIS
    Deletes the E2E test scripts New-E2ETestSet.ps1 / Deploy-IntuneScripts.ps1
    created in a tenant, by matching Intune display name prefix.

.DESCRIPTION
    This is the closest thing to "revert to the state before the E2E run" that
    makes sense here: every script the E2E kit creates is a brand-new
    deviceManagementScript object, so there is no prior version of it to
    restore - undoing its creation IS reverting to the pre-test state, and
    that means deleting it.

    The one case that would NOT be a clean revert is if an E2E-prefixed
    display name collided with a script that already existed before you ran
    the E2E kit (so Deploy-IntuneScripts.ps1 updated it instead of creating
    it). That's why this script checks every generated-root backups/ folder
    first: if a matching display name has a backup, deleting it would destroy
    the pre-existing script for good, so that one is left alone and flagged -
    restore it with Deploy-IntuneScripts.ps1 -Restore <file> first, then
    re-run this script to pick up whatever's left.

    Dry-run by default: lists what it found and does nothing else. Pass
    -Confirm to actually delete.

.PARAMETER MetadataPath
    Path to the e2e-metadata.json used to generate the test set (read for
    answers.runPrefix and the confirmDevTenant gate). Defaults to the file
    next to this script.

.PARAMETER GeneratedRoot
    The generated/ folder produced by New-E2ETestSet.ps1, used to find each
    root's backups/ subfolder for the pre-existing-script check above.
    Defaults to the folder next to this script.

.PARAMETER Confirm
    Actually delete matches. Without this, nothing is removed.

.PARAMETER IncludeFlagged
    Also delete matches that have a backup on file (see DESCRIPTION) - only
    use this once you've confirmed you don't need that backup restored.

.PARAMETER AcceptModuleInstall
    Install missing required Graph modules without prompting.
#>
[CmdletBinding()]
param(
    [string]$MetadataPath = (Join-Path $PSScriptRoot 'e2e-metadata.json'),
    [string]$GeneratedRoot = (Join-Path $PSScriptRoot 'generated'),
    [switch]$Confirm,
    [switch]$IncludeFlagged,
    [switch]$AcceptModuleInstall
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$repo = Split-Path -Parent $here
# GraphOps depends on the error formatter, the atomic JSON writer and the
# hashing helper, so all four are loaded even though this script only calls into
# GraphOps directly.
. (Join-Path $repo 'lib/Errors.ps1')
. (Join-Path $repo 'lib/Logging.ps1')
. (Join-Path $repo 'lib/Storage.ps1')
. (Join-Path $repo 'lib/Matching.ps1')
. (Join-Path $repo 'lib/Prereqs.ps1')
. (Join-Path $repo 'lib/GraphOps.ps1')

if (-not (Test-Path -LiteralPath $MetadataPath)) {
    throw "'$MetadataPath' not found. Run New-E2ETestSet.ps1 first (it creates and explains the metadata file)."
}
try {
    $rawMetadata = Get-Content -LiteralPath $MetadataPath -Raw
    $metadata = Repair-WizardJsonBackslashes -Json $rawMetadata | ConvertFrom-Json -AsHashtable
} catch {
    throw "'$MetadataPath' is not valid JSON: $($_.Exception.Message)"
}
if (-not $metadata['answers']['confirmDevTenant']) {
    throw "'$MetadataPath': answers.confirmDevTenant is false. This script deletes real tenant objects - " +
          "set confirmDevTenant to true (same gate New-E2ETestSet.ps1 uses) once you've confirmed you're pointed at a dev tenant."
}
$runPrefix = [string]$metadata['answers']['runPrefix']
if ([string]::IsNullOrWhiteSpace($runPrefix)) { $runPrefix = 'E2E' }
$namePrefix = "$runPrefix`:"

Initialize-WizardLogging -Mode 'None' -LogRoot $here

Test-WizardPSVersion
Install-WizardModules -AcceptInstall:$AcceptModuleInstall
Import-WizardModules
Connect-WizardGraph

# --------------------------------------------------------------------------
# Anything with a backup on file was an UPDATE, not a CREATE - meaning a
# script with this exact display name already existed before the E2E run.
# Collect those display names so matches can be flagged instead of deleted.
# --------------------------------------------------------------------------
$backedUpNames = [System.Collections.Generic.HashSet[string]]::new()
if (Test-Path -LiteralPath $GeneratedRoot) {
    Get-ChildItem -LiteralPath $GeneratedRoot -Filter 'backups' -Recurse -Directory -ErrorAction SilentlyContinue |
        ForEach-Object {
            Get-ChildItem -LiteralPath $_.FullName -Filter '*.json' -File -ErrorAction SilentlyContinue |
                ForEach-Object {
                    try {
                        $b = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
                        if ($b.DisplayName) { [void]$backedUpNames.Add([string]$b.DisplayName) }
                    } catch {
                        Write-Warning "Could not read backup '$($_.FullName)': $_"
                    }
                }
        }
}

Write-Host "Looking for scripts with display names starting '$namePrefix'..."
$all = @(Get-MgBetaDeviceManagementScript -All -Property id, displayName)
$matches = @($all | Where-Object { $_.DisplayName -and $_.DisplayName.StartsWith($namePrefix) })

if ($matches.Count -eq 0) {
    Write-Host "No matching scripts found. Nothing to do."
    exit 0
}

$toDelete = [System.Collections.Generic.List[object]]::new()
$toSkip   = [System.Collections.Generic.List[object]]::new()
foreach ($m in $matches) {
    if ($backedUpNames.Contains($m.DisplayName) -and -not $IncludeFlagged) {
        $toSkip.Add($m)
    } else {
        $toDelete.Add($m)
    }
}

Write-Host ""
Write-Host "Found $($matches.Count) script(s) matching '$namePrefix':"
foreach ($m in $toDelete) { Write-Host "  [delete]  $($m.Id)  $($m.DisplayName)" -ForegroundColor $(if ($Confirm) { 'Red' } else { 'DarkGray' }) }
foreach ($m in $toSkip)   { Write-Host "  [SKIP - has a backup, may pre-date the E2E run]  $($m.Id)  $($m.DisplayName)" -ForegroundColor Yellow }

if ($toSkip.Count -gt 0 -and -not $IncludeFlagged) {
    Write-Host ""
    Write-Host "$($toSkip.Count) script(s) skipped because a backup exists for that display name - deleting them" -ForegroundColor Yellow
    Write-Host "could destroy a script that existed before the E2E run. Restore it first with:" -ForegroundColor Yellow
    Write-Host "  Deploy-IntuneScripts.ps1 -Restore <backup file>" -ForegroundColor Yellow
    Write-Host "or pass -IncludeFlagged here if you're sure it's safe to delete anyway." -ForegroundColor Yellow
}

if (-not $Confirm) {
    Write-Host ""
    Write-Host "DRY RUN - nothing deleted. Re-run with -Confirm to delete the $($toDelete.Count) script(s) listed above." -ForegroundColor Cyan
    exit 0
}

Write-Host ""
# One failed delete says nothing about the next: carry on so a single stuck
# object cannot leave the rest of a test set behind in the tenant, then report
# the failures and exit non-zero so a wrapper script notices.
$deleted = 0
$failed = @()
foreach ($m in $toDelete) {
    Write-Host "Deleting $($m.Id) '$($m.DisplayName)'..."
    try {
        Remove-WizardScript -Id $m.Id
        $deleted++
    } catch {
        $reason = Get-WizardErrorSummary -ErrorRecord $_
        Write-Host "  ERROR: $reason" -ForegroundColor Red
        $failed += [pscustomobject]@{ Id = $m.Id; DisplayName = $m.DisplayName; Reason = $reason }
    }
}

Write-Host ""
Write-Host "Deleted $deleted script(s)." -ForegroundColor Green
if ($toSkip.Count -gt 0) {
    Write-Host "$($toSkip.Count) script(s) left in place (see SKIP list above)." -ForegroundColor Yellow
}
if ($failed.Count -gt 0) {
    Write-Host "$($failed.Count) script(s) could not be deleted:" -ForegroundColor Red
    foreach ($f in $failed) { Write-Host "  $($f.Id)  $($f.DisplayName): $($f.Reason)" -ForegroundColor Red }
    exit 1
}
