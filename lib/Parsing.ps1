# Parsing.ps1
# Reads a .ps1 file and pulls out the wizard's meta-comment directives.
# Comments are left in the uploaded script content untouched - they're valid
# PowerShell comments and cause no harm at runtime on the endpoint.

function Get-WizardGroupRefValue {
    # Strips the optional surrounding double quotes from a #group: value.
    # Quotes are only needed for display names, but accepting them around a
    # GUID too means users don't have to remember which form takes them.
    param([Parameter(Mandatory)][string]$Raw)

    $value = $Raw.Trim()
    if ($value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"')) {
        $value = $value.Substring(1, $value.Length - 2)
    }
    return $value.Trim()
}

function Get-ScriptMetadata {
    param(
        [Parameter(Mandatory)][string]$Path,
        # Type inferred from the folder the script was found in (user/device),
        # or $null if the script was found loose and must carry a #type comment.
        [ValidateSet('user', 'device', $null)]
        [string]$FolderType
    )

    $lines = Get-Content -LiteralPath $Path
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Path)

    $displayName = $baseName
    $description = ''
    $type = $FolderType
    $noAssignments = $false
    $enforceSignatureCheck = $false
    $runAs32Bit = $true   # default: do NOT run in 64-bit PowerShell host
    $inDesc = $false
    $descLines = @()
    $groupRefs = @()
    $excludeGroupRefs = @()

    foreach ($line in $lines) {
        $trimmed = $line.Trim()

        if ($inDesc) {
            if ($trimmed -match '^#\s*enddesc\s*$') {
                $inDesc = $false
                continue
            }
            # Strip a single leading '#' and one optional space, keep the rest verbatim.
            $descLines += ($trimmed -replace '^#\s?', '')
            continue
        }

        if ($trimmed -match '^#\s*startdesc\s*$') {
            $inDesc = $true
            continue
        }
        if ($trimmed -match '^#\s*scriptname\s*:\s*"(?<name>[^"]+)"\s*$') {
            $displayName = $Matches['name']
            continue
        }
        if ($trimmed -match '^#\s*type\s*:\s*(?<type>user|device)\s*$') {
            $type = $Matches['type'].ToLowerInvariant()
            continue
        }
        if ($trimmed -match '^#\s*noassig(?:n)?ments?\s*$') {
            $noAssignments = $true
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
        $description = ($descLines -join "`n")
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

    $overlap = $groupRefs | Where-Object { $_ -in $excludeGroupRefs }
    if ($overlap) {
        throw "'$Path': group(s) listed as both #group: and #excludegroup: - $(($overlap | Select-Object -Unique) -join ', ')."
    }

    [pscustomobject]@{
        Path                  = $Path
        FileName              = [System.IO.Path]::GetFileName($Path)
        DisplayName           = $displayName
        Description           = $description
        Type                  = $type
        NoAssignments         = $noAssignments
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

function Find-WizardScripts {
    param(
        [Parameter(Mandatory)][string]$RootPath,
        # Full paths never to treat as deployable scripts. The caller passes the
        # wizard's own files: with the default -Path of the current directory,
        # Deploy-IntuneScripts.ps1 is itself a loose .ps1 under RootPath, which
        # otherwise warns on every run and would be uploadable to Intune the
        # moment anyone added a #type: comment to it.
        [string[]]$ExcludePath = @()
    )

    # Case-insensitive set of normalised full paths for O(1) exclusion checks.
    # Catches the usual case: the wizard is run from the same folder it scans.
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
        [void]$excluded.Add([System.IO.Path]::GetFullPath($p))
        [void]$excludedNames.Add([System.IO.Path]::GetFileName($p))
    }

    # Gather candidates first, then parse. Keeping the two phases separate avoids
    # accumulating results inside a script block, where the scoping rules differ
    # depending on how the block is invoked.
    $candidates = @()

    foreach ($folder in @('user', 'device')) {
        $dir = Join-Path $RootPath $folder
        if (Test-Path -LiteralPath $dir -PathType Container) {
            foreach ($file in (Get-ChildItem -LiteralPath $dir -Filter '*.ps1' -Recurse -File)) {
                $candidates += [pscustomobject]@{ File = $file; FolderType = $folder }
            }
        }
    }

    # Loose scripts directly under RootPath (not in user/ or device/) must carry #type.
    foreach ($file in (Get-ChildItem -LiteralPath $RootPath -Filter '*.ps1' -File -ErrorAction SilentlyContinue)) {
        $candidates += [pscustomobject]@{ File = $file; FolderType = $null }
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
        $meta = Get-ScriptMetadata -Path $candidate.File.FullName -FolderType $candidate.FolderType
        if ($meta) { $results += $meta }
    }

    return $results
}
