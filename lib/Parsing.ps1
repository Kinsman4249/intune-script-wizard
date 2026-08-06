# Parsing.ps1
# Reads a .ps1 file and pulls out the wizard's meta-comment directives.
# Comments are left in the uploaded script content untouched - they're valid
# PowerShell comments and cause no harm at runtime on the endpoint.

# Single source of truth for the "#notemplate" directive, shared by two callers
# that must agree exactly: Get-ScriptMetadata (reading a local .ps1 before a
# deploy) and Test-WizardTemplateExcluded (reading a body back out of the
# tenant during an export). Drift between them would exclude a script in one
# direction only.
$script:WizardNoTemplatePattern = '^#\s*notemplate\s*$'

# Takes the raw text after "#group:" (or "#excludegroup:") and returns it
# with any surrounding quotes removed, ready to use as a group name or GUID.
function Get-WizardGroupRefValue {
    # Strips the optional surrounding double quotes from a #group: value.
    # Quotes are only needed for display names, but accepting them around a
    # GUID too means users don't have to remember which form takes them.
    # param() declares this function's inputs. [Parameter(Mandatory)] means
    # the caller must supply -Raw or PowerShell will prompt/error.
    param([Parameter(Mandatory)][string]$Raw)

    $value = $Raw.Trim()
    if ($value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"')) {
        $value = $value.Substring(1, $value.Length - 2)
    }
    return $value.Trim()
}

# Reads one .ps1 file line by line and pulls out its #scriptname:, #type:,
# #group:, description block, etc. Returns a single object describing the
# script, or $null if the script isn't meant to be deployed (see below).
function Get-ScriptMetadata {
    param(
        [Parameter(Mandatory)][string]$Path,
        # Type inferred from the folder the script was found in (user/device),
        # or $null if the script was found loose and must carry a #type comment.
        [ValidateSet('user', 'device', $null)]
        [string]$FolderType,
        # Same effect as a per-script #typeoverride:yes, applied to every script
        # in the run. Set from Deploy-IntuneScripts.ps1's -AllowTypeOverride.
        [switch]$AllowTypeOverride
    )

    try {
        # -ErrorAction Stop matters even under a 'Stop' preference: Get-Content
        # reports some read failures as non-terminating errors per file.
        # Get-Content reads the file as an array of lines. Wrapping it in @(...)
        # guarantees $lines is always an array, even if the file has 0 or 1 lines
        # (without the @(), a single-line file would come back as a plain string).
        $lines = @(Get-Content -LiteralPath $Path -ErrorAction Stop)
    } catch {
        # try/catch: if Get-Content fails (bad permissions, locked file, etc),
        # the catch block runs instead of crashing, so we can throw a clearer message.
        throw "Could not read '$Path': $($_.Exception.Message). Fix the file's permissions, close whatever is holding it open, or move it out of the scanned folder."
    }

    # .NET's Path class strips the folder and the ".ps1" extension, leaving
    # just the file's base name (e.g. "C:\scripts\foo.ps1" -> "foo").
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Path)

    # These are the defaults used if the matching #directive comment is never
    # found while scanning the file below.
    $displayName = $baseName
    $description = ''
    # Folder placement wins by default. #type: is parsed into $typeFromComment
    # rather than straight into $type, so a conflict can be resolved (folder
    # wins, unless #typeoverride:yes is present) after the whole file is read.
    $typeFromComment = $null
    $typeOverride = $false
    $noAssignments = $false
    $assignAll = $false
    $noTemplate = $false
    $enforceSignatureCheck = $false
    $runAs32Bit = $true   # default: do NOT run in 64-bit PowerShell host
    # $inDesc is a flag: true while we're reading lines between #startdesc and
    # #enddesc, so multi-line description text is collected instead of being
    # matched against the single-line directives below.
    $inDesc = $false
    # @() creates an empty array. These collect multiple values found across
    # the file (a description can span many lines; #group: can repeat).
    $descLines = @()
    $groupRefs = @()
    $excludeGroupRefs = @()

    # Walk the file one line at a time, checking each trimmed line against a
    # series of patterns. Every branch below ends in "continue", which skips
    # straight to the next line of the loop once a match is handled.
    foreach ($line in $lines) {
        $trimmed = $line.Trim()

        if ($inDesc) {
            # -match tests $trimmed against a regular expression (regex) on the
            # right. '^#\s*enddesc\s*$' means: start of line, a '#', optional
            # whitespace, the word "enddesc", optional whitespace, end of line.
            if ($trimmed -match '^#\s*enddesc\s*$') {
                $inDesc = $false
                continue
            }
            # Strip a single leading '#' and one optional space, keep the rest verbatim.
            # -replace applies a regex substitution: matches for '^#\s?' at the
            # start of the string are replaced with nothing (deleted).
            $descLines += ($trimmed -replace '^#\s?', '')
            continue
        }

        if ($trimmed -match '^#\s*startdesc\s*$') {
            $inDesc = $true
            continue
        }
        # (?<name>...) is a "named capture group": the text matched inside the
        # parentheses is saved and retrievable afterwards via $Matches['name'].
        # -match automatically fills the built-in $Matches variable on success.
        if ($trimmed -match '^#\s*scriptname\s*:\s*"(?<name>[^"]+)"\s*$') {
            $displayName = $Matches['name']
            continue
        }
        if ($trimmed -match '^#\s*type\s*:\s*(?<type>user|device)\s*$') {
            $typeFromComment = $Matches['type'].ToLowerInvariant()
            continue
        }
        if ($trimmed -match '^#\s*typeoverride\s*:\s*yes\s*$') {
            $typeOverride = $true
            continue
        }
        if ($trimmed -match '^#\s*noassig(?:n)?ments?\s*$') {
            $noAssignments = $true
            continue
        }
        # Explicitly include the default all-users/all-devices target alongside
        # whatever #group: entries (if any) are also present. Without this, a
        # script assigned to both a specific group AND the default target has
        # no way to say so - '#group:' alone means "only these groups".
        if ($trimmed -match '^#\s*assignall\s*$') {
            $assignAll = $true
            continue
        }
        if ($trimmed -match $script:WizardNoTemplatePattern) {
            $noTemplate = $true
            continue
        }
        if ($trimmed -match '^#\s*scriptcheck\s*:\s*yes\s*$') {
            $enforceSignatureCheck = $true
            continue
        }
        if ($trimmed -match '^#\s*host\s*:\s*64\s*$') {
            $runAs32Bit = $false
            continue
        }
        # #group: / #excludegroup: may appear more than once. The value is either
        # a quoted display name or a bare object GUID; which one it is gets
        # decided at resolution time, not here.
        if ($trimmed -match '^#\s*group\s*:\s*(?<ref>\S.*?)\s*$') {
            $groupRefs += (Get-WizardGroupRefValue -Raw $Matches['ref'])
            continue
        }
        if ($trimmed -match '^#\s*excludegroup\s*:\s*(?<ref>\S.*?)\s*$') {
            $excludeGroupRefs += (Get-WizardGroupRefValue -Raw $Matches['ref'])
            continue
        }
    }

    if ($descLines.Count -gt 0) {
        # -join "`n" glues the array of description lines back into one string,
        # putting a newline character (`n is PowerShell's escape for newline,
        # only recognized inside double quotes) between each line.
        $description = ($descLines -join "`n")
    }

    # Resolve #type: against the folder it was found in. A script sitting under
    # user/ or device/ is trusted to be there on purpose, so the folder wins on
    # a conflict - #typeoverride:yes lets an author say the comment is correct
    # and the folder is not (e.g. a device script staged under user/ on purpose).
    if ($FolderType -and $typeFromComment -and $typeFromComment -ne $FolderType) {
        if ($typeOverride -or $AllowTypeOverride) {
            $type = $typeFromComment
            $via = if ($typeOverride) { '#typeoverride:yes' } else { '-AllowTypeOverride' }
            Write-WizardDebug "'$Path': $via honoured, using #type:$typeFromComment over folder '$FolderType'."
        } else {
            $type = $FolderType
            Write-Warning "'$Path': #type:$typeFromComment conflicts with its '$FolderType' folder. Folder wins; add #typeoverride:yes to the script or pass -AllowTypeOverride to use the comment instead."
        }
    } elseif ($FolderType) {
        $type = $FolderType
    } else {
        $type = $typeFromComment
    }

    if (-not $type) {
        # Not an error: a loose script with no #type simply isn't ours to deploy.
        Write-Warning "Skipping '$Path': no user/device folder and no '#type:user|device' comment."
        return $null
    }

    # These, by contrast, are authoring mistakes. Throwing aborts the run during
    # the pre-flight scan, before anything reaches the tenant.
    if ($noAssignments -and ($groupRefs.Count -gt 0 -or $excludeGroupRefs.Count -gt 0)) {
        throw "'$Path': #noassignments cannot be combined with #group: or #excludegroup:. Remove one or the other."
    }

    if ($noAssignments -and $assignAll) {
        throw "'$Path': #noassignments cannot be combined with #assignall. Remove one or the other."
    }

    # Pipeline: $groupRefs is piped into Where-Object, which keeps only the
    # entries that also appear in $excludeGroupRefs (-in checks membership).
    # The result is any group listed in both places, which is a contradiction.
    $overlap = $groupRefs | Where-Object { $_ -in $excludeGroupRefs }
    if ($overlap) {
        throw "'$Path': group(s) listed as both #group: and #excludegroup: - $(($overlap | Select-Object -Unique) -join ', ')."
    }

    # [pscustomobject]@{ ... } builds a lightweight custom object with named
    # properties, similar to a struct/record in other languages. This is the
    # single return value describing everything parsed out of the script.
    [pscustomobject]@{
        Path                  = $Path
        FileName              = [System.IO.Path]::GetFileName($Path)
        DisplayName           = $displayName
        Description           = $description
        Type                  = $type
        NoAssignments         = $noAssignments
        AssignAll             = $assignAll
        NoTemplate            = $noTemplate
        EnforceSignatureCheck = $enforceSignatureCheck
        RunAs32Bit            = $runAs32Bit
        RunAsAccount          = if ($type -eq 'user') { 'user' } else { 'system' }
        # As written in the file: display names and/or GUIDs, unresolved.
        GroupRefs             = @($groupRefs | Select-Object -Unique)
        ExcludeGroupRefs      = @($excludeGroupRefs | Select-Object -Unique)
        # Filled in by Resolve-WizardGroupReferences once Graph is connected.
        IncludeGroupIds       = @()
        ExcludeGroupIds       = @()
    }
}

# Scans RootPath (and its user/ and device/ subfolders) for .ps1 files,
# skips any that are the wizard's own files, and returns the parsed metadata
# (from Get-ScriptMetadata) for every remaining script.
function Find-WizardScripts {
    param(
        [Parameter(Mandatory)][string]$RootPath,
        # Full paths never to treat as deployable scripts. The caller passes the
        # wizard's own files: with the default -Path of the current directory,
        # Deploy-IntuneScripts.ps1 is itself a loose .ps1 under RootPath, which
        # otherwise warns on every run and would be uploadable to Intune the
        # moment anyone added a #type: comment to it.
        [string[]]$ExcludePath = @(),
        # Passed straight through to Get-ScriptMetadata for every candidate.
        [switch]$AllowTypeOverride
    )

    # Case-insensitive set of normalised full paths for O(1) exclusion checks.
    # Catches the usual case: the wizard is run from the same folder it scans.
    # A HashSet is like an array but optimized for fast "does this exist in
    # here?" lookups instead of ordered storage; OrdinalIgnoreCase makes those
    # lookups ignore upper/lower case, which matters on case-insensitive
    # filesystems like Windows.
    $excluded = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    # File names only. Catches the other case: someone copied the wizard next to
    # their scripts, so the path differs but the file is still ours. Applied
    # ONLY to loose root-level scripts - a real deployable script would never
    # sit outside user/ or device/ under one of the wizard's own file names,
    # whereas a script inside those folders is always the user's own.
    $excludedNames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    foreach ($p in $ExcludePath) {
        if (-not $p) { continue }
        # [void] discards the return value. HashSet.Add() returns $true/$false
        # for whether the item was new, but here we don't care about that result
        # and [void] stops it from being printed to the console.
        [void]$excluded.Add([System.IO.Path]::GetFullPath($p))
        [void]$excludedNames.Add([System.IO.Path]::GetFileName($p))
    }

    # Gather candidates first, then parse. Keeping the two phases separate avoids
    # accumulating results inside a script block, where the scoping rules differ
    # depending on how the block is invoked.
    $candidates = @()

    foreach ($folder in @('user', 'device')) {
        $dir = Join-Path $RootPath $folder
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        try {
            # A subfolder the account cannot read would otherwise silently
            # contribute nothing, and the run would look like a success that
            # simply had less to do.
            foreach ($file in (Get-ChildItem -LiteralPath $dir -Filter '*.ps1' -Recurse -File -ErrorAction Stop)) {
                $candidates += [pscustomobject]@{ File = $file; FolderType = $folder }
            }
        } catch {
            throw "Could not list the scripts under '$dir': $($_.Exception.Message)"
        }
    }

    # Loose scripts directly under RootPath (not in user/ or device/) must carry #type.
    try {
        foreach ($file in (Get-ChildItem -LiteralPath $RootPath -Filter '*.ps1' -File -ErrorAction Stop)) {
            $candidates += [pscustomobject]@{ File = $file; FolderType = $null }
        }
    } catch {
        throw "Could not list the loose scripts in '$RootPath': $($_.Exception.Message)"
    }

    $results = @()
    foreach ($candidate in $candidates) {
        $fullPath = [System.IO.Path]::GetFullPath($candidate.File.FullName)
        if ($excluded.Contains($fullPath)) {
            Write-WizardDebug "Skipping the wizard's own file $fullPath"
            continue
        }
        if (-not $candidate.FolderType -and $excludedNames.Contains($candidate.File.Name)) {
            Write-WizardDebug "Skipping loose copy of a wizard file $fullPath"
            continue
        }
        # -AllowTypeOverride:$AllowTypeOverride forwards this function's own
        # switch parameter on to Get-ScriptMetadata. The colon form is needed
        # because $AllowTypeOverride holds a boolean-like value being passed
        # through, rather than just turning the switch on by its presence.
        $meta = Get-ScriptMetadata -Path $candidate.File.FullName -FolderType $candidate.FolderType -AllowTypeOverride:$AllowTypeOverride
        # Get-ScriptMetadata returns $null for scripts that shouldn't be
        # deployed (see its own comments), so only keep non-null results.
        if ($meta) { $results += $meta }
    }

    return $results
}
