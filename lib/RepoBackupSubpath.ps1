# RepoBackupSubpath.ps1
# The '::subpath' variant of Sync-WizardRepoBackupDir (lib/RepoBackup.ps1):
# pushes backups/ or templates/ into one folder of an existing remote repo
# instead of replacing the whole repo. Split into its own file - same reason
# every lib/ file here is single-topic - rather than growing RepoBackup.ps1
# past its current size.
#
# Unlike the whole-repo push, this can't just 'git init' the local folder and
# push it straight to the remote's root: other content already in the remote
# repo (siblings of the configured subpath) has to survive untouched. So
# instead: clone the remote fresh - mirroring Sync-WizardRepoSource's own
# "always a fresh shallow clone, never an incremental fetch" approach in
# lib/RepoSource.ps1 - replace only the configured subpath inside that clone
# with $Dir's current contents, commit, and push.

function Sync-WizardRepoBackupSubpath {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][hashtable]$Config,
        [ValidateSet('Backups', 'Templates')][string]$Kind = 'Backups'
    )

    $info = Get-WizardRepoKindInfo -Kind $Kind
    $remoteUrl = $Config['RemoteUrl']
    $ref = $Config['Ref']
    $subpath = $Config['Subpath']

    $scratch = Join-Path ([System.IO.Path]::GetTempPath()) "wizard-repo-push-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $scratch -Force -ErrorAction Stop | Out-Null

    try {
        $cloneArgs = @('clone', '--depth', '1', '--quiet')
        if ($ref) { $cloneArgs += @('--branch', $ref) }
        $cloneArgs += @($remoteUrl, $scratch)

        try {
            Invoke-WizardExternalCommand -FilePath 'git' -ArgumentList $cloneArgs `
                -What "Cloning $remoteUrl" | Out-Null
        } catch {
            if (-not $ref) { throw }
            # The branch may simply not exist yet - this is the first push to
            # it. Retry against the repo's default branch and create $ref
            # locally, so the push below creates it on the remote too.
            Write-WizardDebug "Branch '$ref' not found on $remoteUrl (or clone failed); retrying without --branch: $($_.Exception.Message)"
            Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Path $scratch -Force -ErrorAction Stop | Out-Null
            Invoke-WizardExternalCommand -FilePath 'git' `
                -ArgumentList @('clone', '--depth', '1', '--quiet', $remoteUrl, $scratch) `
                -What "Cloning $remoteUrl" | Out-Null
            Invoke-WizardExternalCommand -FilePath 'git' `
                -ArgumentList @('-C', $scratch, 'checkout', '-b', $ref) `
                -What "Creating branch '$ref' in $scratch" | Out-Null
        }

        $branch = $ref
        if (-not $branch) {
            $branch = (Invoke-WizardExternalCommand -FilePath 'git' `
                -ArgumentList @('-C', $scratch, 'branch', '--show-current') `
                -What "Reading the current branch in $scratch")
            if ([string]::IsNullOrWhiteSpace($branch)) { $branch = 'main' }
        }

        # Replace only the configured subpath - remove-then-copy so local
        # deletions are reflected too, not just added/changed files -
        # everything else in the clone (siblings of $subpath) is left alone.
        $target = Join-Path $scratch $subpath
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
        }
        New-Item -ItemType Directory -Path $target -Force -ErrorAction Stop | Out-Null
        Get-ChildItem -LiteralPath $Dir -Force | Where-Object { $_.Name -ne '.git' } | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $target -Recurse -Force -ErrorAction Stop
        }

        Invoke-WizardExternalCommand -FilePath 'git' -ArgumentList @('-C', $scratch, 'add', '-A') `
            -What "Staging $($info.Noun) in $scratch" | Out-Null

        # 'git diff --cached --quiet' exits 1 when there ARE staged changes
        # and 0 when there are none - the opposite of every other git exit
        # code convention used here, so this is checked directly rather than
        # through Invoke-WizardExternalCommand (which treats any non-zero
        # exit as a failure).
        $global:LASTEXITCODE = 0
        & git -C $scratch diff --cached --quiet 2>$null
        $hasChanges = ($LASTEXITCODE -ne 0)
        if (-not $hasChanges) {
            Write-WizardDebug "Repo $Kind`: nothing new to push under '$subpath' in $remoteUrl"
            return
        }

        $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Invoke-WizardExternalCommand -FilePath 'git' `
            -ArgumentList @('-C', $scratch, 'commit', '-m', "$($info.CommitPrefix) $stamp") `
            -What "Committing $($info.Noun) in $scratch" | Out-Null

        if ($Config['Provider'] -eq 'azdevops-entra') {
            $token = Get-WizardAzDevOpsAccessToken
            Invoke-WizardExternalCommand -FilePath 'git' -ArgumentList @(
                '-C', $scratch, '-c', "http.extraheader=AUTHORIZATION: bearer $token",
                'push', '-u', 'origin', $branch
            ) -What "Pushing $($info.Noun) to $remoteUrl" | Out-Null
        } else {
            Invoke-WizardExternalCommand -FilePath 'git' `
                -ArgumentList @('-C', $scratch, 'push', '-u', 'origin', $branch) `
                -What "Pushing $($info.Noun) to $remoteUrl" | Out-Null
        }

        Write-Host "  Pushed $($info.Noun) to $remoteUrl (branch $branch, ::$subpath)" -ForegroundColor DarkGray
    } finally {
        Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
    }
}
