# Parsing.ps1
# Reads a .ps1 file and pulls out the wizard's meta-comment directives.
# Comments are left in the uploaded script content untouched - they're valid
# PowerShell comments and cause no harm at runtime on the endpoint.

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
    }

    if ($descLines.Count -gt 0) {
        $description = ($descLines -join "`n")
    }

    if (-not $type) {
        Write-Warning "Skipping '$Path': no user/device folder and no '#type:user|device' comment."
        return $null
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
    }
}

function Find-WizardScripts {
    param(
        [Parameter(Mandatory)][string]$RootPath
    )

    $results = @()

    foreach ($folder in @('user', 'device')) {
        $dir = Join-Path $RootPath $folder
        if (Test-Path -LiteralPath $dir -PathType Container) {
            Get-ChildItem -LiteralPath $dir -Filter '*.ps1' -Recurse -File | ForEach-Object {
                $meta = Get-ScriptMetadata -Path $_.FullName -FolderType $folder
                if ($meta) { $results += $meta }
            }
        }
    }

    # Loose scripts directly under RootPath (not in user/ or device/) must carry #type.
    Get-ChildItem -LiteralPath $RootPath -Filter '*.ps1' -File -ErrorAction SilentlyContinue | ForEach-Object {
        $meta = Get-ScriptMetadata -Path $_.FullName -FolderType $null
        if ($meta) { $results += $meta }
    }

    return $results
}
