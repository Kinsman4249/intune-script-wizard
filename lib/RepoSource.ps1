# RepoSource.ps1
# Sourcing user/device scripts from a git repo instead of (or alongside) local
# disk. Entirely separate from RepoBackup.ps1: that file pushes backups/ OUT
# to a remote; this one pulls scripts IN from one. Neither reads the other's
# state.
#
# -SourceRepo takes one or more strings of the form:
#   <git-url>[#<ref>][::<subpath>]
# e.g. https://github.com/contoso/intune-scripts.git#main::platform/win11
# #<ref> is any git-clone-able ref (branch or tag). ::<subpath> scans only
# that folder within the clone, rather than its root, for user/ and device/.

# Parses one -SourceRepo entry into its URL, optional ref and optional
# subpath, plus a stable, filesystem-safe folder name to clone it into (so the
# same URL+ref always lands in the same cache slot, and different ones of the
# same repo never collide).
function Get-WizardRepoSourceSpec {
    param([Parameter(Mandatory)][string]$Raw)

    $rest = $Raw.Trim()
    if ([string]::IsNullOrWhiteSpace($rest)) {
        throw "-SourceRepo entry is blank. Expected '<git-url>[#<ref>][::<subpath>]'."
    }

    # ::<subpath> is stripped first, since a subpath could itself legally
    # contain '#' (an unusual but valid folder name) and must not be mistaken
    # for the ref separator.
    $subPath = $null
    $sepIndex = $rest.IndexOf('::')
    if ($sepIndex -ge 0) {
        $subPath = $rest.Substring($sepIndex + 2).Trim().Trim('/', '\')
        $rest = $rest.Substring(0, $sepIndex)
        if ([string]::IsNullOrWhiteSpace($subPath)) {
            throw "-SourceRepo '$Raw': nothing after '::'. Drop it, or name the subfolder to scan."
        }
    }

    $ref = $null
    $hashIndex = $rest.IndexOf('#')
    if ($hashIndex -ge 0) {
        $ref = $rest.Substring($hashIndex + 1).Trim()
        $rest = $rest.Substring(0, $hashIndex)
        if ([string]::IsNullOrWhiteSpace($ref)) {
            throw "-SourceRepo '$Raw': nothing after '#'. Drop it, or name the branch/tag to use."
        }
    }

    $url = $rest.Trim()
    if ([string]::IsNullOrWhiteSpace($url)) {
        throw "-SourceRepo '$Raw': could not find a git URL in it. Expected '<git-url>[#<ref>][::<subpath>]'."
    }

    # A short, readable slug from the URL, plus a hash of URL+ref so two refs
    # of the same repo (or two long URLs that only differ near the end) get
    # different cache folders instead of clobbering each other.
    $slug = ($url -replace '^[a-zA-Z][a-zA-Z0-9+.-]*://', '' -replace '[^a-zA-Z0-9]+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) { $slug = 'repo' }
    if ($slug.Length -gt 50) { $slug = $slug.Substring(0, 50) }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$url#$ref"))
    } finally {
        $sha.Dispose()
    }
    $short = (($digest | Select-Object -First 4 | ForEach-Object { $_.ToString('x2') }) -join '')

    [pscustomobject]@{
        Raw     = $Raw
        Url     = $url
        Ref     = $ref
        SubPath = $subPath
        Name    = "$slug-$short"
        Label   = "$url$(if ($ref) { "#$ref" })$(if ($subPath) { "::$subPath" })"
    }
}

# Clones $Spec fresh into $CacheRoot/$Spec.Name (replacing anything already
# there) and returns the folder to scan for user/ and device/ - the clone
# root, or $Spec.SubPath under it. A fresh shallow clone every run, rather
# than an incremental fetch, trades a little time for never having to reason
# about a half-updated or diverged local copy - this tool runs on demand, not
# in a tight loop, so that trade is the right one.
function Sync-WizardRepoSource {
    param(
        [Parameter(Mandatory)]$Spec,
        [Parameter(Mandatory)][string]$CacheRoot,
        # For verification clones only (see e2e-tests/): if the pushed
        # subpath had nothing under it, git never commits the empty folder,
        # so a fresh clone won't have it even though the push succeeded.
        # Creating it and returning it (now legitimately empty) lets the
        # caller's file-count comparison report that honestly instead of
        # this function throwing on a non-error. Real -SourceRepo pulls
        # must NOT set this: there, a missing subpath is most often a typo
        # and should keep failing loudly.
        [switch]$CreateSubPathIfMissing
    )

    if (-not (Test-WizardCommandAvailable -Name 'git')) {
        throw "-SourceRepo needs git installed and on PATH to clone '$($Spec.Url)'."
    }

    if (-not (Test-Path -LiteralPath $CacheRoot)) {
        New-Item -ItemType Directory -Path $CacheRoot -Force -ErrorAction Stop | Out-Null
    }
    $dest = Join-Path $CacheRoot $Spec.Name
    if (Test-Path -LiteralPath $dest) {
        Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction Stop
    }

    # -c core.autocrlf=false/-safecrlf=false: without this, git's own line-
    # ending normalization on checkout can rewrite a script's original
    # CRLF/LF convention (which Export-WizardScriptTemplate - lib/Template.ps1
    # - deliberately preserved byte-for-byte on push) into whatever this
    # machine's git config prefers, corrupting a restored script's content.
    # See lib/RepoBackup.ps1's $script:WizardGitNoCrlfArgs.
    $cloneArgs = $script:WizardGitNoCrlfArgs + @('clone', '--depth', '1', '--quiet')
    if ($Spec.Ref) { $cloneArgs += @('--branch', $Spec.Ref) }
    $cloneArgs += @($Spec.Url, $dest)

    Write-Host "Fetching $($Spec.Label)..."
    try {
        Invoke-WizardExternalCommand -FilePath 'git' -ArgumentList $cloneArgs `
            -What "Cloning $($Spec.Url)" | Out-Null
    } catch {
        throw "Could not clone '$($Spec.Url)'$(if ($Spec.Ref) { " at ref '$($Spec.Ref)'" }): $($_.Exception.Message)"
    }

    $scanRoot = $dest
    if ($Spec.SubPath) {
        $scanRoot = Join-Path $dest $Spec.SubPath
        if (-not (Test-Path -LiteralPath $scanRoot -PathType Container)) {
            if ($CreateSubPathIfMissing) {
                New-Item -ItemType Directory -Path $scanRoot -Force -ErrorAction Stop | Out-Null
            } else {
                throw "-SourceRepo '$($Spec.Raw)': subpath '$($Spec.SubPath)' does not exist in this repo/ref."
            }
        }
    }
    Write-WizardDebug "Repo source '$($Spec.Label)' scanning under $scanRoot"
    return $scanRoot
}
