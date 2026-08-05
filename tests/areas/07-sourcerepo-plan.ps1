# --------------------------------------------------------------- SourceRepo
# -SourceRepo clones a real, local git repo (no network needed - a plain
# `git init`'d folder works as a clone source) and scans it the same way
# -Path itself is scanned, combined with -Path's own results.
function New-WizardGitSourceRepo {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][array]$Scripts)
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    foreach ($s in $Scripts) {
        $full = Join-Path $Root $s.Rel
        New-Item -ItemType Directory -Path (Split-Path $full) -Force | Out-Null
        Set-Content -LiteralPath $full -Value $s.Body -NoNewline
    }
    $env:GIT_AUTHOR_NAME = 'Wizard Test'; $env:GIT_AUTHOR_EMAIL = 'wizard-test@example.invalid'
    $env:GIT_COMMITTER_NAME = 'Wizard Test'; $env:GIT_COMMITTER_EMAIL = 'wizard-test@example.invalid'
    & git -C $Root init -q 2>&1 | Out-Null
    & git -C $Root add -A 2>&1 | Out-Null
    & git -C $Root commit -q -m 'seed' 2>&1 | Out-Null
}

$srcRepo = Join-Path $scratch 'source-repo'
New-WizardGitSourceRepo -Root $srcRepo -Scripts @(@{ Rel = 'device/Repo-Script.ps1'; Body = $bodyA })
$ws = New-Workspace -Scripts @()
$r = Invoke-Wizard -Workspace $ws -State @{ scripts = @() } -WizardArgs @('-SourceRepo', $srcRepo)
$created = @($r.Calls | Where-Object { $_['call'] -eq 'New-MgBetaDeviceManagementScript' })
Check '-SourceRepo clones and deploys a script' ($created.Count -eq 1) "got $($created.Count): $($r.Output)"
Check '-SourceRepo leaves a cache clone under .repo-sources' (Test-Path -LiteralPath (Join-Path $ws '.repo-sources')) 'no .repo-sources dir'

# A repo with a subpath scans only that folder, and combines with -Path's own
# scripts. 'Local-Script'/'Sub-Script' are similar enough to fuzzy-match each
# other once one exists, so -OnFuzzyMatch SideBySide avoids the prompt.
$srcRepo2 = Join-Path $scratch 'source-repo-sub'
New-WizardGitSourceRepo -Root $srcRepo2 -Scripts @(
    @{ Rel = 'platform/win11/device/Sub-Script.ps1'; Body = $bodyA }
    @{ Rel = 'device/Not-Scanned.ps1'; Body = $bodyB }
)
$ws2 = New-Workspace -Scripts @(@{ Rel = 'user/Local-Script.ps1'; Body = $bodyB })
$r2 = Invoke-Wizard -Workspace $ws2 -State @{ scripts = @() } `
    -WizardArgs @('-SourceRepo', "${srcRepo2}::platform/win11", '-OnFuzzyMatch', 'SideBySide')
$created2 = @($r2.Calls | Where-Object { $_['call'] -eq 'New-MgBetaDeviceManagementScript' })
$names2 = @($created2 | ForEach-Object { $_['data']['displayName'] }) | Sort-Object
Check '-SourceRepo subpath scans only that folder, plus local' (($names2 -join ',') -eq 'Local-Script,Sub-Script') "got $($names2 -join ','): $($r2.Output)"

# A subpath that doesn't exist in the repo must fail the run, not silently scan nothing.
$r3 = Invoke-Wizard -Workspace (New-Workspace -Scripts @()) -State @{ scripts = @() } `
    -WizardArgs @('-SourceRepo', "${srcRepo}::no-such-subpath")
Check '-SourceRepo missing subpath fails the run' ($r3.ExitCode -ne 0) "got $($r3.ExitCode)"
Check '-SourceRepo missing subpath names the problem' ($r3.Output -match 'does not exist in this repo') $r3.Output

# --------------------------------------------------------------- Plan (SavePlan / ApplyPlan / ReportCsv)
# -DryRun -SavePlan records exactly what would happen; -ApplyPlan later
# replays it as the real deploy, guarded by a signature over the local
# scripts and tenant state at save time.
$planWs = New-Workspace -Scripts @(
    @{ Rel = 'device/Plan-Update.ps1'; Body = "$bodyA# v2`n" }
    @{ Rel = 'user/Plan-Create.ps1';   Body = $bodyB }
)
$planState = @{ scripts = @((New-TenantScript -Id 'plan-existing-1' -Name 'Plan-Update' -Body $bodyA)) }
$planFile = Join-Path $scratch 'plan.json'

$rPlan = Invoke-Wizard -Workspace $planWs -State $planState -WizardArgs @('-DryRun', '-SavePlan', $planFile)
Check '-SavePlan exits 0' ($rPlan.ExitCode -eq 0) "got $($rPlan.ExitCode)`n$($rPlan.Output)"
Check '-SavePlan writes a plan file' (Test-Path -LiteralPath $planFile) 'no plan file written'
$planMut = @($rPlan.Calls | Where-Object { $_['call'] -in @('New-MgBetaDeviceManagementScript', 'Update-MgBetaDeviceManagementScript') })
Check '-SavePlan (still a dry run) makes no mutating calls' ($planMut.Count -eq 0) "got $($planMut.Count)"

$savedPlan = Get-Content -LiteralPath $planFile -Raw | ConvertFrom-Json -AsHashtable
$planActionsByName = @{}
foreach ($a in $savedPlan['Actions']) { $planActionsByName[$a['DisplayName']] = $a }
Check '-SavePlan recorded the create' ($planActionsByName['Plan-Create']['Action'] -eq 'Create') "got $($planActionsByName['Plan-Create']['Action'])"
Check '-SavePlan recorded the update' ($planActionsByName['Plan-Update']['Action'] -eq 'Update') "got $($planActionsByName['Plan-Update']['Action'])"
Check '-SavePlan recorded the update target id' ($planActionsByName['Plan-Update']['TargetId'] -eq 'plan-existing-1') "got $($planActionsByName['Plan-Update']['TargetId'])"

# Applying against the exact same local/tenant state must replay cleanly.
$rApply = Invoke-Wizard -Workspace $planWs -State $planState -WizardArgs @('-ApplyPlan', $planFile)
Check '-ApplyPlan exits 0' ($rApply.ExitCode -eq 0) "got $($rApply.ExitCode)`n$($rApply.Output)"
$applyCreated = @($rApply.Calls | Where-Object { $_['call'] -eq 'New-MgBetaDeviceManagementScript' })
$applyUpdated = @($rApply.Calls | Where-Object { $_['call'] -eq 'Update-MgBetaDeviceManagementScript' })
Check '-ApplyPlan created the planned script'  ($applyCreated.Count -eq 1) "got $($applyCreated.Count)"
Check '-ApplyPlan updated the planned script'  ($applyUpdated.Count -eq 1) "got $($applyUpdated.Count)"
Check '-ApplyPlan did not prompt for fuzzy match' (-not ($rApply.Output -match 'Skip.*Replace.*side-by-side')) $rApply.Output

# A plan applied against a tenant/local state that has since drifted must be
# refused outright, not silently recomputed.
$driftWs = New-Workspace -Scripts @(
    @{ Rel = 'device/Plan-Update.ps1'; Body = "$bodyA# v2 changed again`n" }
    @{ Rel = 'user/Plan-Create.ps1';   Body = $bodyB }
)
$rDrift = Invoke-Wizard -Workspace $driftWs -State $planState -WizardArgs @('-ApplyPlan', $planFile)
Check '-ApplyPlan refuses on a changed local file' ($rDrift.ExitCode -ne 0) "got $($rDrift.ExitCode)"
Check '-ApplyPlan refusal names the reason' ($rDrift.Output -match 'refused') $rDrift.Output
$driftMut = @($rDrift.Calls | Where-Object { $_['call'] -in @('New-MgBetaDeviceManagementScript', 'Update-MgBetaDeviceManagementScript') })
Check '-ApplyPlan refusal makes no mutating calls' ($driftMut.Count -eq 0) "got $($driftMut.Count)"

# -SavePlan needs -DryRun; -ApplyPlan rejects the flags that would conflict
# with a plan already carrying its own decisions.
$r = Invoke-Wizard -Workspace (New-Workspace -Scripts @()) -State @{ scripts = @() } -WizardArgs @('-SavePlan', $planFile)
Check '-SavePlan without -DryRun is refused' ($r.Output -match "SavePlan needs -DryRun") $r.Output
$r = Invoke-Wizard -Workspace (New-Workspace -Scripts @()) -State @{ scripts = @() } -WizardArgs @('-ApplyPlan', $planFile, '-DryRun')
Check '-ApplyPlan with -DryRun is refused' ($r.Output -match 'cannot be combined with -DryRun') $r.Output
$r = Invoke-Wizard -Workspace (New-Workspace -Scripts @()) -State @{ scripts = @() } -WizardArgs @('-ApplyPlan', $planFile, '-OnFuzzyMatch', 'Skip')
Check '-ApplyPlan with -OnFuzzyMatch is refused' ($r.Output -match 'has no effect with -ApplyPlan') $r.Output

# -ReportCsv writes the same decided actions to CSV, for a management-approval report.
$csvWs = New-Workspace -Scripts @(
    @{ Rel = 'device/Csv-Update.ps1'; Body = "$bodyA# v2`n" }
    @{ Rel = 'user/Csv-Create.ps1';   Body = $bodyB }
)
$csvState = @{ scripts = @((New-TenantScript -Id 'csv-existing-1' -Name 'Csv-Update' -Body $bodyA)) }
$csvFile = Join-Path $scratch 'report.csv'
$rCsv = Invoke-Wizard -Workspace $csvWs -State $csvState -WizardArgs @('-DryRun', '-ReportCsv', $csvFile)
Check '-ReportCsv exits 0' ($rCsv.ExitCode -eq 0) "got $($rCsv.ExitCode)`n$($rCsv.Output)"
Check '-ReportCsv writes a csv file' (Test-Path -LiteralPath $csvFile) 'no csv file written'
$csvRows = Import-Csv -LiteralPath $csvFile
Check '-ReportCsv has one row per script' ($csvRows.Count -eq 2) "got $($csvRows.Count)"
$csvByName = @{}
foreach ($row in $csvRows) { $csvByName[$row.DisplayName] = $row }
Check '-ReportCsv row action for the create' ($csvByName['Csv-Create'].Action -eq 'Create') "got $($csvByName['Csv-Create'].Action)"
Check '-ReportCsv row action for the update' ($csvByName['Csv-Update'].Action -eq 'Update') "got $($csvByName['Csv-Update'].Action)"
Check '-ReportCsv row carries the assignment target' (-not [string]::IsNullOrWhiteSpace($csvByName['Csv-Create'].Assignment)) 'Assignment column was blank'

$r = Invoke-Wizard -Workspace (New-Workspace -Scripts @()) -State @{ scripts = @() } -WizardArgs @('-ReportCsv', $csvFile)
Check '-ReportCsv without -DryRun is refused' ($r.Output -match "ReportCsv needs -DryRun") $r.Output
