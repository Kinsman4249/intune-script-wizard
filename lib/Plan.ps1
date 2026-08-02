# Plan.ps1
# -SavePlan / -ApplyPlan: capturing exactly what a -DryRun decided, and
# replaying that later with a guarantee that what gets applied is what was
# reviewed - not a fresh recompute that happens to usually match.
#
# The guarantee comes from a signature: a hash of every local script's content
# and metadata plus every existing Intune script's id/content-hash/name, taken
# at plan-save time. -ApplyPlan recomputes the same signature from the current
# local files and a fresh read of the tenant, and refuses to apply unless it
# matches exactly. Because of that, the plan itself only needs to record the
# already-decided action per script (Create/Update/Skip/UpToDate, plus which
# existing script an Update targets) - duplicate/fuzzy-match resolution is
# never re-run at apply time, it is replayed from what was recorded.

$script:WizardPlanSchemaVersion = 1

# One line per script, in a fixed field order, so the same inputs always
# produce the same signature regardless of hashtable/array ordering.
function Get-WizardPlanSignature {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$LocalScripts,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$ExistingScripts
    )

    $localLines = $LocalScripts | Sort-Object Path | ForEach-Object {
        $includeIds = (@($_.IncludeGroupIds) | Sort-Object) -join ','
        $excludeIds = (@($_.ExcludeGroupIds) | Sort-Object) -join ','
        "L|$($_.Path)|$(Get-WizardFileHash -Path $_.Path)|$($_.DisplayName)|$($_.Type)|" +
        "$($_.RunAsAccount)|$($_.EnforceSignatureCheck)|$($_.RunAs32Bit)|$($_.NoAssignments)|" +
        "$includeIds|$excludeIds"
    }
    $existingLines = $ExistingScripts | Sort-Object Id | ForEach-Object {
        "E|$($_.Id)|$($_.ContentHash)|$($_.DisplayName)"
    }

    $combined = (@($localLines) + @($existingLines)) -join "`n"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($combined))
    } finally {
        $sha.Dispose()
    }
    return (($digest | ForEach-Object { $_.ToString('x2') }) -join '')
}

# Appends one action to $PlanActions (a List, or $null when the caller isn't
# recording a plan - every call site passes -PlanActions unconditionally and
# this is the no-op branch for a normal, non-recording run).
function Add-WizardPlanAction {
    param(
        [System.Collections.Generic.List[object]]$PlanActions,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][ValidateSet('Create', 'Update', 'Skip', 'UpToDate')][string]$Action,
        [string]$TargetId
    )
    # -not on a collection tests its Count, not whether it's $null - an empty
    # (about to be filled) List[object] would read as falsy and never get its
    # first item added. $null is the only "not recording a plan" signal.
    if ($null -eq $PlanActions) { return }
    $PlanActions.Add([pscustomobject]@{
        Path        = $Path
        DisplayName = $DisplayName
        Action      = $Action
        TargetId    = $TargetId
    })
}

function Save-WizardPlan {
    param(
        [Parameter(Mandatory)][string]$PlanFile,
        [Parameter(Mandatory)][string]$ResolvedPath,
        [Parameter(Mandatory)][string]$Signature,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Actions
    )

    $plan = [ordered]@{
        SchemaVersion = $script:WizardPlanSchemaVersion
        CreatedAt     = (Get-Date).ToString('o')
        Path          = $ResolvedPath
        Signature     = $Signature
        Actions       = @($Actions)
    }
    Save-WizardJsonFile -Path $PlanFile -Value $plan -Depth 6
    Write-Host "Plan saved to $PlanFile ($(@($Actions).Count) script(s)). Replay it later with -ApplyPlan '$PlanFile'." -ForegroundColor Cyan
}

# Reads back a plan file, rejecting anything that isn't recognisably one of
# ours - a stray JSON file here would otherwise be silently misread as an
# empty plan (no Actions) rather than failing loudly.
function Read-WizardPlan {
    param([Parameter(Mandatory)][string]$PlanFile)

    if (-not (Test-Path -LiteralPath $PlanFile -PathType Leaf)) {
        throw "-ApplyPlan file '$PlanFile' does not exist."
    }
    $data = $null
    try {
        $data = Read-WizardJsonFile -Path $PlanFile -AsHashtable
    } catch {
        throw "-ApplyPlan file '$PlanFile' is not valid JSON: $($_.Exception.Message)"
    }
    if (-not $data -or -not $data.ContainsKey('SchemaVersion') -or -not $data.ContainsKey('Signature') -or -not $data.ContainsKey('Actions')) {
        throw "-ApplyPlan file '$PlanFile' doesn't look like a wizard plan (missing SchemaVersion/Signature/Actions). Generate one with -DryRun -SavePlan."
    }
    if ($data['SchemaVersion'] -ne $script:WizardPlanSchemaVersion) {
        throw "-ApplyPlan file '$PlanFile' is schema version $($data['SchemaVersion']), this build expects $($script:WizardPlanSchemaVersion). Re-run -DryRun -SavePlan with this build to make a fresh plan."
    }
    return $data
}

# Throws with a clear reason if the current local scripts + tenant state no
# longer match what the plan was built from - this is the whole guarantee
# -ApplyPlan makes, so it refuses rather than guesses.
function Assert-WizardPlanSignatureMatches {
    param(
        [Parameter(Mandatory)][hashtable]$Plan,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$LocalScripts,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$ExistingScripts
    )

    $current = Get-WizardPlanSignature -LocalScripts $LocalScripts -ExistingScripts $ExistingScripts
    if ($current -ne $Plan['Signature']) {
        throw "-ApplyPlan refused: the local scripts and/or the tenant have changed since this plan was saved, so replaying it would not be the plan that was reviewed. Run -DryRun -SavePlan again to make a fresh one."
    }
}

# Writes a -DryRun's decided actions to a CSV, for a management-approval
# report outside the console - it opens straight into Excel. Not tied to
# -SavePlan: -ReportCsv can be used on its own, or together with it.
function Export-WizardPlanCsv {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Actions,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$LocalScripts,
        [Parameter(Mandatory)][string]$CsvFile
    )

    $metaByPath = @{}
    foreach ($m in $LocalScripts) { $metaByPath[$m.Path] = $m }

    $rows = foreach ($a in ($Actions | Sort-Object DisplayName)) {
        $meta = $metaByPath[$a.Path]
        [pscustomobject]@{
            DisplayName = $a.DisplayName
            Type        = if ($meta) { $meta.Type } else { '' }
            Action      = $a.Action
            Assignment  = if ($meta) { Get-WizardAssignmentSummary -Meta $meta } else { '' }
            ExistingId  = $a.TargetId
            Path        = $a.Path
        }
    }

    # A straight write, not the atomic temp-file dance Storage.ps1 uses for
    # the wizard's own state: this is a preview report, not tenant state, so
    # a failure part-way through has nothing that needs protecting.
    $rows | Export-Csv -LiteralPath $CsvFile -NoTypeInformation -ErrorAction Stop
    Write-Host "Approval report written to $CsvFile ($($rows.Count) script(s))." -ForegroundColor Cyan
}
