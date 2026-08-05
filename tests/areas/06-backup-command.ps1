# --------------------------------------------------------------- Test 40
# -Backup snapshots one existing script by name, with no local scan or Graph
# write - a plain workspace with no user/device folders is enough to prove it.
$ws = New-Workspace -Scripts @()
$state = @{ scripts = @(
    (New-TenantScript -Id 'backup-1' -Name 'Payroll Script' -Body $bodyA)
    (New-TenantScript -Id 'backup-2' -Name 'Other Script'   -Body $bodyB)
) }
$r = Invoke-Wizard -Workspace $ws -State $state -WizardArgs @('-Backup', 'Payroll Script')
$backupFiles = @(Get-ChildItem -LiteralPath (Join-Path $ws 'backups') -Filter '*.json' -ErrorAction SilentlyContinue)
Check '-Backup by name exits 0'          ($r.ExitCode -eq 0) "got $($r.ExitCode)`n$($r.Output)"
Check '-Backup by name wrote one file'   ($backupFiles.Count -eq 1) "got $($backupFiles.Count)"
$backedUp = Get-Content -LiteralPath $backupFiles[0].FullName -Raw | ConvertFrom-Json -AsHashtable
Check '-Backup by name backed up the right script' ($backedUp['Id'] -eq 'backup-1') "got $($backedUp['Id'])"
Check '-Backup made no create/update call' (@($r.Calls | Where-Object { $_['call'] -in @('New-MgBetaDeviceManagementScript', 'Update-MgBetaDeviceManagementScript') }).Count -eq 0) 'a write call was made'

# -Backup by Id takes the same path. Needs a GUID-shaped Id: that is what
# tells Resolve-WizardBackupTargets to match on Id rather than display name.
$guidState = @{ scripts = @((New-TenantScript -Id 'aaaaaaaa-1111-2222-3333-444444444444' -Name 'Guid Script' -Body $bodyA)) }
$ws = New-Workspace -Scripts @()
$r = Invoke-Wizard -Workspace $ws -State $guidState -WizardArgs @('-Backup', 'aaaaaaaa-1111-2222-3333-444444444444')
$backupFiles = @(Get-ChildItem -LiteralPath (Join-Path $ws 'backups') -Filter '*.json' -ErrorAction SilentlyContinue)
Check '-Backup by Id exits 0'        ($r.ExitCode -eq 0) "got $($r.ExitCode)`n$($r.Output)"
Check '-Backup by Id wrote one file' ($backupFiles.Count -eq 1) "got $($backupFiles.Count)"
$backedUp = Get-Content -LiteralPath $backupFiles[0].FullName -Raw | ConvertFrom-Json -AsHashtable
Check '-Backup by Id backed up the right script' ($backedUp['Id'] -eq 'aaaaaaaa-1111-2222-3333-444444444444') "got $($backedUp['Id'])"

# --------------------------------------------------------------- Test 41
# -BackupAll snapshots every script in the tenant in one run.
$ws = New-Workspace -Scripts @()
$r = Invoke-Wizard -Workspace $ws -State $state -WizardArgs @('-BackupAll')
$backupFiles = @(Get-ChildItem -LiteralPath (Join-Path $ws 'backups') -Filter '*.json' -ErrorAction SilentlyContinue)
Check '-BackupAll exits 0'            ($r.ExitCode -eq 0) "got $($r.ExitCode)`n$($r.Output)"
Check '-BackupAll backed up both'     ($backupFiles.Count -eq 2) "got $($backupFiles.Count)"

# --------------------------------------------------------------- Test 42
# -Backup usage errors: unknown name, ambiguous name, mutually exclusive flags.
$r = Invoke-Wizard -Workspace $ws -State $state -WizardArgs @('-Backup', 'No Such Script')
Check '-Backup unknown name fails'   ($r.ExitCode -eq 1) "got $($r.ExitCode)"
Check '-Backup unknown name says so' ($r.Output -match 'No script named') $r.Output

$dupeState = @{ scripts = @(
    (New-TenantScript -Id 'dupe-a' -Name 'Same Name' -Body $bodyA)
    (New-TenantScript -Id 'dupe-b' -Name 'Same Name' -Body $bodyB)
) }
$r = Invoke-Wizard -Workspace $ws -State $dupeState -WizardArgs @('-Backup', 'Same Name')
Check '-Backup ambiguous name fails'   ($r.ExitCode -eq 1) "got $($r.ExitCode)"
Check '-Backup ambiguous name says so' ($r.Output -match 'is ambiguous') $r.Output

$r = Invoke-Wizard -Workspace $ws -State @{ scripts = @() } -WizardArgs @('-Backup', 'X', '-BackupAll')
Check '-Backup with -BackupAll is refused' ($r.Output -match 'mutually exclusive') $r.Output
Check '-Backup with -BackupAll exits 1'    ($r.ExitCode -eq 1) "got $($r.ExitCode)"

$r = Invoke-Wizard -Workspace $ws -State @{ scripts = @() } -WizardArgs @('-BackupAll', '-Restore', 'anything.json')
Check '-BackupAll with -Restore is refused' ($r.Output -match 'cannot be combined with -Restore') $r.Output
Check '-BackupAll with -Restore exits 1'    ($r.ExitCode -eq 1) "got $($r.ExitCode)"

# -DryRun with -Backup lists the target and writes nothing.
$ws = New-Workspace -Scripts @()
$r = Invoke-Wizard -Workspace $ws -State $state -WizardArgs @('-Backup', 'Payroll Script', '-DryRun')
$backupFiles = @(Get-ChildItem -LiteralPath (Join-Path $ws 'backups') -Filter '*.json' -ErrorAction SilentlyContinue)
Check '-DryRun with -Backup exits 0'       ($r.ExitCode -eq 0) "got $($r.ExitCode)`n$($r.Output)"
Check '-DryRun with -Backup writes nothing' ($backupFiles.Count -eq 0) "got $($backupFiles.Count)"
Check '-DryRun with -Backup names the target' ($r.Output -match '(?s)Would back up.*Payroll Script') $r.Output
