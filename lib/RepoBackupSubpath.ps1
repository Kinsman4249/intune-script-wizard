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
# lib/RepoSource.ps1 - and update only the configured subpath inside that
# clone, commit, and push.
#
# Within that subpath itself, the wizard only ever touches files it wrote on
# a previous push (tracked in the config's 'SyncedFiles' list). Anything else
# already there - a placeholder, something a person or another tool put in
# that folder - is left alone by default. A same-named file this push wants
# to write that the wizard doesn't already own is a conflict: the user is
# asked before it gets overwritten, never overwritten silently.

# Relative (forward-slash) paths of every file under $Root, so a file found
# in the clone can be compared against a file found in $Dir regardless of
# platform path separators. Never includes '.git' - that's the clone's own
# repo metadata, not content to sync.
function Get-WizardRepoBackupRelativeFiles {
    param([Parameter(Mandatory)][string]$Root)

    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    return @(
        Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } |
            ForEach-Object {
                ([System.IO.Path]::GetRelativePath($Root, $_.FullName)) -replace '\\', '/'
            }
    )
}

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

        # Update only the configured subpath - siblings of $subpath elsewhere
        # in the clone are never touched. Within $subpath itself: only add,
        # update, or delete files this wizard previously wrote there
        # (tracked in $Config['SyncedFiles']); anything else already present
        # is left exactly as found unless it collides with a file this push
        # wants to write, in which case the user is asked first.
        $target = Join-Path $scratch $subpath
        $manifest = if ($Config['SyncedFiles']) { @($Config['SyncedFiles']) } else { @() }
        $existingRel = Get-WizardRepoBackupRelativeFiles -Root $target
        $desiredRel = Get-WizardRepoBackupRelativeFiles -Root $Dir

        # Files sitting under $subpath that this wizard did not put there
        # itself - a hand-added placeholder, someone else's content, or the
        # very first push into a folder that wasn't empty.
        $foreignRel = @($existingRel | Where-Object { $manifest -notcontains $_ })
        $conflicts = @($desiredRel | Where-Object { $foreignRel -contains $_ })

        if ($conflicts.Count -gt 0) {
            Write-Warning "'$subpath' in $remoteUrl already has $($conflicts.Count) file(s) this wizard did not put there: $($conflicts -join ', ')"
            $overwrite = $false
            if (Test-WizardInteractive) {
                $answer = Read-Host "Overwrite them with the local copy? (y/N)"
                $overwrite = ($answer -match '^y(es)?$')
            } else {
                Write-WizardDebug "Non-interactive session: leaving conflicting file(s) under '$subpath' untouched."
            }
            if (-not $overwrite) {
                $desiredRel = @($desiredRel | Where-Object { $conflicts -notcontains $_ })
                Write-Host "  Leaving $($conflicts.Count) pre-existing file(s) under '$subpath' untouched." -ForegroundColor Yellow
            }
        }

        New-Item -ItemType Directory -Path $target -Force -ErrorAction Stop | Out-Null
        foreach ($rel in $desiredRel) {
            $relPath = $rel -replace '/', [System.IO.Path]::DirectorySeparatorChar
            $src = Join-Path $Dir $relPath
            $dst = Join-Path $target $relPath
            New-Item -ItemType Directory -Path (Split-Path -Parent $dst) -Force -ErrorAction Stop | Out-Null
            Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop
        }

        # Files this wizard owns from a previous push that are no longer in
        # $Dir are real, intentional local deletions and get removed from the
        # remote too - anything foreign is never removed this way.
        $toRemove = @($manifest | Where-Object { ($desiredRel -notcontains $_) -and ($existingRel -contains $_) })
        foreach ($rel in $toRemove) {
            $path = Join-Path $target ($rel -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
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

        # Record what the wizard now owns under $subpath, so the next push
        # can tell its own files apart from anything else found there.
        $Config['SyncedFiles'] = $desiredRel
        Save-WizardRepoBackupConfig -Kind $Kind -Config $Config

        Write-Host "  Pushed $($info.Noun) to $remoteUrl (branch $branch, ::$subpath)" -ForegroundColor DarkGray
    } finally {
        Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
    }
}
