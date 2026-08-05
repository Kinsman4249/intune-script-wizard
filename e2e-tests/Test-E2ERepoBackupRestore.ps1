#Requires -Version 7.0
<#
.SYNOPSIS
    Proves against a real dev tenant AND a real remote git repo that the
    template export -> repo push -> -SourceRepo restore path actually works
    end to end: tenant scripts survive being deleted and pulled back from
    GitHub/Azure DevOps, meta-comment directives regenerate correctly, and
    the restored copies actually uploaded to the tenant carry the wizard's
    template header for a human to eyeball.

.DESCRIPTION
    Test-E2EBackupRestore.ps1 covers the JSON backups/ -> -Restore path.
    This script covers the other one: lib/Template.ps1's .ps1 export,
    lib/RepoBackup.ps1's push to a remote repo, and lib/RepoSource.ps1's
    -SourceRepo pull - none of which that script touches.

      1. Deploys two throwaway scripts (one user/, one device/), each with
         its own meta-comment directives and hand-written prose/block
         comments in the body.
      2. Makes sure a Templates repo push is configured (walks through the
         real first-run prompt if it isn't - see repo-template-config.json).
      3. Backs up each script by name, which exports a regenerated .ps1
         template for it and pushes templates/ to the configured remote.
      4. Clones that remote independently (before touching the tenant) and
         checks the pushed files are byte-identical to what's on disk -
         proof the push landed, not just that the local step didn't throw.
      5. Deletes both scripts from the tenant.
      6. Restores them with -SourceRepo pointed at the same remote, into an
         otherwise-empty -Path, so nothing local can paper over a broken
         pull.
      7. Checks the restored tenant content: it must contain the wizard's
         regenerated template header (proving the meta-comment insertions
         the backup side made are really what got uploaded), its
         EnforceSignatureCheck/RunAs32Bit must match what the original
         directives asked for, and - once comments and blank lines are
         stripped from both sides - its logic must be byte-for-byte the
         same as the original, pre-delete tenant content.

    Restored content is also written to WorkPath/restored-tenant-content/
    so the header insertion can be read by eye, not just asserted.

    Both test scripts carry #noassignments, so this does not exercise
    #group:/#excludegroup: round-tripping - see Test-E2EDeployedSet.ps1 and
    the generated set for that. It also does not clean up the remote repo's
    git history; each run adds one more commit to it.

    Deploy-IntuneScripts.ps1 is invoked with stdin redirected so those child
    runs are non-interactive and skip the per-run tenant confirmation prompt
    (and, not being interactive, never try to run first-run repo setup
    themselves). This script asks for the tenant confirmation once, up
    front, on its own connection, and - the first time only - walks through
    the interactive repo-push setup prompt itself too.

.PARAMETER MetadataPath
    Path to e2e-metadata.json (read for answers.confirmDevTenant and
    answers.runPrefix). Defaults to the file next to this script.

.PARAMETER WorkPath
    Scratch -Path root for the generated scripts, their backups/ and
    templates/ folders, the restore target, and the independent clone used
    to verify the push. Defaults to e2e-tests/generated-repo-backup-restore.
    Rebuilt on every run.

.PARAMETER KeepArtifacts
    Leave both test scripts in the tenant and the scratch folder on disk,
    for poking at a failure by hand. Without this both are cleaned up.
    Never touches the remote repo either way.

.PARAMETER AcceptModuleInstall
    Install missing required Graph modules without prompting.
#>
[CmdletBinding()]
param(
    [string]$MetadataPath = (Join-Path $PSScriptRoot 'e2e-metadata.json'),
    [string]$WorkPath = (Join-Path $PSScriptRoot 'generated-repo-backup-restore'),
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
. (Join-Path $repo 'lib/GraphOps.ps1')
. (Join-Path $repo 'lib/Backup.ps1')
. (Join-Path $repo 'lib/Template.ps1')
. (Join-Path $repo 'lib/RepoBackup.ps1')
. (Join-Path $repo 'lib/RepoSource.ps1')

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
    throw "'$MetadataPath': answers.confirmDevTenant is false. This script creates, backs up, deletes and restores real tenant objects, and pushes to a real remote repo - set confirmDevTenant to true once you've confirmed you're pointed at a dev tenant."
}
$runPrefix = [string]$metadata['answers']['runPrefix']
if ([string]::IsNullOrWhiteSpace($runPrefix)) { $runPrefix = 'ZZZ-E2E-TEST-DELETE-ME' }

$userDisplayName = "$runPrefix Repo-Restore-User"
$deviceDisplayName = "$runPrefix Repo-Restore-Device"

# --------------------------------------------------------------------------
# Tiny check harness, same shape as the offline suite and the sibling E2E
# scripts: record every assertion and keep going, so one failure still
# reports what else was wrong.
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
    # child skips the tenant-confirmation prompt this script already answered
    # (and never attempts first-run repo-push setup on its own).
    param([string[]]$WizardArgs)
    $output = '' | & pwsh -NoProfile -File $deploy @WizardArgs 2>&1 | Out-String
    return [pscustomobject]@{ Output = $output; ExitCode = $LASTEXITCODE }
}

function Get-TenantScript {
    # Reads a script back out of the tenant with the properties this test
    # actually checks - explicit -Property because the beta cmdlet's default
    # projection is not guaranteed to include all of these.
    param([Parameter(Mandatory)][string]$Id)
    return Get-MgBetaDeviceManagementScript -DeviceManagementScriptId $Id `
        -Property id, displayName, scriptContent, enforceSignatureCheck, runAs32Bit, runAsAccount
}

function Get-TenantScriptText {
    param([Parameter(Mandatory)][string]$Id)
    $full = Get-TenantScript -Id $Id
    $bytes = Get-WizardScriptContentBytes -Content $full.ScriptContent
    if (-not $bytes) { return $null }
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

# Strips <# ... #> block comments, then everything from an unquoted '#' to
# end of line, then drops blank lines - so two versions of a script that
# differ only in comments (the wizard's own regenerated header among them)
# compare equal on logic alone. Deliberately simple: it doesn't try to
# understand '#' inside a quoted string, which is fine because nothing this
# test writes ever puts one there.
function Get-WizardLogicOnlyText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $noBlockComments = $Text -replace '(?s)<#.*?#>', ''
    $lines = $noBlockComments -split "`r?`n" | ForEach-Object {
        ($_ -replace '#.*$', '').Trim()
    } | Where-Object { $_ -ne '' }
    return ($lines -join "`n")
}

# --------------------------------------------------------------------------
# Scratch workspace.
# --------------------------------------------------------------------------
if (Test-Path -LiteralPath $WorkPath) { Remove-Item -LiteralPath $WorkPath -Recurse -Force }
$userDir = Join-Path $WorkPath 'user'
$deviceDir = Join-Path $WorkPath 'device'
New-Item -ItemType Directory -Path $userDir -Force | Out-Null
New-Item -ItemType Directory -Path $deviceDir -Force | Out-Null
$userFile = Join-Path $userDir 'RepoE2E-User.ps1'
$deviceFile = Join-Path $deviceDir 'RepoE2E-Device.ps1'

# Directive names deliberately avoided in the prose below (no "type:",
# "group:", "host:", "scriptcheck:", "noassignments" as bare words) so
# Get-ScriptMetadata's whole-file directive scan - which is not limited to a
# leading block - can never mistake ordinary prose for a real directive.
$v1User = @"
#scriptname:"$userDisplayName"
#noassignments
#scriptcheck:yes
#startdesc
E2E repo backup/restore check - USER script. This description proves the
round trip through the template header too.
#enddesc

<#
    Block comment noise above the real logic - must not survive into the
    logic-only comparison this test makes after the restore.
#>
# Inline comment noise before the real line.
Write-Host 'E2E repo-restore: USER script v1'
# Inline comment noise after the real line.
"@ -replace "`r`n", "`n"

$v1Device = @"
#scriptname:"$deviceDisplayName"
#noassignments
#host:64
#startdesc
E2E repo backup/restore check - DEVICE script. Same idea as the user one,
covering the other folder and the other directive shape.
#enddesc

<#
    More block comment noise, same reason as the user script.
#>
# Inline comment noise before the real line.
Write-Host 'E2E repo-restore: DEVICE script v1'
# Inline comment noise after the real line.
"@ -replace "`r`n", "`n"

Set-Content -LiteralPath $userFile -Value $v1User -NoNewline
Set-Content -LiteralPath $deviceFile -Value $v1Device -NoNewline

Write-Host ""
Write-Host "E2E repo backup/restore check" -ForegroundColor Cyan
Write-Host "  User script   : $userDisplayName"
Write-Host "  Device script : $deviceDisplayName"
Write-Host "  Workspace     : $WorkPath"
Write-Host ""

Test-WizardPSVersion
Install-WizardModules -AcceptInstall:$AcceptModuleInstall
Import-WizardModules

# This connection is only for verification, the interactive repo setup
# prompt (if needed) and the deletes below. It prompts for the tenant
# confirmation once; the wizard child processes run non-interactive.
Connect-WizardGraph

$userId = $null
$deviceId = $null
$restoredUserId = $null
$restoredDeviceId = $null
try {
    # ---------------------------------------------------------------- Step 1
    Write-Host "[1/7] Deploying both scripts (create)..." -ForegroundColor Cyan
    $run = Invoke-Deploy -WizardArgs @('-Path', $WorkPath)
    Check 'Create run exited 0' ($run.ExitCode -eq 0) $run.Output

    $existingUser = @(Get-MgBetaDeviceManagementScript -All -Property id, displayName |
        Where-Object { $_.DisplayName -eq $userDisplayName })
    $existingDevice = @(Get-MgBetaDeviceManagementScript -All -Property id, displayName |
        Where-Object { $_.DisplayName -eq $deviceDisplayName })
    Check 'User script exists in the tenant after create' ($existingUser.Count -eq 1) "found $($existingUser.Count) named '$userDisplayName'"
    Check 'Device script exists in the tenant after create' ($existingDevice.Count -eq 1) "found $($existingDevice.Count) named '$deviceDisplayName'"
    if ($existingUser.Count -ne 1 -or $existingDevice.Count -ne 1) {
        throw "Cannot continue without exactly one of each script in the tenant."
    }
    $userId = $existingUser[0].Id
    $deviceId = $existingDevice[0].Id

    $origUserText = Get-TenantScriptText -Id $userId
    $origDeviceText = Get-TenantScriptText -Id $deviceId
    Check 'Tenant holds the user script v1 text' ($origUserText -eq $v1User) 'content did not round-trip on create'
    Check 'Tenant holds the device script v1 text' ($origDeviceText -eq $v1Device) 'content did not round-trip on create'

    # ---------------------------------------------------------------- Step 2
    Write-Host "[2/7] Making sure a Templates repo push is configured..." -ForegroundColor Cyan
    $templatesConfig = Get-WizardRepoBackupConfig -Kind Templates
    if (-not $templatesConfig -or $templatesConfig['Declined']) {
        Write-Host "  No usable Templates repo config found - walking through first-run setup now." -ForegroundColor Yellow
        Write-Host "  Answer 'y', paste your Azure DevOps repo URL, and complete whichever auth prompt follows." -ForegroundColor Yellow
        Request-WizardRepoBackupSetup -Kind Templates
        $templatesConfig = Get-WizardRepoBackupConfig -Kind Templates
    }
    $repoConfigured = ($templatesConfig -and -not $templatesConfig['Declined'] -and $templatesConfig['RemoteUrl'])
    Check 'Templates repo push is configured' $repoConfigured "config: $(if ($templatesConfig) { $templatesConfig | ConvertTo-Json -Compress } else { '<none>' })"
    if (-not $repoConfigured) {
        throw "Cannot continue without a configured Templates repo push. Re-run and complete the setup prompt, or delete '$(Get-WizardRepoBackupConfigPath -Kind Templates)' and try again."
    }
    $remoteUrl = [string]$templatesConfig['RemoteUrl']
    Write-Host "  Using $remoteUrl" -ForegroundColor DarkGray

    # ---------------------------------------------------------------- Step 3
    Write-Host "[3/7] Backing up each script by name (exports + pushes templates)..." -ForegroundColor Cyan
    $run = Invoke-Deploy -WizardArgs @('-Path', $WorkPath, '-Backup', $userDisplayName)
    Check 'Backup (user) run exited 0' ($run.ExitCode -eq 0) $run.Output
    $run = Invoke-Deploy -WizardArgs @('-Path', $WorkPath, '-Backup', $deviceDisplayName)
    Check 'Backup (device) run exited 0' ($run.ExitCode -eq 0) $run.Output

    $userTemplateFiles = @(Get-ChildItem -LiteralPath (Join-Path $WorkPath 'templates/user') -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
    $deviceTemplateFiles = @(Get-ChildItem -LiteralPath (Join-Path $WorkPath 'templates/device') -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
    Check 'Exactly one user template was exported' ($userTemplateFiles.Count -eq 1) "found $($userTemplateFiles.Count)"
    Check 'Exactly one device template was exported' ($deviceTemplateFiles.Count -eq 1) "found $($deviceTemplateFiles.Count)"
    if ($userTemplateFiles.Count -ne 1 -or $deviceTemplateFiles.Count -ne 1) {
        throw "Cannot continue without exactly one exported template per script."
    }

    $userTemplateText = Get-Content -LiteralPath $userTemplateFiles[0].FullName -Raw
    $deviceTemplateText = Get-Content -LiteralPath $deviceTemplateFiles[0].FullName -Raw
    Check 'User template carries the wizard header markers' `
        ($userTemplateText.Contains($script:WizardTemplateStartMarker) -and $userTemplateText.Contains($script:WizardTemplateEndMarker))
    Check 'User template regenerated #scriptname: and #scriptcheck:yes' `
        ($userTemplateText.Contains("#scriptname:`"$userDisplayName`"") -and $userTemplateText.Contains('#scriptcheck:yes'))
    Check 'Device template regenerated #scriptname: and #host:64' `
        ($deviceTemplateText.Contains("#scriptname:`"$deviceDisplayName`"") -and $deviceTemplateText.Contains('#host:64'))
    Check 'User template still carries the original v1 body verbatim' $userTemplateText.Contains('E2E repo-restore: USER script v1')
    Check 'Device template still carries the original v1 body verbatim' $deviceTemplateText.Contains('E2E repo-restore: DEVICE script v1')

    # ---------------------------------------------------------------- Step 4
    # Clone the remote independently - not just "the push command didn't
    # throw" - and do it BEFORE anything in the tenant is deleted, so a
    # broken push aborts here with both scripts still safely in place.
    Write-Host "[4/7] Verifying the push landed on the remote (independent clone)..." -ForegroundColor Cyan
    $verifyCacheRoot = Join-Path $WorkPath 'verify-clone'
    $spec = Get-WizardRepoSourceSpec -Raw $remoteUrl
    $cloneScanRoot = $null
    try {
        $cloneScanRoot = Sync-WizardRepoSource -Spec $spec -CacheRoot $verifyCacheRoot
    } catch {
        Check 'Remote clone for verification succeeded' $false $_.Exception.Message
    }
    if ($cloneScanRoot) {
        Check 'Remote clone for verification succeeded' $true
        $clonedUser = @(Get-ChildItem -LiteralPath (Join-Path $cloneScanRoot 'user') -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
        $clonedDevice = @(Get-ChildItem -LiteralPath (Join-Path $cloneScanRoot 'device') -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
        Check 'Cloned remote has exactly one user template' ($clonedUser.Count -eq 1) "found $($clonedUser.Count)"
        Check 'Cloned remote has exactly one device template' ($clonedDevice.Count -eq 1) "found $($clonedDevice.Count)"
        if ($clonedUser.Count -eq 1) {
            $bytesEqual = Test-WizardBytesEqual -A ([System.IO.File]::ReadAllBytes($clonedUser[0].FullName)) -B ([System.IO.File]::ReadAllBytes($userTemplateFiles[0].FullName))
            Check 'Cloned user template is byte-identical to the pushed local copy' $bytesEqual
        }
        if ($clonedDevice.Count -eq 1) {
            $bytesEqual = Test-WizardBytesEqual -A ([System.IO.File]::ReadAllBytes($clonedDevice[0].FullName)) -B ([System.IO.File]::ReadAllBytes($deviceTemplateFiles[0].FullName))
            Check 'Cloned device template is byte-identical to the pushed local copy' $bytesEqual
        }
    }
    if ($script:Failed -gt 0) {
        throw "Push verification failed; refusing to delete anything from the tenant. See the FAIL lines above."
    }

    # ---------------------------------------------------------------- Step 5
    Write-Host "[5/7] Deleting both scripts from the tenant..." -ForegroundColor Cyan
    Remove-WizardScript -Id $userId
    Remove-WizardScript -Id $deviceId
    $stillThere = @(Get-MgBetaDeviceManagementScript -All -Property id, displayName |
        Where-Object { $_.DisplayName -eq $userDisplayName -or $_.DisplayName -eq $deviceDisplayName })
    Check 'Both scripts are gone from the tenant' ($stillThere.Count -eq 0) "still found: $(($stillThere.DisplayName) -join ', ')"
    $userId = $null
    $deviceId = $null

    # ---------------------------------------------------------------- Step 6
    Write-Host "[6/7] Restoring from the remote via -SourceRepo (empty -Path)..." -ForegroundColor Cyan
    $restorePath = Join-Path $WorkPath 'restore'
    New-Item -ItemType Directory -Path $restorePath -Force | Out-Null
    $run = Invoke-Deploy -WizardArgs @('-Path', $restorePath, '-SourceRepo', $remoteUrl)
    Check 'Restore run exited 0' ($run.ExitCode -eq 0) $run.Output

    $restoredUser = @(Get-MgBetaDeviceManagementScript -All -Property id, displayName |
        Where-Object { $_.DisplayName -eq $userDisplayName })
    $restoredDevice = @(Get-MgBetaDeviceManagementScript -All -Property id, displayName |
        Where-Object { $_.DisplayName -eq $deviceDisplayName })
    Check 'User script exists in the tenant after restore' ($restoredUser.Count -eq 1) "found $($restoredUser.Count)"
    Check 'Device script exists in the tenant after restore' ($restoredDevice.Count -eq 1) "found $($restoredDevice.Count)"
    if ($restoredUser.Count -ne 1 -or $restoredDevice.Count -ne 1) {
        throw "Cannot continue without exactly one restored copy of each script."
    }
    $restoredUserId = $restoredUser[0].Id
    $restoredDeviceId = $restoredDevice[0].Id

    # ---------------------------------------------------------------- Step 7
    Write-Host "[7/7] Checking the restored copies..." -ForegroundColor Cyan
    $restoredUserFull = Get-TenantScript -Id $restoredUserId
    $restoredDeviceFull = Get-TenantScript -Id $restoredDeviceId
    $restoredUserText = [System.Text.Encoding]::UTF8.GetString((Get-WizardScriptContentBytes -Content $restoredUserFull.ScriptContent))
    $restoredDeviceText = [System.Text.Encoding]::UTF8.GetString((Get-WizardScriptContentBytes -Content $restoredDeviceFull.ScriptContent))

    # The insertions themselves, visible in what actually got uploaded - not
    # just "a restore happened", but that the backup side's regenerated
    # meta-comment header is really what the tenant is running.
    Check 'Restored user script carries the wizard header markers' `
        ($restoredUserText.Contains($script:WizardTemplateStartMarker) -and $restoredUserText.Contains($script:WizardTemplateEndMarker))
    Check 'Restored device script carries the wizard header markers' `
        ($restoredDeviceText.Contains($script:WizardTemplateStartMarker) -and $restoredDeviceText.Contains($script:WizardTemplateEndMarker))

    Check 'Restored user script kept EnforceSignatureCheck from #scriptcheck:yes' ([bool]$restoredUserFull.EnforceSignatureCheck -eq $true) `
        "got $($restoredUserFull.EnforceSignatureCheck)"
    Check 'Restored device script kept RunAs32Bit false from #host:64' ([bool]$restoredDeviceFull.RunAs32Bit -eq $false) `
        "got $($restoredDeviceFull.RunAs32Bit)"

    $origUserLogic = Get-WizardLogicOnlyText -Text $origUserText
    $restoredUserLogic = Get-WizardLogicOnlyText -Text $restoredUserText
    $origDeviceLogic = Get-WizardLogicOnlyText -Text $origDeviceText
    $restoredDeviceLogic = Get-WizardLogicOnlyText -Text $restoredDeviceText
    Check 'User script logic matches before and after, comments stripped' ($origUserLogic -eq $restoredUserLogic) `
        "before: $origUserLogic`n      after:  $restoredUserLogic"
    Check 'Device script logic matches before and after, comments stripped' ($origDeviceLogic -eq $restoredDeviceLogic) `
        "before: $origDeviceLogic`n      after:  $restoredDeviceLogic"

    # Left on disk (not deleted even by -KeepArtifacts logic below, since it's
    # not a tenant artifact) so the header insertion can be read by eye.
    $inspectDir = Join-Path $WorkPath 'restored-tenant-content'
    New-Item -ItemType Directory -Path $inspectDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $inspectDir 'RepoE2E-User.ps1') -Value $restoredUserText -NoNewline
    Set-Content -LiteralPath (Join-Path $inspectDir 'RepoE2E-Device.ps1') -Value $restoredDeviceText -NoNewline
    Write-Host "  Restored tenant content written to $inspectDir for a by-eye look at the header insertion." -ForegroundColor DarkGray
} finally {
    # Cleanup runs even on a failed assertion, so a broken run does not leave
    # scripts behind in the tenant for the next one to collide with. The
    # remote repo itself is never touched here.
    $idsToClean = @($userId, $deviceId, $restoredUserId, $restoredDeviceId) | Where-Object { $_ }
    if ($idsToClean.Count -gt 0 -and -not $KeepArtifacts) {
        Write-Host ""
        Write-Host "Cleaning up tenant scripts..." -ForegroundColor DarkGray
        foreach ($id in $idsToClean) {
            try {
                Remove-WizardScript -Id $id
            } catch {
                Write-Warning "Could not delete tenant script $id : $(Get-WizardErrorSummary -ErrorRecord $_). Remove it by hand, or re-run Remove-E2ETestSet.ps1 -Confirm."
            }
        }
    } elseif ($idsToClean.Count -gt 0) {
        Write-Host ""
        Write-Host "-KeepArtifacts: $($idsToClean.Count) tenant script(s) left in place and $WorkPath left on disk." -ForegroundColor Yellow
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
