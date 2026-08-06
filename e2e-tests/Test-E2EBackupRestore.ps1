#Requires -Version 7.0
<#
.SYNOPSIS
    Proves against a real dev tenant that a backup taken during an update can
    actually be restored, and that the backup file on disk is well-formed.

.DESCRIPTION
    The rest of the E2E kit only ever creates new scripts, so it never exercises
    the update -> backup -> restore path. That path is the one where a broken
    backup stays invisible until the day someone needs it: the wizard reports a
    successful update, writes a file to backups/, and only a restore attempt
    (usually during an incident) reveals whether that file was usable.

    This script closes that gap end to end, against the tenant, unattended:

      1. Deploys a throwaway script (v1 content) - a create.
      2. Rewrites it (v2 content) and deploys again - an update, which forces a
         backup of v1 to be written.
      3. Checks the backup FILE itself: ScriptContent must be base64 *text* that
         decodes back to v1 byte for byte. This is the specific regression guard
         for the SDK returning scriptContent as a byte[]: writing that through
         unconverted produces a JSON array of numbers, which still "looks like"
         a successful backup but cannot be restored.
      4. Restores that backup and confirms the tenant really holds v1 again, and
         that the used backup was filed away under backup-restored/.

    Everything it creates is named with the metadata file's runPrefix, so
    Remove-E2ETestSet.ps1 cleans it up like any other E2E artifact. It also
    deletes its own script on the way out unless -KeepArtifacts is passed.

    Deploy-IntuneScripts.ps1 is invoked with stdin redirected so those child runs
    are non-interactive and skip the per-run tenant confirmation prompt. This
    script asks for that confirmation once, up front, on its own connection.

.PARAMETER MetadataPath
    Path to e2e-metadata.json (read for answers.confirmDevTenant and
    answers.runPrefix). Defaults to the file next to this script.

.PARAMETER WorkPath
    Scratch -Path root for the generated script and its backups/ folder.
    Defaults to e2e-tests/generated-backup-restore. Rebuilt on every run.

.PARAMETER KeepArtifacts
    Leave the test script in the tenant and the scratch folder on disk, for
    poking at a failure by hand. Without this both are cleaned up.

.PARAMETER AcceptModuleInstall
    Install missing required Graph modules without prompting.
#>
[CmdletBinding()]
param(
    [string]$MetadataPath = (Join-Path $PSScriptRoot 'e2e-metadata.json'),
    [string]$WorkPath = (Join-Path $PSScriptRoot 'generated-backup-restore'),
    [switch]$KeepArtifacts,
    [switch]$AcceptModuleInstall
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$repo = Split-Path -Parent $here

. (Join-Path $repo 'lib/Errors.ps1')
. (Join-Path $repo 'lib/Logging.ps1')
. (Join-Path $repo 'lib/Storage.ps1')
. (Join-Path $repo 'lib/Matching.ps1')
. (Join-Path $repo 'lib/Prereqs.ps1')
. (Join-Path $repo 'lib/GraphCore.ps1')
. (Join-Path $repo 'lib/GraphAuth.ps1')
. (Join-Path $repo 'lib/Assignments.ps1')
. (Join-Path $repo 'lib/GraphOps.ps1')

# --------------------------------------------------------------------------
# Metadata gate - same confirmDevTenant contract the rest of the kit uses.
# --------------------------------------------------------------------------
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
    throw "'$MetadataPath': answers.confirmDevTenant is false. This script creates, updates and deletes real tenant objects - set confirmDevTenant to true once you've confirmed you're pointed at a dev tenant."
}
$runPrefix = [string]$metadata['answers']['runPrefix']
if ([string]::IsNullOrWhiteSpace($runPrefix)) { $runPrefix = 'ZZZ-E2E-TEST-DELETE-ME' }

$displayName = "$runPrefix Backup-Restore"

# --------------------------------------------------------------------------
# Tiny check harness, same shape as the offline suite: record every assertion
# and keep going, so one failure still reports what else was wrong.
# --------------------------------------------------------------------------
$script:Passed = 0
$script:Failed = 0
function Check {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) {
        Write-Host "PASS  $Name" -ForegroundColor Green
        $script:Passed++
    } else {
        Write-Host "FAIL  $Name" -ForegroundColor Red
        if ($Detail) { Write-Host "      $Detail" -ForegroundColor Red }
        $script:Failed++
    }
}

$deploy = Join-Path $repo 'Deploy-IntuneScripts.ps1'
function Invoke-Deploy {
    # Runs the real wizard as a child process. Piping '' into it redirects the
    # child's stdin, which makes Test-WizardInteractive false there, so the
    # child skips the tenant-confirmation prompt this script already answered.
    param([string[]]$WizardArgs)
    # *>&1, not 2>&1: a push failure in Push-WizardBackupsToRepo
    # (lib/RepoBackup.ps1) is deliberately reported via Write-Warning, not a
    # thrown error - that's stream 3, which 2>&1 does not merge. Missing it
    # here means the run looks like a clean success right up until the
    # separate remote-verification step, with no clue why.
    $output = '' | & pwsh -NoProfile -File $deploy @WizardArgs *>&1 | Out-String
    return [pscustomobject]@{ Output = $output; ExitCode = $LASTEXITCODE }
}

function Get-TenantScriptText {
    # Reads a script's content back out of the tenant as text, via the same
    # normalisation the wizard itself uses.
    param([Parameter(Mandatory)][string]$Id)
    $full = Get-MgBetaDeviceManagementScript -DeviceManagementScriptId $Id -Property scriptContent
    $bytes = Get-WizardScriptContentBytes -Content $full.ScriptContent
    if (-not $bytes) { return $null }
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Get-TenantScriptHash {
    # SHA256 of exactly the bytes the tenant holds, for byte-identical
    # comparison against the local file. Text comparison would quietly forgive
    # a BOM, a CRLF/LF flip or a lost trailing newline; a hash does not.
    param([Parameter(Mandatory)][string]$Id)
    $full = Get-MgBetaDeviceManagementScript -DeviceManagementScriptId $Id -Property scriptContent
    $bytes = Get-WizardScriptContentBytes -Content $full.ScriptContent
    if (-not $bytes) { return $null }
    return Get-WizardBytesHash -Bytes $bytes
}

$v1 = @"
#scriptname:"$displayName"
#noassignments
#startdesc
E2E backup/restore check - VERSION ONE. This is the content a restore must bring back.
#enddesc

Write-Host 'E2E backup/restore: VERSION ONE'
"@ -replace "`r`n", "`n"

$v2 = @"
#scriptname:"$displayName"
#noassignments
#startdesc
E2E backup/restore check - VERSION TWO. This replaced version one and triggered the backup.
#enddesc

Write-Host 'E2E backup/restore: VERSION TWO'
"@ -replace "`r`n", "`n"

# --------------------------------------------------------------------------
# Scratch workspace. #noassignments above keeps this off every device in the
# tenant - the test is about content round-tripping, not assignment.
# --------------------------------------------------------------------------
if (Test-Path -LiteralPath $WorkPath) { Remove-Item -LiteralPath $WorkPath -Recurse -Force }
$deviceDir = Join-Path $WorkPath 'device'
New-Item -ItemType Directory -Path $deviceDir -Force | Out-Null
$scriptFile = Join-Path $deviceDir 'E2E-BackupRestore.ps1'
Set-Content -LiteralPath $scriptFile -Value $v1 -NoNewline

Write-Host ""
Write-Host "E2E backup/restore check" -ForegroundColor Cyan
Write-Host "  Script name : $displayName"
Write-Host "  Workspace   : $WorkPath"
Write-Host ""

Test-WizardPSVersion
Install-WizardModules -AcceptInstall:$AcceptModuleInstall
Import-WizardModules

# This connection is only for verification. It prompts for the tenant
# confirmation once; the wizard child processes below run non-interactive.
Connect-WizardGraph

$createdId = $null
try {
    # ---------------------------------------------------------------- Step 1
    Write-Host "[1/4] Deploying version one (create)..." -ForegroundColor Cyan
    $run = Invoke-Deploy -WizardArgs @('-Path', $WorkPath)
    Check 'Create run exited 0' ($run.ExitCode -eq 0) $run.Output

    $existing = @(Get-MgBetaDeviceManagementScript -All -Property id, displayName |
        Where-Object { $_.DisplayName -eq $displayName })
    Check 'Script exists in the tenant after create' ($existing.Count -eq 1) "found $($existing.Count) named '$displayName'"
    if ($existing.Count -ne 1) { throw "Cannot continue without exactly one '$displayName' in the tenant." }
    $createdId = $existing[0].Id
    $localHash = Get-WizardFileHash -Path $scriptFile
    Check 'Tenant holds version one, byte for byte' ((Get-TenantScriptHash -Id $createdId) -eq $localHash) `
        "local $localHash vs tenant $(Get-TenantScriptHash -Id $createdId) - check for a BOM, CRLF/LF, or a lost trailing newline"

    # ---------------------------------------------------------------- Step 2
    Write-Host "[2/4] Deploying version two (update, writes a backup)..." -ForegroundColor Cyan
    Set-Content -LiteralPath $scriptFile -Value $v2 -NoNewline
    $run = Invoke-Deploy -WizardArgs @('-Path', $WorkPath)
    Check 'Update run exited 0' ($run.ExitCode -eq 0) $run.Output
    $localHashV2 = Get-WizardFileHash -Path $scriptFile
    Check 'Tenant holds version two, byte for byte' ((Get-TenantScriptHash -Id $createdId) -eq $localHashV2) 'the update did not take'

    $backupDir = Join-Path $WorkPath 'backups'
    $backupFiles = @(Get-ChildItem -LiteralPath $backupDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
    Check 'Update wrote exactly one backup' ($backupFiles.Count -eq 1) "found $($backupFiles.Count) in $backupDir"
    if ($backupFiles.Count -ne 1) { throw "Cannot continue without exactly one backup file." }
    $backupFile = $backupFiles[0].FullName

    # ---------------------------------------------------------------- Step 3
    # The file itself, before trusting a restore of it. A backup that only
    # restores because the reader can repair it is still a broken backup.
    Write-Host "[3/4] Checking the backup file is well-formed..." -ForegroundColor Cyan
    $backup = Get-Content -LiteralPath $backupFile -Raw | ConvertFrom-Json -AsHashtable
    Check 'Backup stores content as base64 text' ($backup['ScriptContent'] -is [string]) `
        "ScriptContent is $(if ($null -eq $backup['ScriptContent']) { 'null' } else { $backup['ScriptContent'].GetType().Name }) - a byte[] written through unconverted lands here as an array of numbers"
    $decoded = ''
    try { $decoded = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String([string]$backup['ScriptContent'])) } catch { }
    Check 'Backup content decodes to version one' ($decoded -eq $v1) "decoded to: $decoded"
    Check 'Backup recorded the original id' ($backup['Id'] -eq $createdId) "got $($backup['Id'])"
    Check 'Backup recorded the display name' ($backup['DisplayName'] -eq $displayName) "got $($backup['DisplayName'])"

    # ---------------------------------------------------------------- Step 4
    Write-Host "[4/4] Restoring the backup..." -ForegroundColor Cyan
    $run = Invoke-Deploy -WizardArgs @('-Path', $WorkPath, '-Restore', $backupFile)
    Check 'Restore run exited 0' ($run.ExitCode -eq 0) $run.Output
    # Against the hash of the original v1 bytes, not the file on disk - the file
    # now holds v2, which is the whole point of what the restore had to undo.
    $v1Hash = Get-WizardBytesHash -Bytes ([System.Text.Encoding]::UTF8.GetBytes($v1))
    Check 'Tenant holds version one again, byte for byte' ((Get-TenantScriptHash -Id $createdId) -eq $v1Hash) `
        "expected $v1Hash, tenant has $(Get-TenantScriptHash -Id $createdId)"
    Check 'Restored text matches version one' ((Get-TenantScriptText -Id $createdId) -eq $v1) 'the restore did not bring version one back'

    $filed = Join-Path (Join-Path $backupDir 'backup-restored') (Split-Path -Leaf $backupFile)
    Check 'Used backup filed under backup-restored/' (Test-Path -LiteralPath $filed) "expected $filed"
    Check 'Used backup no longer in backups/' (-not (Test-Path -LiteralPath $backupFile)) "still at $backupFile"
} finally {
    # Cleanup runs even on a failed assertion, so a broken run does not leave a
    # script behind in the tenant for the next one to collide with.
    if ($createdId -and -not $KeepArtifacts) {
        Write-Host ""
        Write-Host "Cleaning up tenant script $createdId..." -ForegroundColor DarkGray
        try {
            Remove-WizardScript -Id $createdId
        } catch {
            Write-Warning "Could not delete the test script '$displayName' ($createdId): $(Get-WizardErrorSummary -ErrorRecord $_). Remove it by hand, or re-run Remove-E2ETestSet.ps1 -Confirm."
        }
    } elseif ($createdId) {
        Write-Host ""
        Write-Host "-KeepArtifacts: '$displayName' ($createdId) left in the tenant and $WorkPath left on disk." -ForegroundColor Yellow
    }
    if (-not $KeepArtifacts -and (Test-Path -LiteralPath $WorkPath)) {
        Remove-Item -LiteralPath $WorkPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    Disconnect-WizardGraph
}

Write-Host ""
if ($script:Failed -gt 0) {
    Write-Host "$($script:Passed) passed, $($script:Failed) failed" -ForegroundColor Red
    exit 1
}
Write-Host "$($script:Passed) passed, 0 failed" -ForegroundColor Green
exit 0
