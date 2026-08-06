#Requires -Version 7.0
<#
.SYNOPSIS
    Proves the real disaster-recovery story on the real dev tenant: every
    script currently in it is backed up (JSON + .ps1 template), the template
    push to the remote repo is independently verified, every script is then
    DELETED from the tenant, and all of them are restored purely from the
    remote repo via -SourceRepo. Produces a markdown report suitable for
    showing someone who wasn't in the room.

.DESCRIPTION
    This is deliberately not like the rest of e2e-tests/: it does not create
    throwaway scripts of its own. It operates on whatever real scripts
    already exist in the tenant, because a rehearsal against synthetic,
    known-shape data proves less than one against arbitrary real content -
    real assignments, real descriptions, real edge cases nobody thought to
    script. That is also what makes it far more destructive: step 5 below
    deletes EVERY script in the tenant, not just ones this run created.

      1. Makes sure a Templates repo push is configured (walks through the
         real first-run prompt if it isn't).
      2. Reads the full list of scripts currently in the tenant.
      3. Runs -BackupAll: a JSON backup of every script (the "before"
         record this script compares against later) plus a regenerated .ps1
         template of each, pushed to the configured remote.
      4. Clones that remote independently and checks every template file on
         disk is byte-identical to what landed on the remote - BEFORE
         anything is deleted.
      5. Prints exactly what is about to be deleted and requires typing an
         exact confirmation phrase - not y/N - before deleting every script
         in the tenant. Pass -StopBeforeDelete to rehearse steps 1-4 only
         and stop here.
      6. Restores everything with -SourceRepo pointed at the same remote,
         into an otherwise-empty -Path.
      7. For every script from step 2, matches it to a restored script by
         display name and checks: the restored content carries the wizard's
         regenerated template header, EnforceSignatureCheck/RunAs32Bit/
         RunAsAccount match the original, its logic matches the original
         once comments and blank lines are stripped from both sides, and
         its assignments match - except #group:/#excludegroup: cannot
         express an "all devices"/"all licensed users" assignment (see
         lib/Template.ps1's Export-WizardScriptTemplate), so a script that
         only had that kind of assignment is reported as a known
         limitation, not a failure.

    A script excluded from template export (#notemplate, or one whose
    export otherwise failed) is expected to come back missing after the
    restore - see step 4's push-verification output for which display names
    were actually templated - and is reported as skipped, not failed.

    Deploy-IntuneScripts.ps1 is invoked with stdin redirected so those child
    runs are non-interactive. This script itself asks for the tenant
    confirmation, the repo-push setup (if needed), and the delete
    confirmation, all on its own connection.

.PARAMETER MetadataPath
    Path to e2e-tests/e2e-metadata.json (read for answers.confirmDevTenant
    only - runPrefix does not apply here, this touches every script in the
    tenant regardless of name). Defaults to the file next to this script.

.PARAMETER WorkPath
    Scratch -Path root for the JSON backups, exported templates, the
    independent verification clone, and the restore target. Defaults to
    e2e-tests/tenant-wide-repo-backup-restore. NOT deleted when the run
    finishes - it holds your only local copy of the pre-delete JSON
    backups. Rebuilt (wiped and recreated) at the start of every run, so
    move anything you want to keep out of it first.

.PARAMETER ReportPath
    Where to write the markdown summary report. Defaults to
    WorkPath/report.md.

.PARAMETER StopBeforeDelete
    Run steps 1-4 (backup, push, independent verification) and then stop,
    without deleting or restoring anything. Use this to rehearse safely
    before committing to the real delete+restore.

.PARAMETER AcceptModuleInstall
    Install missing required Graph modules without prompting.
#>
[CmdletBinding()]
param(
    [string]$MetadataPath = (Join-Path $PSScriptRoot 'e2e-metadata.json'),
    [string]$WorkPath = (Join-Path $PSScriptRoot 'tenant-wide-repo-backup-restore'),
    [string]$ReportPath,
    [switch]$StopBeforeDelete,
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
. (Join-Path $repo 'lib/Backup.ps1')
. (Join-Path $repo 'lib/TemplateHeader.ps1')
. (Join-Path $repo 'lib/Template.ps1')
. (Join-Path $repo 'lib/RepoBackup.ps1')
. (Join-Path $repo 'lib/RepoBackupSubpath.ps1')
. (Join-Path $repo 'lib/RepoSource.ps1')

if (-not $ReportPath) { $ReportPath = Join-Path $WorkPath 'report.md' }

# --------------------------------------------------------------------------
# Metadata gate - same confirmDevTenant contract as the rest of the kit.
# runPrefix is not read: this run is not scoped to a prefix, it is the
# whole tenant.
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
    throw "'$MetadataPath': answers.confirmDevTenant is false. This script deletes and restores EVERY script currently in the tenant - set confirmDevTenant to true once you've confirmed you're pointed at a dev tenant."
}

# --------------------------------------------------------------------------
# Tiny check harness, same shape as the rest of the kit.
# --------------------------------------------------------------------------
$script:Passed = 0
$script:Failed = 0
$script:Notes = @()
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
    # Runs the real wizard as a child process, same as every other script in
    # this kit - the point of using the actual CLI rather than calling the
    # library functions directly is that this rehearses the exact commands a
    # real recovery would use. Piping '' redirects stdin, making the child
    # non-interactive.
    param([string[]]$WizardArgs)
    $output = '' | & pwsh -NoProfile -File $deploy @WizardArgs 2>&1 | Out-String
    return [pscustomobject]@{ Output = $output; ExitCode = $LASTEXITCODE }
}

# Strips <# ... #> block comments, then everything from an unquoted '#' to
# end of line, then drops blank lines - so two versions of a script that
# differ only in comments (the wizard's own regenerated header among them)
# compare equal on logic alone.
function Get-WizardLogicOnlyText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $noBlockComments = $Text -replace '(?s)<#.*?#>', ''
    $lines = $noBlockComments -split "`r?`n" | ForEach-Object { ($_ -replace '#.*$', '').Trim() } | Where-Object { $_ -ne '' }
    return ($lines -join "`n")
}

# A stable, order-independent fingerprint of an assignment target: group
# targets compare by their groupId, everything else compares by its
# @odata.type alone (there is only ever one "all devices" target, etc).
function Get-WizardAssignmentTargetKey {
    param([Parameter(Mandatory)][hashtable]$Target)
    $type = [string]$Target['@odata.type']
    if ($type -in @('#microsoft.graph.groupAssignmentTarget', '#microsoft.graph.exclusionGroupAssignmentTarget')) {
        return "$type|$($Target['groupId'])"
    }
    return $type
}

function Get-WizardAssignmentTargetKeys {
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Assignments)
    return @($Assignments | ForEach-Object { Get-WizardAssignmentTargetKey -Target $_['target'] } | Sort-Object -Unique)
}

# --------------------------------------------------------------------------
# Scratch workspace. Rebuilt every run; NOT removed at the end - it holds
# the only local copy of the pre-delete JSON backups.
# --------------------------------------------------------------------------
if (Test-Path -LiteralPath $WorkPath) { Remove-Item -LiteralPath $WorkPath -Recurse -Force }
New-Item -ItemType Directory -Path $WorkPath -Force | Out-Null

Write-Host ""
Write-Host "Tenant-wide repo backup/restore check" -ForegroundColor Cyan
Write-Host "  Workspace : $WorkPath" -ForegroundColor Cyan
Write-Host "  Report    : $ReportPath" -ForegroundColor Cyan
Write-Host ""
Write-Host "This backs up, then DELETES, then restores EVERY script currently in the tenant." -ForegroundColor Yellow
Write-Host ""

Test-WizardPSVersion
Install-WizardModules -AcceptInstall:$AcceptModuleInstall
Import-WizardModules

# This connection is for reading/deleting/verifying and any interactive
# prompts below. It prompts for the tenant confirmation once; the wizard
# child processes run non-interactive.
Connect-WizardGraph

$reportRows = @()
try {
    # ---------------------------------------------------------------- Step 1
    Write-Host "[1/7] Making sure a Templates repo push is configured..." -ForegroundColor Cyan
    $templatesConfig = Get-WizardRepoBackupConfig -Kind Templates
    if (-not $templatesConfig -or $templatesConfig['Declined']) {
        Write-Host "  No usable Templates repo config found - walking through first-run setup now." -ForegroundColor Yellow
        Write-Host "  Answer 'y', paste your repo URL, and complete whichever auth prompt follows." -ForegroundColor Yellow
        Request-WizardRepoBackupSetup -Kind Templates
        $templatesConfig = Get-WizardRepoBackupConfig -Kind Templates
    }
    $repoConfigured = ($templatesConfig -and -not $templatesConfig['Declined'] -and $templatesConfig['RemoteUrl'])
    Check 'Templates repo push is configured' $repoConfigured
    if (-not $repoConfigured) {
        throw "Cannot continue without a configured Templates repo push. Re-run and complete the setup prompt, or delete '$(Get-WizardRepoBackupConfigPath -Kind Templates)' and try again."
    }
    # Raw, not RemoteUrl: RemoteUrl is the bare git URL with the ref/subpath
    # already split off into their own config fields. Get-WizardRepoSourceSpec
    # (used below for the verification clone, and passed to -SourceRepo for
    # the restore) needs the combined '<url>#<ref>::<subpath>' form to find
    # the same branch/folder the push actually wrote to.
    $remoteUrl = [string]$templatesConfig['Raw']
    Write-Host "  Using $remoteUrl" -ForegroundColor DarkGray

    # ---------------------------------------------------------------- Step 2
    Write-Host "[2/7] Reading every script currently in the tenant..." -ForegroundColor Cyan
    $originalList = @(Get-MgBetaDeviceManagementScript -All -Property id, displayName)
    Write-Host "  Found $($originalList.Count) script(s)."
    if ($originalList.Count -eq 0) {
        Write-Host "Nothing to back up. Exiting." -ForegroundColor Yellow
        exit 0
    }

    # ---------------------------------------------------------------- Step 3
    Write-Host "[3/7] Running -BackupAll (JSON backups + template export + push)..." -ForegroundColor Cyan
    $run = Invoke-Deploy -WizardArgs @('-Path', $WorkPath, '-BackupAll')
    Check '-BackupAll run exited 0' ($run.ExitCode -eq 0) $run.Output

    # A pushed-but-conflicting file under the configured subpath (something
    # already there that the wizard doesn't own from a previous push) is left
    # untouched, not an error - Sync-WizardRepoBackupSubpath still exits 0.
    # That means the warning below is silently swallowed by the Check above
    # on the success path. Surface it unconditionally here so a mismatch in
    # step 4 (same file, remote still has the pre-existing content) is
    # traceable back to its cause instead of just showing up as a raw byte
    # diff with no explanation.
    $conflictLines = @($run.Output -split "`r?`n" | Where-Object {
        $_ -match 'already has \d+ file\(s\) this wizard did not put there' -or
        $_ -match 'Leaving \d+ pre-existing file'
    })
    if ($conflictLines.Count -gt 0) {
        Write-Host "  Push reported pre-existing/conflicting file(s) under the configured subpath - these are NOT overwritten and will show up as mismatches in step 4:" -ForegroundColor Yellow
        foreach ($line in $conflictLines) { Write-Host "    $line" -ForegroundColor Yellow }
    }

    $backupDir = Join-Path $WorkPath 'backups'
    $backupFiles = @(Get-ChildItem -LiteralPath $backupDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
    Check "Backed up $($backupFiles.Count) of $($originalList.Count) script(s) to JSON" ($backupFiles.Count -eq $originalList.Count) `
        "found $($backupFiles.Count) backup file(s) in $backupDir"

    # The "before" oracle every later comparison reads from - not a second,
    # independently-captured snapshot, but the same JSON backup the wizard
    # itself would use to recover from. Keyed by original Id.
    $originalById = @{}
    foreach ($file in $backupFiles) {
        $data = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable
        $originalById[[string]$data['Id']] = $data
    }

    # ---------------------------------------------------------------- Step 4
    Write-Host "[4/7] Verifying the template push landed on the remote (independent clone)..." -ForegroundColor Cyan
    $templateDir = Join-Path $WorkPath 'templates'
    $localTemplateFiles = @(Get-ChildItem -LiteralPath $templateDir -Filter '*.ps1' -File -Recurse -ErrorAction SilentlyContinue)
    Write-Host "  $($localTemplateFiles.Count) template file(s) exported locally."

    # Which display names actually got a template (vs. #notemplate or a
    # per-script export failure, both of which are legitimate and expected
    # to come back missing after the restore, not a failure of this script).
    $templatedDisplayNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $localTemplateFiles) {
        $text = Get-Content -LiteralPath $file.FullName -Raw
        if ($text -match '#\s*scriptname\s*:\s*"(?<name>[^"]+)"') {
            [void]$templatedDisplayNames.Add($Matches['name'])
        }
    }

    $verifyCacheRoot = Join-Path $WorkPath 'verify-clone'
    $spec = Get-WizardRepoSourceSpec -Raw $remoteUrl
    $cloneScanRoot = $null
    try {
        $cloneScanRoot = Sync-WizardRepoSource -Spec $spec -CacheRoot $verifyCacheRoot -CreateSubPathIfMissing
    } catch {
        Check 'Remote clone for verification succeeded' $false $_.Exception.Message
    }
    if ($cloneScanRoot) {
        Check 'Remote clone for verification succeeded' $true
        $clonedFiles = @(Get-ChildItem -LiteralPath $cloneScanRoot -Filter '*.ps1' -File -Recurse -ErrorAction SilentlyContinue)
        $clonedByRelPath = @{}
        foreach ($f in $clonedFiles) { $clonedByRelPath[$f.FullName.Substring($cloneScanRoot.Length).TrimStart('\', '/')] = $f }

        $mismatches = 0
        $localRelPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $mismatchDetails = [System.Collections.Generic.List[string]]::new()
        foreach ($local in $localTemplateFiles) {
            $rel = $local.FullName.Substring($templateDir.Length).TrimStart('\', '/')
            [void]$localRelPaths.Add($rel)
            $cloned = $clonedByRelPath[$rel]
            if (-not $cloned) {
                $mismatches++
                $mismatchDetails.Add("missing on remote: $rel")
                continue
            }
            $localBytes = [System.IO.File]::ReadAllBytes($local.FullName)
            $clonedBytes = [System.IO.File]::ReadAllBytes($cloned.FullName)
            $equal = Test-WizardBytesEqual -A $localBytes -B $clonedBytes
            if (-not $equal) {
                $mismatches++
                $mismatchDetails.Add("content differs: $rel (local $($localBytes.Length) bytes, remote $($clonedBytes.Length) bytes)")
            }
        }
        # Files present on the remote clone that don't correspond to any
        # locally-exported template - e.g. something a previous run (or
        # someone else) left under the same subpath. clonedFiles.Count can
        # equal localTemplateFiles.Count even while a mismatch exists, if one
        # local file failed to land (see above) and one unrelated remote file
        # happens to make up the difference; listing these explicitly avoids
        # having to guess which is which from the counts alone.
        $extraRemote = @($clonedByRelPath.Keys | Where-Object { -not $localRelPaths.Contains($_) })
        foreach ($rel in $extraRemote) { $mismatchDetails.Add("present on remote only: $rel") }

        $detail = "$mismatches mismatched/missing locally-pushed file(s); remote has $($clonedFiles.Count), local has $($localTemplateFiles.Count)"
        if ($mismatchDetails.Count -gt 0) {
            $detail += "`n" + (($mismatchDetails | ForEach-Object { "      - $_" }) -join "`n")
        }
        Check "All $($localTemplateFiles.Count) template file(s) verified byte-identical on the remote" `
            ($mismatches -eq 0 -and $clonedFiles.Count -eq $localTemplateFiles.Count -and $extraRemote.Count -eq 0) `
            $detail
    }
    if ($script:Failed -gt 0) {
        throw "Push verification failed; refusing to delete anything from the tenant. See the FAIL lines above. Fix the push, then re-run - nothing has been deleted yet."
    }

    if ($StopBeforeDelete) {
        Write-Host ""
        Write-Host "-StopBeforeDelete: backup and push verified, stopping before delete/restore." -ForegroundColor Yellow
        Write-Host "Re-run without -StopBeforeDelete to continue with the delete+restore rehearsal." -ForegroundColor Yellow
        exit 0
    }

    # ---------------------------------------------------------------- Step 5
    Write-Host ""
    Write-Host "[5/7] About to permanently delete $($originalList.Count) script(s) from this tenant:" -ForegroundColor Yellow
    foreach ($s in $originalList) { Write-Host "  - $($s.DisplayName) ($($s.Id))" }
    Write-Host ""
    Write-Host "They will be restored immediately afterward from $remoteUrl." -ForegroundColor Yellow
    $confirmPhrase = 'DELETE-ALL-SCRIPTS'
    $typed = Read-Host "Type $confirmPhrase to continue, anything else to abort"
    if ($typed -ne $confirmPhrase) {
        Write-Host "Aborted - nothing was deleted. The JSON backups and pushed templates from steps 3-4 are still valid at $WorkPath and on the remote." -ForegroundColor Yellow
        exit 0
    }

    Write-Host "Deleting..." -ForegroundColor Cyan
    $deleteFailures = @()
    foreach ($s in $originalList) {
        try {
            Remove-WizardScript -Id $s.Id
        } catch {
            $deleteFailures += $s
            Write-Warning "Could not delete '$($s.DisplayName)' ($($s.Id)): $(Get-WizardErrorSummary -ErrorRecord $_)"
        }
    }
    $remaining = @(Get-MgBetaDeviceManagementScript -All -Property id, displayName)
    Check "All $($originalList.Count) script(s) deleted from the tenant" ($remaining.Count -eq 0) `
        "$($remaining.Count) still present$(if ($deleteFailures.Count -gt 0) { " ($($deleteFailures.Count) delete call(s) failed)" })"

    # ---------------------------------------------------------------- Step 6
    Write-Host "[6/7] Restoring from the remote via -SourceRepo (empty -Path)..." -ForegroundColor Cyan
    $restorePath = Join-Path $WorkPath 'restore'
    New-Item -ItemType Directory -Path $restorePath -Force | Out-Null
    $run = Invoke-Deploy -WizardArgs @('-Path', $restorePath, '-SourceRepo', $remoteUrl)
    Check 'Restore run exited 0' ($run.ExitCode -eq 0) $run.Output

    # ---------------------------------------------------------------- Step 7
    Write-Host "[7/7] Comparing every original against its restored copy..." -ForegroundColor Cyan
    $restoredList = @(Get-MgBetaDeviceManagementScript -All -Property id, displayName, enforceSignatureCheck, runAs32Bit, runAsAccount)
    $restoredByName = @{}
    foreach ($r in $restoredList) {
        # A real tenant can legitimately have two scripts sharing a display
        # name; only the first is matched, and that is reported so it can be
        # judged by eye rather than silently picked.
        if (-not $restoredByName.ContainsKey($r.DisplayName)) { $restoredByName[$r.DisplayName] = $r }
    }

    foreach ($original in ($originalById.Values | Sort-Object DisplayName)) {
        $name = [string]$original['DisplayName']
        $wasTemplated = $templatedDisplayNames.Contains($name)

        if (-not $wasTemplated) {
            $script:Notes += "SKIPPED (not templated - #notemplate or export failure, so a repo restore was never expected to bring it back): $name"
            $reportRows += [pscustomobject]@{ Name = $name; Result = 'SKIPPED (not templated)'; Detail = 'Excluded from template export - see step 3/4 warnings for why.' }
            continue
        }

        $restored = $restoredByName[$name]
        if (-not $restored) {
            Check "Restored: $name" $false 'templated and pushed, but no script with this display name exists after restore'
            $reportRows += [pscustomobject]@{ Name = $name; Result = 'FAIL'; Detail = 'Templated but missing after restore.' }
            continue
        }

        $originalBytes = [System.Convert]::FromBase64String([string]$original['ScriptContent'])
        $originalText = [System.Text.Encoding]::UTF8.GetString($originalBytes)
        $restoredFull = Get-MgBetaDeviceManagementScript -DeviceManagementScriptId $restored.Id -Property scriptContent
        $restoredBytes = Get-WizardScriptContentBytes -Content $restoredFull.ScriptContent
        $restoredText = if ($restoredBytes) { [System.Text.Encoding]::UTF8.GetString($restoredBytes) } else { '' }

        $hasHeader = $restoredText.Contains($script:WizardTemplateStartMarker) -and $restoredText.Contains($script:WizardTemplateEndMarker)
        $logicMatches = (Get-WizardLogicOnlyText -Text $originalText) -eq (Get-WizardLogicOnlyText -Text $restoredText)
        $propsMatch = ([bool]$original['EnforceSignatureCheck'] -eq [bool]$restored.EnforceSignatureCheck) -and
                      ([bool]$original['RunAs32Bit'] -eq [bool]$restored.RunAs32Bit) -and
                      ([string]$original['RunAsAccount'] -eq [string]$restored.RunAsAccount)

        $originalAssignmentKeys = Get-WizardAssignmentTargetKeys -Assignments @($original['Assignments'])
        $restoredAssignments = @(Get-WizardScriptAssignments -Id $restored.Id)
        $restoredAssignmentKeys = Get-WizardAssignmentTargetKeys -Assignments $restoredAssignments

        $assignmentsMatch = (@($restoredAssignmentKeys) -join ',') -eq (@($originalAssignmentKeys) -join ',')

        $detailParts = @()
        if (-not $hasHeader) { $detailParts += 'restored content is missing the wizard template header' }
        if (-not $logicMatches) { $detailParts += 'logic differs once comments are stripped' }
        if (-not $propsMatch) { $detailParts += "properties differ (EnforceSignatureCheck/RunAs32Bit/RunAsAccount): original scriptcheck=$($original['EnforceSignatureCheck']) 32bit=$($original['RunAs32Bit']) type=$($original['RunAsAccount']); restored scriptcheck=$($restored.EnforceSignatureCheck) 32bit=$($restored.RunAs32Bit) type=$($restored.RunAsAccount)" }
        if (-not $assignmentsMatch) { $detailParts += "assignments differ: expected {$($originalAssignmentKeys -join '; ')} got {$($restoredAssignmentKeys -join '; ')}" }

        $allOk = $hasHeader -and $logicMatches -and $propsMatch -and $assignmentsMatch
        Check "Restored: $name" $allOk ($detailParts -join '; ')
        $reportRows += [pscustomobject]@{
            Name   = $name
            Result = if ($allOk) { 'PASS' } else { 'FAIL' }
            Detail = if ($detailParts.Count -gt 0) { $detailParts -join '; ' } else { 'Content, properties and assignments all matched.' }
        }
    }
} finally {
    # No tenant cleanup here on purpose: unlike the throwaway e2e scripts,
    # the restored scripts here ARE real tenant content and are meant to be
    # the end state, not artifacts to tear down. WorkPath is also left in
    # place - it holds the only local copy of the pre-delete JSON backups.
    Disconnect-WizardGraph
}

# --------------------------------------------------------------------------
# Report
# --------------------------------------------------------------------------
$reportLines = @()
$reportLines += "# Tenant-wide repo backup/restore check"
$reportLines += ""
$reportLines += "Run at $((Get-Date).ToString('o'))."
$reportLines += ""
$reportLines += "Every script in the dev tenant was backed up (JSON + .ps1 template), the"
$reportLines += "template push to the remote repo was independently verified, every script"
$reportLines += "was deleted, and all of them were restored purely from the remote repo via"
$reportLines += "``-SourceRepo``. The table below compares each original against its restored"
$reportLines += "copy: content logic (comments/blank lines stripped from both sides),"
$reportLines += "``EnforceSignatureCheck``/``RunAs32Bit``/``RunAsAccount``, and assignments."
$reportLines += ""
$reportLines += "| Script | Result | Detail |"
$reportLines += "| --- | --- | --- |"
foreach ($row in $reportRows) {
    $escapedDetail = $row.Detail -replace '\|', '\|'
    $reportLines += "| $($row.Name) | $($row.Result) | $escapedDetail |"
}
$reportLines += ""
$reportLines += "$($script:Passed) check(s) passed, $($script:Failed) failed."
if ($script:Notes.Count -gt 0) {
    $reportLines += ""
    $reportLines += "## Notes"
    foreach ($n in $script:Notes) { $reportLines += "- $n" }
}
Set-Content -LiteralPath $ReportPath -Value ($reportLines -join "`n") -NoNewline
Write-Host ""
Write-Host "Report written to $ReportPath" -ForegroundColor Cyan

if ($script:Failed -gt 0) {
    Write-Host "$($script:Passed) passed, $($script:Failed) failed" -ForegroundColor Red
    exit 1
}
Write-Host "$($script:Passed) passed, 0 failed" -ForegroundColor Green
exit 0
