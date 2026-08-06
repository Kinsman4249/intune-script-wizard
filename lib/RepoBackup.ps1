# RepoBackup.ps1
# Optionally pushes the wizard's local backups/ folder to a remote git repo
# (plain git+PAT, GitHub via gh, or Azure DevOps via PAT or a Microsoft Entra
# token) so backup history survives a lost or wiped machine. Entirely
# separate from Backup.ps1's own on-disk schema: this file only ever adds a
# git commit on top of files Backup-WizardScript already wrote - it never
# reads or interprets backup JSON itself.
#
# No secret this wizard handles is ever written to a file this wizard owns.
# A PAT is handed straight to 'git credential approve', which stores it
# through whatever OS-native credential helper is already configured
# (git-credential-manager if installed, else osxkeychain/wincred/libsecret).
# An Azure DevOps Entra token is fetched fresh from 'az' on every push and
# never persisted at all.

# The fixed application id for Azure DevOps' own Entra app - the same one
# used to request a token via the Azure CLI. Documented at
# https://learn.microsoft.com/azure/devops/integrate/get-started/authentication/entra
$script:WizardAzDevOpsResourceId = '499b84ac-1321-427f-aa17-267ca6975798'

# Export-WizardScriptTemplate (lib/Template.ps1) deliberately preserves each
# script's original CRLF-vs-LF convention byte-for-byte. Without this, git's
# own autocrlf normalization - on by default in most Windows git installs -
# would silently undo that: LF endings get rewritten to CRLF on checkout
# (and vice versa on commit), corrupting content that was exported exactly as
# the tenant had it. Passed as global '-c' options - rather than relying on
# 'git config' inside the target repo - so it applies uniformly whether the
# call is a clone, an add, or a commit, regardless of the machine's own git
# config. Prepend this to the ArgumentList of any git call that clones,
# stages, or commits file content (read-only calls like rev-parse/branch/push
# don't need it).
$script:WizardGitNoCrlfArgs = @('-c', 'core.autocrlf=false', '-c', 'core.safecrlf=false')

# Per-target strings for the two independent repo-push destinations this file
# supports. A third target later is a table entry here rather than
# if-statements scattered through every function below.
function Get-WizardRepoKindInfo {
    param([ValidateSet('Backups', 'Templates')][string]$Kind = 'Backups')

    switch ($Kind) {
        'Templates' {
            return @{
                ConfigFile   = 'repo-template-config.json'
                Noun         = 'templates'
                SetupPrompt  = 'Also push exported templates to a remote git repo? (y/N)'
                UrlPrompt    = 'Repo URL to push templates to - <git-url>[#branch][::subpath] (e.g. https://github.com/you/templates.git, or for Azure DevOps: https://org@dev.azure.com/org/project/_git/repo#branch::path/in/repo)'
                CommitPrefix = 'Templates'
            }
        }
        default {
            return @{
                ConfigFile   = 'repo-backup-config.json'
                Noun         = 'backups'
                SetupPrompt  = 'Also back up these backup files to a remote git repo? (y/N)'
                UrlPrompt    = 'Repo URL to push backups to - <git-url>[#branch][::subpath] (e.g. https://github.com/you/backups.git, or for Azure DevOps: https://org@dev.azure.com/org/project/_git/repo#branch::path/in/repo)'
                CommitPrefix = 'Backup'
            }
        }
    }
}

# Where the repo-backup settings (which provider, which remote, or that the
# user said no) are remembered between runs. Same folder Telemetry.ps1 uses
# for its own local state, same reason: %APPDATA% on Windows, a dotfile under
# HOME everywhere else. Backups and Templates are two independent config
# files in that same folder, so declining one never silences the other.
function Get-WizardRepoBackupConfigPath {
    param([ValidateSet('Backups', 'Templates')][string]$Kind = 'Backups')

    if ($IsWindows -and $env:APPDATA) {
        $dir = Join-Path $env:APPDATA 'IntuneScriptWizard'
    } else {
        $dir = Join-Path $HOME '.intune-script-wizard'
    }
    return (Join-Path $dir (Get-WizardRepoKindInfo -Kind $Kind).ConfigFile)
}

# Returns $null when nothing has been configured yet (including "the file
# can't be read") - Push-WizardBackupsToRepo takes $null as its cue to offer
# first-run setup, so a freshly-installed wizard and a genuinely declined one
# must not look the same.
function Get-WizardRepoBackupConfig {
    param([ValidateSet('Backups', 'Templates')][string]$Kind = 'Backups')

    $path = Get-WizardRepoBackupConfigPath -Kind $Kind
    try {
        return (Read-WizardJsonFile -Path $path -AsHashtable)
    } catch {
        Write-WizardDebug "Could not read repo $Kind config, treating as unconfigured: $($_.Exception.Message)"
        return $null
    }
}

function Save-WizardRepoBackupConfig {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [ValidateSet('Backups', 'Templates')][string]$Kind = 'Backups'
    )

    $path = Get-WizardRepoBackupConfigPath -Kind $Kind
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
    }
    Save-WizardJsonFile -Path $path -Value $Config -Depth 4
}

# Runs an external CLI (git/az) for a step that should either succeed
# cleanly or fail loudly - throws a clear, wizard-style error on a non-zero
# exit instead of leaving a native command's raw output and a non-terminating
# error for the caller to piece together. Not used for the interactive
# 'gh auth login'/'az login' steps, which need the real console attached
# rather than captured output.
function Invoke-WizardExternalCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$What,
        # Lines fed to the command on stdin, e.g. git's credential protocol
        # (url=...  username=...  password=...  <blank line>).
        [string[]]$StdInLines
    )

    # Cleared first: if $FilePath isn't found, the call below throws before
    # setting $LASTEXITCODE at all, and a stale value from an earlier native
    # command would otherwise be misread as this call's own exit code.
    $global:LASTEXITCODE = 0
    if ($StdInLines) {
        $output = $StdInLines | & $FilePath @ArgumentList 2>&1
    } else {
        $output = & $FilePath @ArgumentList 2>&1
    }
    $exit = $LASTEXITCODE
    $text = ($output | Out-String).Trim()

    if ($exit -ne 0) {
        throw "$What failed (exit ${exit}): $text"
    }
    return $text
}

# Stores a PAT for $RemoteUrl in git's own credential store. 'x-access-token'
# is GitHub's documented convention for "the password is the whole
# credential, the username doesn't matter" - GitLab and most other plain git
# hosts accept it the same way.
function Set-WizardGitPatCredential {
    param([Parameter(Mandatory)][string]$RemoteUrl)

    $secure = Read-Host "Personal access token for $RemoteUrl" -AsSecureString
    # This is the only place the PAT ever exists as plain text, and only for
    # the moment it takes to hand it to 'git credential approve' below - it
    # is never written to a variable that outlives this function or to disk.
    $plain = [System.Net.NetworkCredential]::new('', $secure).Password
    if ([string]::IsNullOrWhiteSpace($plain)) {
        throw "No token entered."
    }

    $lines = @(
        "url=$RemoteUrl"
        "username=x-access-token"
        "password=$plain"
        ""
    )
    Invoke-WizardExternalCommand -FilePath 'git' -ArgumentList @('credential', 'approve') `
        -StdInLines $lines -What "Storing the credential for $RemoteUrl" | Out-Null
}

# Same idea for Azure DevOps, whose own docs use 'pat' as the placeholder
# username for PAT-over-HTTPS auth (any non-empty username is accepted).
function Set-WizardAzDevOpsPatCredential {
    param([Parameter(Mandatory)][string]$RemoteUrl)

    $secure = Read-Host "Azure DevOps personal access token for $RemoteUrl" -AsSecureString
    $plain = [System.Net.NetworkCredential]::new('', $secure).Password
    if ([string]::IsNullOrWhiteSpace($plain)) {
        throw "No token entered."
    }

    $lines = @(
        "url=$RemoteUrl"
        "username=pat"
        "password=$plain"
        ""
    )
    Invoke-WizardExternalCommand -FilePath 'git' -ArgumentList @('credential', 'approve') `
        -StdInLines $lines -What "Storing the Azure DevOps credential for $RemoteUrl" | Out-Null
}

# Lets gh own its whole login+credential flow, including wiring itself into
# git as the credential helper - no PAT handling on our side at all.
function Set-WizardGhAuth {
    $global:LASTEXITCODE = 0
    & gh auth status 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Starting gh's interactive sign-in..." -ForegroundColor Cyan
        # No output capture here: gh's own prompts need the real console.
        & gh auth login
        if ($LASTEXITCODE -ne 0) { throw "'gh auth login' did not complete successfully." }
    }
    & gh auth setup-git
    if ($LASTEXITCODE -ne 0) { throw "'gh auth setup-git' could not wire gh into git's credential helper." }
}

# Makes sure 'az' has a signed-in account to mint tokens from. Doesn't fetch
# or store a token itself - Entra tokens are short-lived by design, so
# Get-WizardAzDevOpsAccessToken fetches a fresh one on every push instead.
function Set-WizardAzDevOpsEntraAuth {
    $global:LASTEXITCODE = 0
    & az account show 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Starting az's interactive sign-in..." -ForegroundColor Cyan
        & az login | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "'az login' did not complete successfully." }
    }
}

function Get-WizardAzDevOpsAccessToken {
    $global:LASTEXITCODE = 0
    $token = & az account get-access-token --resource $script:WizardAzDevOpsResourceId --query accessToken -o tsv 2>&1
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace("$token")) {
        throw "Could not get a Microsoft Entra access token for Azure DevOps: $token. Run 'az login' and try a backup again."
    }
    return "$token".Trim()
}

# Asks how to authenticate against an Azure DevOps remote: Entra sign-in via
# 'az' when it's installed (Microsoft's now-recommended method - see
# learn.microsoft.com/azure/devops/integrate/get-started/authentication/entra),
# else falls back to a PAT the same way plain git does.
function Request-WizardAzDevOpsAuthChoice {
    param(
        [switch]$HasAz,
        [Parameter(Mandatory)][string]$RemoteUrl
    )

    if ($HasAz) {
        $answer = Read-Host "Azure DevOps supports signing in with your Microsoft account instead of a PAT (via az login). Use that? (Y/n)"
        if ($answer -notmatch '^n(o)?$') {
            Set-WizardAzDevOpsEntraAuth
            return 'azdevops-entra'
        }
    } else {
        Write-Host "  (Azure CLI 'az' not found - install it for PAT-free sign-in: https://learn.microsoft.com/cli/azure/install-azure-cli)" -ForegroundColor DarkGray
    }

    Set-WizardAzDevOpsPatCredential -RemoteUrl $RemoteUrl
    return 'azdevops-pat'
}

# Offers, once, to push the wizard's local backups (or templates) to a
# remote repo too. Only ever called when no config for this $Kind exists
# yet; whatever the answer is (including "no") gets remembered so this never
# asks twice - independently per $Kind, so declining templates never
# silences an already-configured backups push and vice versa.
function Request-WizardRepoBackupSetup {
    param([ValidateSet('Backups', 'Templates')][string]$Kind = 'Backups')

    if (-not (Test-WizardInteractive)) {
        Write-WizardDebug "Skipping repo $Kind setup prompt: session is not interactive."
        return
    }

    $info = Get-WizardRepoKindInfo -Kind $Kind

    Write-Host ""
    $answer = Read-Host $info.SetupPrompt
    if ($answer -notmatch '^y(es)?$') {
        Save-WizardRepoBackupConfig -Kind $Kind -Config @{ Declined = $true; ConfiguredAt = (Get-Date).ToString('o') }
        Write-Host "  Not asking again. Delete '$(Get-WizardRepoBackupConfigPath -Kind $Kind)' if you change your mind." -ForegroundColor DarkGray
        return
    }

    $rawUrl = Read-Host $info.UrlPrompt
    if ([string]::IsNullOrWhiteSpace($rawUrl)) {
        Write-Host "  No URL entered; skipping repo $($info.Noun) setup." -ForegroundColor Yellow
        return
    }

    # Same '<git-url>[#ref][::subpath]' syntax -SourceRepo already uses
    # (lib/RepoSource.ps1), so pushing into a subfolder of a shared repo uses
    # the one syntax people have to learn either way. $remoteUrl below is
    # always the bare git URL - credential storage and provider detection key
    # off it directly, never off the '#ref::subpath' suffix.
    try {
        $spec = Get-WizardRepoSourceSpec -Raw $rawUrl
    } catch {
        Write-Warning "Could not parse that repo URL: $($_.Exception.Message)"
        return
    }
    $remoteUrl = $spec.Url

    # backups/.git and templates/.git are two unrelated repos with disjoint
    # histories. Pointed at the same remote branch with no subpath (or the
    # same subpath), each push rejects the other's history - so the second
    # one configured must be told and must opt in explicitly rather than
    # silently fighting the first. Different subpaths of the same repo/branch
    # don't collide (each push only ever touches its own subfolder), so that
    # combination is allowed without a warning.
    if ($Kind -eq 'Templates') {
        $backupsConfig = Get-WizardRepoBackupConfig -Kind Backups
        if ($backupsConfig -and -not $backupsConfig['Declined'] -and
            $backupsConfig['RemoteUrl'] -eq $remoteUrl -and
            "$($backupsConfig['Ref'])" -eq "$($spec.Ref)") {
            $confinedToDifferentSubpaths = $backupsConfig['Subpath'] -and $spec.SubPath -and
                ($backupsConfig['Subpath'] -ne $spec.SubPath)
            if (-not $confinedToDifferentSubpaths) {
                Write-Warning "This is the same remote ($($spec.Label)) already configured for backups. backups/ and templates/ push independent, unrelated git histories - unless each is confined to its own '::subpath', pushing both means each push rejects the other's history."
                $confirm = Read-Host "Use it anyway? (y/N)"
                if ($confirm -notmatch '^y(es)?$') {
                    Write-Host "  Not configuring the templates repo push." -ForegroundColor DarkGray
                    return
                }
            }
        }
    }

    $hasGit = Test-WizardCommandAvailable -Name 'git'
    if (-not $hasGit) {
        Write-Warning "git is not installed/on PATH; it's required to push $($info.Noun) (the gh and az paths still push over git underneath). Install git and re-run a backup to set this up."
        return
    }
    $isAzureDevOps = $remoteUrl -match '(?i)dev\.azure\.com|\.visualstudio\.com'
    $hasGh = $hasGit -and (Test-WizardCommandAvailable -Name 'gh')

    try {
        if ($isAzureDevOps) {
            $hasAz = Test-WizardCommandAvailable -Name 'az'
            $provider = Request-WizardAzDevOpsAuthChoice -HasAz:$hasAz -RemoteUrl $remoteUrl
        } elseif ($hasGh) {
            $useGh = Read-Host "gh is also available and can sign you in without you handling a PAT yourself. Use gh? (Y/n)"
            if ($useGh -notmatch '^n(o)?$') {
                Set-WizardGhAuth
                $provider = 'gh'
            } else {
                Set-WizardGitPatCredential -RemoteUrl $remoteUrl
                $provider = 'git'
            }
        } else {
            Set-WizardGitPatCredential -RemoteUrl $remoteUrl
            $provider = 'git'
        }
    } catch {
        Write-Warning "Could not finish setting up repo $($info.Noun) auth: $($_.Exception.Message). Nothing was saved; the next backup will offer this again."
        return
    }

    Save-WizardRepoBackupConfig -Kind $Kind -Config @{
        Provider     = $provider
        RemoteUrl    = $remoteUrl
        Ref          = $spec.Ref
        Subpath      = $spec.SubPath
        Raw          = $rawUrl
        Declined     = $false
        ConfiguredAt = (Get-Date).ToString('o')
    }
    Write-Host "  Repo backup configured ($provider -> $($spec.Label)). Future $($info.Noun) will be pushed automatically." -ForegroundColor Green
}

# Commits and pushes whatever is currently in $Dir to the configured remote.
# A fresh $Dir becomes its own git repo the first time this runs (backups/
# and templates/ are already gitignored by the wizard's own repo, so this
# nested repo does not fight it for the same files).
function Sync-WizardRepoBackupDir {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][hashtable]$Config,
        [ValidateSet('Backups', 'Templates')][string]$Kind = 'Backups'
    )

    # A configured '::subpath' means $Dir's contents belong in one folder of
    # an existing remote repo, not at its root - handled by a dedicated clone
    # + merge flow in RepoBackupSubpath.ps1 rather than the push-to-root path
    # below, since siblings of that subpath must survive untouched.
    if ($Config['Subpath']) {
        Sync-WizardRepoBackupSubpath -Dir $Dir -Config $Config -Kind $Kind
        return
    }

    $info = Get-WizardRepoKindInfo -Kind $Kind

    $isRepo = $false
    try {
        Invoke-WizardExternalCommand -FilePath 'git' `
            -ArgumentList @('-C', $Dir, 'rev-parse', '--is-inside-work-tree') `
            -What "Checking for a git repo in $Dir" | Out-Null
        $isRepo = $true
    } catch {
        $isRepo = $false
    }

    if (-not $isRepo) {
        Invoke-WizardExternalCommand -FilePath 'git' -ArgumentList @('-C', $Dir, 'init') `
            -What "Initialising a git repo in $Dir" | Out-Null
        Invoke-WizardExternalCommand -FilePath 'git' `
            -ArgumentList @('-C', $Dir, 'remote', 'add', 'origin', $Config['RemoteUrl']) `
            -What "Adding the remote in $Dir" | Out-Null
    }

    Invoke-WizardExternalCommand -FilePath 'git' -ArgumentList ($script:WizardGitNoCrlfArgs + @('-C', $Dir, 'add', '-A')) `
        -What "Staging $($info.Noun) in $Dir" | Out-Null

    # 'git diff --cached --quiet' exits 1 when there ARE staged changes and 0
    # when there are none - the opposite of every other git exit-code
    # convention used here, so this is checked directly rather than through
    # Invoke-WizardExternalCommand (which treats any non-zero as a failure).
    $global:LASTEXITCODE = 0
    & git -C $Dir diff --cached --quiet 2>$null
    $hasChanges = ($LASTEXITCODE -ne 0)
    if (-not $hasChanges) {
        Write-WizardDebug "Repo $Kind`: nothing new to push in $Dir"
        return
    }

    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Invoke-WizardExternalCommand -FilePath 'git' `
        -ArgumentList ($script:WizardGitNoCrlfArgs + @('-C', $Dir, 'commit', '-m', "$($info.CommitPrefix) $stamp")) `
        -What "Committing $($info.Noun) in $Dir" | Out-Null

    $branch = (Invoke-WizardExternalCommand -FilePath 'git' `
        -ArgumentList @('-C', $Dir, 'branch', '--show-current') `
        -What "Reading the current branch in $Dir")
    if ([string]::IsNullOrWhiteSpace($branch)) { $branch = 'main' }

    if ($Config['Provider'] -eq 'azdevops-entra') {
        $token = Get-WizardAzDevOpsAccessToken
        Invoke-WizardExternalCommand -FilePath 'git' -ArgumentList @(
            '-C', $Dir, '-c', "http.extraheader=AUTHORIZATION: bearer $token",
            'push', '-u', 'origin', $branch
        ) -What "Pushing $($info.Noun) to $($Config['RemoteUrl'])" | Out-Null
    } else {
        Invoke-WizardExternalCommand -FilePath 'git' `
            -ArgumentList @('-C', $Dir, 'push', '-u', 'origin', $branch) `
            -What "Pushing $($info.Noun) to $($Config['RemoteUrl'])" | Out-Null
    }

    Write-Host "  Pushed $($info.Noun) to $($Config['RemoteUrl'])" -ForegroundColor DarkGray
}

# Called after a run has written new backups (or templates) locally. Pushes
# them to a configured remote repo, or - the very first time this $Kind ever
# runs - offers to set that up. A push failure here is reported as a
# warning, never a run failure: the local copy already exists and is the
# thing restores (or promotion) actually depend on.
function Push-WizardBackupsToRepo {
    param(
        [Parameter(Mandatory)][string]$BackupDir,
        [ValidateSet('Backups', 'Templates')][string]$Kind = 'Backups'
    )

    if (-not (Test-Path -LiteralPath $BackupDir)) { return }

    $config = Get-WizardRepoBackupConfig -Kind $Kind
    if (-not $config) {
        Request-WizardRepoBackupSetup -Kind $Kind
        $config = Get-WizardRepoBackupConfig -Kind $Kind
    }
    if (-not $config -or $config['Declined']) { return }

    try {
        Sync-WizardRepoBackupDir -Dir $BackupDir -Config $config -Kind $Kind
    } catch {
        $noun = (Get-WizardRepoKindInfo -Kind $Kind).Noun
        Write-Warning "Local $noun are safe at '$BackupDir', but the push to the configured repo failed: $($_.Exception.Message). This will retry on the next backup."
    }
}

# Thin wrapper so the stage-6 call site in Deploy-IntuneScripts.ps1 reads
# honestly as "push the templates" rather than reusing the backups verb.
function Push-WizardTemplatesToRepo {
    param([Parameter(Mandatory)][string]$TemplateDir)

    Push-WizardBackupsToRepo -BackupDir $TemplateDir -Kind Templates
}
