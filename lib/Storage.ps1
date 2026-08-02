# Storage.ps1
# Writing the wizard's own on-disk state (the hash cache and the pre-change
# backups). Both are written the same way and for the same reason: a run that is
# interrupted or runs out of disk part-way through a write must not leave a file
# that still parses but is missing data.

# Saves any PowerShell value (object, array, hashtable, etc.) to disk as a JSON file.
function Save-WizardJsonFile {
    # Serialises to a sibling temp file and moves it into place. The move is the
    # only step that touches the real path, so the file on disk is either the
    # previous version or the complete new one - never a half-written mixture.
    # param() declares the function's inputs. [Parameter(Mandatory)] means the
    # caller must supply that argument or PowerShell will stop and prompt for it.
    param(
        [Parameter(Mandatory)][string]$Path,
        # [AllowNull()] lets $Value legally be $null even though it's Mandatory -
        # otherwise PowerShell would reject a caller passing $null on purpose.
        [Parameter(Mandatory)][AllowNull()]$Value,
        [int]$Depth = 10
    )

    # ConvertTo-Json turns the PowerShell object/hashtable into a JSON text string.
    # -Depth controls how many levels of nested objects/arrays it will serialise.
    $json = $Value | ConvertTo-Json -Depth $Depth
    # Build a unique temp filename next to the real one, e.g. "state.json.a1b2c3d4.tmp".
    # [guid]::NewGuid() generates a random unique ID so concurrent runs don't collide.
    $temp = "$Path.$([guid]::NewGuid().ToString('N').Substring(0, 8)).tmp"

    # try/catch: if anything in the try block throws an error, control jumps to catch.
    try {
        # Write the JSON text to the temp file first, not the real path.
        Set-Content -LiteralPath $temp -Value $json -ErrorAction Stop
        # -Force overwrites an existing destination; Move-Item is atomic within
        # a filesystem, which the temp file's placement alongside $Path assures.
        Move-Item -LiteralPath $temp -Destination $Path -Force -ErrorAction Stop
    } catch {
        # Something went wrong: clean up the leftover temp file (ignore errors if
        # it doesn't exist) and re-throw so the caller still sees the failure.
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        throw
    }
}

# Loads a JSON file previously written by Save-WizardJsonFile and returns it as
# PowerShell data (hashtable or object), or $null if there's nothing usable to read.
function Read-WizardJsonFile {
    # Reads JSON back as plain hashtables. Returns $null rather than throwing
    # when the file is absent or unreadable; callers decide whether that is fatal.
    param(
        [Parameter(Mandatory)][string]$Path,
        # [switch] makes this an on/off flag: pass -AsHashtable to enable it,
        # omit it to leave it $false. No value needed after the flag name.
        [switch]$AsHashtable
    )

    # Bail out early with $null if the file doesn't exist (PathType Leaf means "a file, not a folder").
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }

    # -Raw reads the whole file as one string instead of an array of lines.
    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    # An empty or whitespace-only file has nothing to parse, so treat it like "no data".
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }

    # ConvertFrom-Json parses the JSON text back into PowerShell data.
    # -AsHashtable returns hashtables (key/value lookups); without it, you get
    # PSCustomObject instances instead. The caller picks which shape they want.
    if ($AsHashtable) { return ($raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop) }
    return ($raw | ConvertFrom-Json -ErrorAction Stop)
}

# Hand-edited group names/paths often contain a literal backslash (e.g.
# CONTOSO\GroupName) that isn't valid inside a JSON string unless doubled.
# Rather than making people remember to escape it, walk the raw text and
# double any backslash that isn't already part of a recognised JSON escape
# (\" \\ \/ \b \f \n \r \t \u). Only meant for hand-edited files like
# e2e-metadata.json - machine-written JSON (the hash cache, backups) is
# already correctly escaped and never needs this.
function Repair-WizardJsonBackslashes {
    param([Parameter(Mandatory)][string]$Json)

    $validEscapes = '"\/bfnrtu'
    $sb = [System.Text.StringBuilder]::new()
    $inString = $false
    $i = 0
    $len = $Json.Length
    while ($i -lt $len) {
        $c = $Json[$i]
        if ($inString -and $c -eq '\') {
            $next = if ($i + 1 -lt $len) { $Json[$i + 1] } else { $null }
            if ($next -and $validEscapes.Contains($next)) {
                [void]$sb.Append($c).Append($next)
                $i += 2
            } else {
                [void]$sb.Append('\\')
                $i += 1
            }
            continue
        }
        if ($c -eq '"') { $inString = -not $inString }
        [void]$sb.Append($c)
        $i++
    }
    return $sb.ToString()
}

# Turns an arbitrary string (typically an Intune display name) into something
# safe to use as a filename component. An empty or all-punctuation input would
# collapse to '', so callers supply a -Fallback (e.g. a script id) to use instead.
function Get-WizardSafeFileName {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Fallback,
        [int]$MaxLength = 100
    )

    $safeName = ($Name -replace '[^a-zA-Z0-9._-]', '_')
    if ([string]::IsNullOrWhiteSpace($safeName.Replace('_', ''))) { $safeName = $Fallback }
    # Windows caps a path component at 255 characters and Intune allows long
    # display names, so leave room for whatever the caller appends.
    if ($safeName.Length -gt $MaxLength) { $safeName = $safeName.Substring(0, $MaxLength) }
    return $safeName
}
