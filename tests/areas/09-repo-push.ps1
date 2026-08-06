# --------------------------------------------------------------- Test 43
# Repo backup: pushing local backups/ to a remote git repo. Each scenario
# runs in its own pwsh subprocess with $env:HOME pointed at a scratch
# folder - same isolation Invoke-Wizard gives _state.json - because
# Get-WizardRepoBackupConfigPath reads the real $HOME, and these tests must
# never read or write the actual user's own repo-backup-config.json.
$originalEnvHome = $env:HOME
$repoBackupHarness = Join-Path $scratch 'repo-backup-harness.ps1'
@'
$ErrorActionPreference = "Stop"
. (Join-Path $env:WIZTEST_REPO "lib/Logging.ps1")
. (Join-Path $env:WIZTEST_REPO "lib/Storage.ps1")
. (Join-Path $env:WIZTEST_REPO "lib/Prereqs.ps1")
. (Join-Path $env:WIZTEST_REPO "lib/RepoBackup.ps1")
. (Join-Path $env:WIZTEST_REPO "lib/RepoBackupSubpath.ps1")

$rbKind = if ($env:WIZTEST_RBKIND) { $env:WIZTEST_RBKIND } else { "Backups" }
switch ($env:WIZTEST_RBACTION) {
    "get-config" {
        $c = Get-WizardRepoBackupConfig -Kind $rbKind
        if ($null -eq $c) { Write-Output "null" } else { $c | ConvertTo-Json -Depth 5 -Compress | Write-Output }
    }
    "save-config" {
        $cfg = $env:WIZTEST_RBCONFIG | ConvertFrom-Json -AsHashtable
        Save-WizardRepoBackupConfig -Kind $rbKind -Config $cfg
    }
    "push" {
        Push-WizardBackupsToRepo -BackupDir $env:WIZTEST_BACKUPDIR -Kind $rbKind
    }
}
'@ | Set-Content -LiteralPath $repoBackupHarness

function Invoke-RepoBackupHarness {
    param([string]$Action, [string]$HomeDir, [string]$BackupDir, [hashtable]$Config, [string]$Kind = 'Backups')
    $env:WIZTEST_REPO      = $repo
    $env:WIZTEST_RBACTION  = $Action
    $env:WIZTEST_BACKUPDIR = $BackupDir
    $env:WIZTEST_RBCONFIG  = if ($Config) { $Config | ConvertTo-Json -Depth 5 -Compress } else { '' }
    $env:WIZTEST_RBKIND    = $Kind
    $env:HOME              = $HomeDir
    # Fixed identity so a commit made during -Action push never depends on
    # this machine having git user.name/user.email configured globally.
    $env:GIT_AUTHOR_NAME     = 'Wizard Test'
    $env:GIT_AUTHOR_EMAIL    = 'wizard-test@example.invalid'
    $env:GIT_COMMITTER_NAME  = 'Wizard Test'
    $env:GIT_COMMITTER_EMAIL = 'wizard-test@example.invalid'
    $out = & pwsh -NoProfile -File $repoBackupHarness 2>&1
    $exit = $LASTEXITCODE
    return [pscustomobject]@{ Output = ($out | Out-String); ExitCode = $exit }
}

# Test-WizardCommandAvailable: true for a real command, false for a bogus one.
. (Join-Path $repo 'lib/Prereqs.ps1')
Check 'Test-WizardCommandAvailable: git is found' (Test-WizardCommandAvailable -Name 'git') 'git not found on PATH'
Check 'Test-WizardCommandAvailable: bogus command is not found' `
    (-not (Test-WizardCommandAvailable -Name 'this-command-does-not-exist-xyz')) 'bogus command reported as found'

# No config file yet: Get-WizardRepoBackupConfig must read as "unconfigured",
# not as an empty/default config, so Push-WizardBackupsToRepo knows to offer
# first-run setup rather than silently doing nothing forever.
$rbHomeEmpty = Join-Path $scratch 'rbhome-empty'
New-Item -ItemType Directory -Path $rbHomeEmpty -Force | Out-Null
$r = Invoke-RepoBackupHarness -Action 'get-config' -HomeDir $rbHomeEmpty
Check 'Repo backup config: unset reads as null' ($r.Output.Trim() -eq 'null') $r.Output

# A declined choice round-trips and is what Push-WizardBackupsToRepo checks
# to never ask again.
$rbHomeDeclined = Join-Path $scratch 'rbhome-declined'
New-Item -ItemType Directory -Path $rbHomeDeclined -Force | Out-Null
Invoke-RepoBackupHarness -Action 'save-config' -HomeDir $rbHomeDeclined -Config @{ Declined = $true; ConfiguredAt = '2026-01-01T00:00:00Z' } | Out-Null
$r = Invoke-RepoBackupHarness -Action 'get-config' -HomeDir $rbHomeDeclined
$parsedConfig = $r.Output.Trim() | ConvertFrom-Json
Check 'Repo backup config: declined round-trips' ($parsedConfig.Declined -eq $true) $r.Output

# Push-WizardBackupsToRepo with nothing configured, in a non-interactive
# session (this harness always is - see [Console]::IsInputRedirected),
# must no-op cleanly rather than hang on a prompt or fail the run.
$bkNoConfig = Join-Path $scratch 'nopush-backups'
New-Item -ItemType Directory -Path $bkNoConfig -Force | Out-Null
Set-Content -LiteralPath (Join-Path $bkNoConfig 'x.json') -Value '{}'
$r = Invoke-RepoBackupHarness -Action 'push' -HomeDir $rbHomeEmpty -BackupDir $bkNoConfig
Check 'Push: no-ops with nothing configured' ($r.ExitCode -eq 0) "exit $($r.ExitCode)`n$($r.Output)"
Check 'Push: no-ops does not turn backups/ into a repo' (-not (Test-Path (Join-Path $bkNoConfig '.git'))) 'a .git folder was created'

# Push-WizardBackupsToRepo with a declined config must also no-op, and must
# not re-prompt or re-save anything.
$r = Invoke-RepoBackupHarness -Action 'push' -HomeDir $rbHomeDeclined -BackupDir $bkNoConfig
Check 'Push: no-ops when declined' ($r.ExitCode -eq 0) "exit $($r.ExitCode)`n$($r.Output)"
Check 'Push: declined does not touch backups/' (-not (Test-Path (Join-Path $bkNoConfig '.git'))) 'a .git folder was created'

# End-to-end: a real local bare repo stands in for GitHub/Azure DevOps, so
# this proves the actual git init/add/commit/push mechanics work without
# needing real remote credentials.
$bareRepo = Join-Path $scratch 'bare-repo.git'
& git init --bare -q $bareRepo
$rbHomePush = Join-Path $scratch 'rbhome-push'
New-Item -ItemType Directory -Path $rbHomePush -Force | Out-Null
Invoke-RepoBackupHarness -Action 'save-config' -HomeDir $rbHomePush `
    -Config @{ Provider = 'git'; RemoteUrl = $bareRepo; Declined = $false } | Out-Null

$bkPush = Join-Path $scratch 'push-backups'
New-Item -ItemType Directory -Path $bkPush -Force | Out-Null
Set-Content -LiteralPath (Join-Path $bkPush 'script-1.json') -Value '{"Id":"1"}'
$r = Invoke-RepoBackupHarness -Action 'push' -HomeDir $rbHomePush -BackupDir $bkPush
Check 'Push: end-to-end push succeeds' ($r.ExitCode -eq 0) "exit $($r.ExitCode)`n$($r.Output)"

$pushedCommit = (& git --git-dir=$bareRepo rev-list --all -n 1 2>$null | Out-String).Trim()
Check 'Push: a commit landed in the bare repo' (-not [string]::IsNullOrWhiteSpace($pushedCommit)) 'no commit found in the bare repo'
$pushedFiles = & git --git-dir=$bareRepo ls-tree -r --name-only $pushedCommit 2>$null
Check 'Push: the backup file is in that commit' ($pushedFiles -contains 'script-1.json') "files: $pushedFiles"

# A second push with nothing new to commit must stay a clean no-op, not an error.
$r2 = Invoke-RepoBackupHarness -Action 'push' -HomeDir $rbHomePush -BackupDir $bkPush
Check 'Push: a second push with no changes is a clean no-op' ($r2.ExitCode -eq 0) "exit $($r2.ExitCode)`n$($r2.Output)"
$commitCountAfter = @(& git --git-dir=$bareRepo rev-list --all 2>$null).Count
Check 'Push: no-op push adds no extra commit' ($commitCountAfter -eq 1) "got $commitCountAfter commit(s)"

# -Kind Templates is a second, independent config file - proven by reusing
# every check above verbatim with -Kind Backups (the default), so nothing
# above this point changed behaviour. These few add the second target.
$rbHomeTpl = Join-Path $scratch 'rbhome-templates'
New-Item -ItemType Directory -Path $rbHomeTpl -Force | Out-Null
$r = Invoke-RepoBackupHarness -Action 'get-config' -HomeDir $rbHomeTpl -Kind 'Templates'
Check 'Repo backup config: Templates unset reads as null' ($r.Output.Trim() -eq 'null') $r.Output

Invoke-RepoBackupHarness -Action 'save-config' -HomeDir $rbHomeTpl -Kind 'Templates' `
    -Config @{ Provider = 'git'; RemoteUrl = $bareRepo; Declined = $false } | Out-Null
$configPath = Join-Path $rbHomeTpl '.intune-script-wizard/repo-template-config.json'
Check 'Repo backup config: Templates lands in repo-template-config.json' (Test-Path -LiteralPath $configPath) "expected $configPath"
$backupsConfigPath = Join-Path $rbHomeTpl '.intune-script-wizard/repo-backup-config.json'
Check 'Repo backup config: Templates config is independent of Backups config' (-not (Test-Path -LiteralPath $backupsConfigPath)) 'saving Templates also wrote a Backups config'

# A Backups-only home (from earlier in this test) must read Templates as
# still unconfigured - the two configs never leak into each other.
$r = Invoke-RepoBackupHarness -Action 'get-config' -HomeDir $rbHomePush -Kind 'Templates'
Check 'Repo backup config: a Backups-only home reads Templates as null' ($r.Output.Trim() -eq 'null') $r.Output

# End-to-end push of Templates uses the same bare repo, but must produce a
# commit prefixed 'Templates', not 'Backup'.
$tplPushDir = Join-Path $scratch 'push-templates'
New-Item -ItemType Directory -Path $tplPushDir -Force | Out-Null
Set-Content -LiteralPath (Join-Path $tplPushDir 'template-1.ps1') -Value '# a template'
$bareRepo2 = Join-Path $scratch 'bare-repo-templates.git'
& git init --bare -q $bareRepo2
Invoke-RepoBackupHarness -Action 'save-config' -HomeDir $rbHomeTpl -Kind 'Templates' `
    -Config @{ Provider = 'git'; RemoteUrl = $bareRepo2; Declined = $false } | Out-Null
$r = Invoke-RepoBackupHarness -Action 'push' -HomeDir $rbHomeTpl -BackupDir $tplPushDir -Kind 'Templates'
Check 'Push: Templates end-to-end push succeeds' ($r.ExitCode -eq 0) "exit $($r.ExitCode)`n$($r.Output)"
$tplPushedCommit = (& git --git-dir=$bareRepo2 rev-list --all -n 1 2>$null | Out-String).Trim()
Check 'Push: Templates commit landed in the bare repo' (-not [string]::IsNullOrWhiteSpace($tplPushedCommit)) 'no commit found in the bare repo'
$tplCommitMessage = (& git --git-dir=$bareRepo2 log -1 --format=%s $tplPushedCommit 2>$null | Out-String).Trim()
Check 'Push: Templates commit uses the Templates prefix' ($tplCommitMessage -match '^Templates') "got '$tplCommitMessage'"

# ---- '::subpath' push: confined to one folder of an existing repo --------
# A bare repo standing in for a shared repo that already has unrelated
# content on its default branch, plus a branch ('dev') that doesn't exist
# yet - proving both that a subpath push leaves siblings untouched and that
# it can create the target branch on first push.
$bareRepo3 = Join-Path $scratch 'bare-repo-subpath.git'
& git init --bare -q $bareRepo3
$seedClone = Join-Path $scratch 'seed-clone'
& git clone -q $bareRepo3 $seedClone 2>$null
New-Item -ItemType Directory -Path (Join-Path $seedClone 'Scripts/OtherProject') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $seedClone 'Scripts/OtherProject/keep.txt') -Value 'pre-existing content'
& git -C $seedClone add -A
& git -C $seedClone -c user.name='Wizard Test' -c user.email='wizard-test@example.invalid' commit -q -m 'Seed'
& git -C $seedClone push -q origin HEAD:main 2>$null
# 'git init --bare' leaves HEAD pointing at whatever init.defaultBranch is,
# which was never actually pushed above (we always push to 'main'
# explicitly regardless of the seed clone's own local branch name) - fix it
# up so a branch-less clone below resolves to 'main' instead of an unborn ref.
& git --git-dir=$bareRepo3 symbolic-ref HEAD refs/heads/main

$rbHomeSubpath = Join-Path $scratch 'rbhome-subpath'
New-Item -ItemType Directory -Path $rbHomeSubpath -Force | Out-Null
Invoke-RepoBackupHarness -Action 'save-config' -HomeDir $rbHomeSubpath `
    -Config @{ Provider = 'git'; RemoteUrl = $bareRepo3; Ref = 'dev'; Subpath = 'Scripts/Intune'; Declined = $false } | Out-Null

$bkSubpath = Join-Path $scratch 'push-subpath'
New-Item -ItemType Directory -Path $bkSubpath -Force | Out-Null
Set-Content -LiteralPath (Join-Path $bkSubpath 'script-1.json') -Value '{"Id":"1"}'
$r = Invoke-RepoBackupHarness -Action 'push' -HomeDir $rbHomeSubpath -BackupDir $bkSubpath
Check 'Subpath push: end-to-end push succeeds' ($r.ExitCode -eq 0) "exit $($r.ExitCode)`n$($r.Output)"

$devBranches = @(& git --git-dir=$bareRepo3 branch --list 'dev')
Check 'Subpath push: creates the branch when it did not exist yet' ($devBranches.Count -gt 0) 'no dev branch found'

$devFiles = & git --git-dir=$bareRepo3 ls-tree -r --name-only dev 2>$null
Check 'Subpath push: file lands under the configured subpath' ($devFiles -contains 'Scripts/Intune/script-1.json') "files: $devFiles"
Check 'Subpath push: sibling content forked from the default branch survives' ($devFiles -contains 'Scripts/OtherProject/keep.txt') "files: $devFiles"

$mainFiles = & git --git-dir=$bareRepo3 ls-tree -r --name-only main 2>$null
Check 'Subpath push: default branch is untouched by a push to dev' (-not ($mainFiles -contains 'Scripts/Intune/script-1.json')) "files: $mainFiles"

# A second push to the now-existing 'dev' branch must update only the
# subpath - the sibling folder from the seed commit must still be there.
Set-Content -LiteralPath (Join-Path $bkSubpath 'script-2.json') -Value '{"Id":"2"}'
$r2 = Invoke-RepoBackupHarness -Action 'push' -HomeDir $rbHomeSubpath -BackupDir $bkSubpath
Check 'Subpath push: second push to an existing branch succeeds' ($r2.ExitCode -eq 0) "exit $($r2.ExitCode)`n$($r2.Output)"
$devFiles2 = & git --git-dir=$bareRepo3 ls-tree -r --name-only dev 2>$null
Check 'Subpath push: second push adds the new file under the subpath' ($devFiles2 -contains 'Scripts/Intune/script-2.json') "files: $devFiles2"
Check 'Subpath push: second push still leaves the sibling folder alone' ($devFiles2 -contains 'Scripts/OtherProject/keep.txt') "files: $devFiles2"

# ---- '::subpath' push: pre-existing content INSIDE the subpath survives --
# Regression test for a real incident: the subpath sync used to delete the
# whole configured folder and replace it wholesale, wiping out a placeholder
# file that was already sitting there before the wizard ever pushed to it.
# It must now leave anything it didn't itself write alone by default.
$bareRepo4 = Join-Path $scratch 'bare-repo-subpath-placeholder.git'
& git init --bare -q $bareRepo4
$seedClone2 = Join-Path $scratch 'seed-clone-2'
& git clone -q $bareRepo4 $seedClone2 2>$null
New-Item -ItemType Directory -Path (Join-Path $seedClone2 'Scripts/Intune') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $seedClone2 'Scripts/Intune/placeholder.txt') -Value 'do not delete me'
Set-Content -LiteralPath (Join-Path $seedClone2 'Scripts/Intune/script-1.json') -Value '{"Id":"pre-existing"}'
& git -C $seedClone2 add -A
& git -C $seedClone2 -c user.name='Wizard Test' -c user.email='wizard-test@example.invalid' commit -q -m 'Seed'
& git -C $seedClone2 push -q origin HEAD:main 2>$null
& git --git-dir=$bareRepo4 symbolic-ref HEAD refs/heads/main

$rbHomeSubpath2 = Join-Path $scratch 'rbhome-subpath-placeholder'
New-Item -ItemType Directory -Path $rbHomeSubpath2 -Force | Out-Null
Invoke-RepoBackupHarness -Action 'save-config' -HomeDir $rbHomeSubpath2 `
    -Config @{ Provider = 'git'; RemoteUrl = $bareRepo4; Subpath = 'Scripts/Intune'; Declined = $false } | Out-Null

# The wizard's own local backups/ never had 'placeholder.txt' and pushes a
# same-named-but-different 'script-1.json' - the placeholder is unrelated
# content, script-1.json is a same-path conflict. Non-interactive, so the
# safe default (leave it alone) applies to both without a prompt.
$bkSubpath2 = Join-Path $scratch 'push-subpath-placeholder'
New-Item -ItemType Directory -Path $bkSubpath2 -Force | Out-Null
Set-Content -LiteralPath (Join-Path $bkSubpath2 'script-1.json') -Value '{"Id":"new-from-wizard"}'
Set-Content -LiteralPath (Join-Path $bkSubpath2 'script-2.json') -Value '{"Id":"2"}'
$r3 = Invoke-RepoBackupHarness -Action 'push' -HomeDir $rbHomeSubpath2 -BackupDir $bkSubpath2
Check 'Subpath push: does not fail when the subpath already has content' ($r3.ExitCode -eq 0) "exit $($r3.ExitCode)`n$($r3.Output)"

$devFiles3 = & git --git-dir=$bareRepo4 ls-tree -r --name-only main 2>$null
Check 'Subpath push: pre-existing placeholder file survives' ($devFiles3 -contains 'Scripts/Intune/placeholder.txt') "files: $devFiles3"
Check 'Subpath push: new, non-conflicting file is added' ($devFiles3 -contains 'Scripts/Intune/script-2.json') "files: $devFiles3"

$placeholderContent = (& git --git-dir=$bareRepo4 show "main:Scripts/Intune/placeholder.txt" 2>$null | Out-String).Trim()
Check 'Subpath push: placeholder content is untouched' ($placeholderContent -eq 'do not delete me') "got '$placeholderContent'"

# Non-interactive default for a same-path conflict is "leave it" - the
# wizard's own new content must NOT have silently overwritten it.
$conflictContent = (& git --git-dir=$bareRepo4 show "main:Scripts/Intune/script-1.json" 2>$null | Out-String).Trim()
Check 'Subpath push: same-name conflict is left untouched by default (non-interactive)' `
    ($conflictContent -eq '{"Id":"pre-existing"}') "got '$conflictContent'"

Remove-Item Env:\WIZTEST_RBACTION, Env:\WIZTEST_RBCONFIG, Env:\WIZTEST_BACKUPDIR, Env:\WIZTEST_RBKIND,
    Env:\GIT_AUTHOR_NAME, Env:\GIT_AUTHOR_EMAIL, Env:\GIT_COMMITTER_NAME, Env:\GIT_COMMITTER_EMAIL `
    -ErrorAction SilentlyContinue
$env:HOME = $originalEnvHome
