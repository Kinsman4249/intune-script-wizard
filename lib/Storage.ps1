# Storage.ps1
# Writing the wizard's own on-disk state (the hash cache and the pre-change
# backups). Both are written the same way and for the same reason: a run that is
# interrupted or runs out of disk part-way through a write must not leave a file
# that still parses but is missing data.

function Save-WizardJsonFile {
    # Serialises to a sibling temp file and moves it into place. The move is the
    # only step that touches the real path, so the file on disk is either the
    # previous version or the complete new one - never a half-written mixture.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowNull()]$Value,
        [int]$Depth = 10
    )

    $json = $Value | ConvertTo-Json -Depth $Depth
    $temp = "$Path.$([guid]::NewGuid().ToString('N').Substring(0, 8)).tmp"

    try {
        Set-Content -LiteralPath $temp -Value $json -ErrorAction Stop
        # -Force overwrites an existing destination; Move-Item is atomic within
        # a filesystem, which the temp file's placement alongside $Path assures.
        Move-Item -LiteralPath $temp -Destination $Path -Force -ErrorAction Stop
    } catch {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Read-WizardJsonFile {
    # Reads JSON back as plain hashtables. Returns $null rather than throwing
    # when the file is absent or unreadable; callers decide whether that is fatal.
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$AsHashtable
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }

    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }

    if ($AsHashtable) { return ($raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop) }
    return ($raw | ConvertFrom-Json -ErrorAction Stop)
}
