# TemplateHeader.ps1
# The pure, side-effect-free core of template export: byte helpers, stripping a
# previously-written header off a script body, and building a fresh header from
# a script's settings. No Graph calls and no disk access, which is what makes
# these the directly unit-testable heart of the feature. The orchestration that
# reads the tenant and writes the files lives in Template.ps1.

# The two lines that bound a template header inside a .ps1 file. Shared
# between the writer (New-WizardTemplateHeader) and the stripper
# (Remove-WizardTemplateHeader) so they can never drift out of sync with
# each other.
$script:WizardTemplateStartMarker = '# --- intune-script-wizard template ---'
$script:WizardTemplateEndMarker   = '# --- end intune-script-wizard template ---'

# Byte-for-byte "does A equal B" - .NET has no single built-in for two byte
# arrays, and ConvertTo comparisons (base64 strings, etc) would be a detour
# for something this cheap to do directly.
function Test-WizardBytesEqual {
    param([Parameter(Mandatory)][byte[]]$A, [Parameter(Mandatory)][byte[]]$B)

    if ($A.Length -ne $B.Length) { return $false }
    for ($i = 0; $i -lt $A.Length; $i++) {
        if ($A[$i] -ne $B[$i]) { return $false }
    }
    return $true
}

# Plain byte-pattern search (like .NET's string.IndexOf, but for byte[]).
# Used to find the template end marker without ever decoding the body through
# a text encoding, which would risk corrupting content the caller has
# promised to preserve byte-for-byte.
function Find-WizardByteSequence {
    param(
        [Parameter(Mandatory)][byte[]]$Haystack,
        [Parameter(Mandatory)][byte[]]$Needle,
        [int]$StartAt = 0
    )

    if ($Needle.Length -eq 0) { return $StartAt }
    for ($i = $StartAt; $i -le $Haystack.Length - $Needle.Length; $i++) {
        $match = $true
        for ($j = 0; $j -lt $Needle.Length; $j++) {
            if ($Haystack[$i + $j] -ne $Needle[$j]) { $match = $false; break }
        }
        if ($match) { return $i }
    }
    return -1
}

# Sniffs whether a body's first line break is CRLF or bare LF, so a template
# header can be written in the same style and git diffs on a re-export stay
# clean instead of showing every line as changed.
function Test-WizardBodyUsesCrlf {
    param([Parameter(Mandatory)][byte[]]$Bytes)

    for ($i = 0; $i -lt $Bytes.Length; $i++) {
        if ($Bytes[$i] -eq 0x0A) {
            return ($i -gt 0 -and $Bytes[$i - 1] -eq 0x0D)
        }
    }
    return $false
}

# Decodes body bytes and checks every line against the shared #notemplate
# pattern from Parsing.ps1. Kept as a byte-in function (rather than taking a
# pre-decoded string) so every caller goes through the same decode step and
# can't accidentally check the wrong copy of the content.
function Test-WizardTemplateExcluded {
    param([Parameter(Mandatory)][AllowNull()][byte[]]$Bytes)

    if (-not $Bytes -or $Bytes.Length -eq 0) { return $false }
    $text = [System.Text.Encoding]::UTF8.GetString($Bytes)
    foreach ($line in ($text -split "`r?`n")) {
        if ($line.Trim() -match $script:WizardNoTemplatePattern) { return $true }
    }
    return $false
}

# Strips a previously-written template header off a tenant script's content,
# identified by its two marker lines. Load-bearing, not a nicety: a deployed
# template's header becomes part of the uploaded script body, so without this
# the next -BackupAll on that tenant would export it back out with a second
# header stacked on top, and every round trip would push the body further
# from the original.
#
# Only strips when the content starts with the start marker AND the end
# marker is found within roughly the first 200 lines - anything else (a
# script that merely mentions the marker text in a comment, or one where the
# "header" isn't actually at the top) passes through untouched.
function Remove-WizardTemplateHeader {
    param([Parameter(Mandatory)][byte[]]$Bytes)

    # The header is always written as plain ASCII/UTF8 text with no BOM (see
    # New-WizardTemplateHeader), so a byte-for-byte match against UTF8-encoded
    # marker text works regardless of what encoding the body itself uses.
    $startBytes = [System.Text.Encoding]::UTF8.GetBytes($script:WizardTemplateStartMarker)
    $endBytes   = [System.Text.Encoding]::UTF8.GetBytes($script:WizardTemplateEndMarker)

    if ($Bytes.Length -lt $startBytes.Length) { return ,$Bytes }
    for ($i = 0; $i -lt $startBytes.Length; $i++) {
        if ($Bytes[$i] -ne $startBytes[$i]) { return ,$Bytes }
    }

    $endIndex = Find-WizardByteSequence -Haystack $Bytes -Needle $endBytes -StartAt $startBytes.Length
    if ($endIndex -lt 0) { return ,$Bytes }

    $newlineCount = 0
    for ($i = 0; $i -lt $endIndex; $i++) {
        if ($Bytes[$i] -eq 0x0A) { $newlineCount++ }
    }
    if ($newlineCount -gt 200) { return ,$Bytes }

    # Skip past the rest of the end-marker line (up to and including its
    # newline), so what's returned is exactly the body that follows it.
    $cursor = $endIndex + $endBytes.Length
    while ($cursor -lt $Bytes.Length -and $Bytes[$cursor] -ne 0x0A) { $cursor++ }
    if ($cursor -lt $Bytes.Length) { $cursor++ }

    $bodyLength = $Bytes.Length - $cursor
    if ($bodyLength -le 0) { return ,([byte[]]@()) }
    $body = [byte[]]::new($bodyLength)
    [System.Array]::Copy($Bytes, $cursor, $body, 0, $bodyLength)
    return ,$body
}

# Formats one #group:/#excludegroup: line from a reverse-resolved group
# entry (a hashtable with Id and Name, Name being $null when the id couldn't
# be resolved to a display name at all). Two data-loss traps are guarded
# here, each falling back to the bare GUID rather than emitting something
# that would silently resolve to the wrong group later:
#   - a display name that itself parses as a GUID (ambiguous with a literal
#     GUID reference)
#   - a display name containing '"', which #group:"..." cannot round-trip
# Every fallback is reported as a warning string, never a thrown error - a
# deleted or unresolvable group must not fail the whole export.
function Format-WizardGroupDirective {
    param(
        [Parameter(Mandatory)][hashtable]$Entry,
        [Parameter(Mandatory)][ValidateSet('group', 'excludegroup')][string]$Directive
    )

    $id = [string]$Entry['Id']
    $name = $Entry['Name']

    if ($null -eq $name) {
        return [pscustomobject]@{
            Line    = "#${Directive}:$id"
            Warning = "Group $id could not be resolved to a display name (deleted, or the $script:GroupReadScope scope was not granted); exported as its GUID. Verify it still exists before deploying this template."
        }
    }

    $parsed = [guid]::Empty
    if ([guid]::TryParse($name, [ref]$parsed)) {
        return [pscustomobject]@{
            Line    = "#${Directive}:$id"
            Warning = "Group '$name' ($id) has a display name that itself looks like a GUID; exported as its actual GUID to avoid ambiguity."
        }
    }

    if (([string]$name).Contains('"')) {
        return [pscustomobject]@{
            Line    = "#${Directive}:$id"
            Warning = "Group '$name' ($id) has a display name containing a double quote, which cannot be safely quoted; exported as its GUID instead."
        }
    }

    return [pscustomobject]@{
        Line    = "#${Directive}:`"$name`""
        Warning = $null
    }
}

# Builds the template header text for one script. Pure: no Graph calls, no
# disk access, nothing but string formatting - which is what makes it the
# directly-unit-testable core of the whole feature. Everything it emits is
# exactly what Get-ScriptMetadata (lib/Parsing.ps1) parses back out.
function New-WizardTemplateHeader {
    param(
        [Parameter(Mandatory)][datetime]$ExportedAt,
        [Parameter(Mandatory)][string]$DisplayName,
        [AllowEmptyString()][string]$Description = '',
        [Parameter(Mandatory)][ValidateSet('user', 'device')][string]$Type,
        [switch]$EnforceSignatureCheck,
        # The tenant's actual RunAs32Bit value. #host:64 is only emitted when
        # this is $false (32-bit is the default, so it needs no directive).
        [bool]$RunAs32Bit = $true,
        [switch]$NoAssignments,
        # Set when the tenant's live assignments included the default target
        # matching this script's own #type: - whether alone, or alongside
        # specific groups (a combination '#group:' by itself cannot express).
        [switch]$AssignAll,
        # Set when the tenant's live assignments ALSO included the default
        # target that does NOT match this script's own #type: - a script can
        # be assigned to both all-devices and all-licensed-users at once,
        # independent of which host it runs under, which -AssignAll alone
        # cannot express since it only ever covers the #type:-matching one.
        [switch]$AssignDevices,
        [switch]$AssignUsers,
        # Each entry: @{ Id = '<guid>'; Name = '<display name>' (or $null) }
        [array]$IncludeGroups = @(),
        [array]$ExcludeGroups = @(),
        # Plain-text warnings for assignment targets that carry no group id at
        # all (e.g. one with an assignment filter) and so can't be expressed
        # by any directive.
        [string[]]$UnsupportedTargetWarnings = @(),
        [string[]]$RoleScopeTagIds = @(),
        [string]$OriginalFileName,
        [string]$NewLine = "`n"
    )

    # Mirrors the check Parsing.ps1 itself makes on the way back in - if this
    # ever fired it would mean the caller built its group lists wrong, since
    # NoAssignments is only ever true when there were zero assignments to
    # reverse-resolve in the first place.
    if ($NoAssignments -and ($IncludeGroups.Count -gt 0 -or $ExcludeGroups.Count -gt 0)) {
        throw "New-WizardTemplateHeader: -NoAssignments cannot be combined with -IncludeGroups/-ExcludeGroups; Parsing.ps1 rejects that combination on the way back in."
    }
    if ($NoAssignments -and $AssignAll) {
        throw "New-WizardTemplateHeader: -NoAssignments cannot be combined with -AssignAll; Parsing.ps1 rejects that combination on the way back in."
    }
    if ($NoAssignments -and ($AssignDevices -or $AssignUsers)) {
        throw "New-WizardTemplateHeader: -NoAssignments cannot be combined with -AssignDevices/-AssignUsers; Parsing.ps1 rejects that combination on the way back in."
    }

    $warnings = @()
    $lines = @()
    $lines += $script:WizardTemplateStartMarker
    # No tenant id here: this line, and the whole template file, is what gets
    # pushed to a remote git repo (see lib/RepoBackup.ps1) - possibly one
    # shared beyond this tenant's own admins - so nothing that identifies the
    # tenant belongs in it.
    $lines += "# Exported on $($ExportedAt.ToString('o')) by intune-script-wizard $script:WizardVersion."

    # Trap 1: a '"' in the display name cannot round-trip through
    # #scriptname:"..." (the parser regex is "([^"]+)"). Strip it and warn
    # rather than silently mangling the name or corrupting the directive.
    $safeDisplayName = $DisplayName
    if ($safeDisplayName.Contains('"')) {
        $safeDisplayName = $safeDisplayName.Replace('"', '')
        $warning = "Display name '$DisplayName' contains a double quote, which #scriptname: cannot round-trip; exported as '$safeDisplayName'."
        $warnings += $warning
        $lines += "# WARNING: $warning"
    }
    $lines += "#scriptname:`"$safeDisplayName`""
    $lines += "#type:$Type"

    if ($Description) {
        $descLines = @($Description -split "`r?`n")
        # Trap 2: a description line reading exactly "enddesc" (or
        # "startdesc") becomes "# enddesc" inside the block, which the parser
        # reads as the block's real end marker - silently truncating
        # everything after it. The format has no escape for this, so fall
        # back to plain comments (no directive at all) rather than risk it.
        $trapped = @($descLines | Where-Object { $_.Trim() -match '^\s*(start|end)desc\s*$' })
        if ($trapped.Count -gt 0) {
            $warning = "Description for '$DisplayName' contains a line reading exactly 'startdesc' or 'enddesc', which would truncate the description inside a #startdesc/#enddesc block; exported as plain comments instead."
            $warnings += $warning
            $lines += "# WARNING: $warning"
            foreach ($descLine in $descLines) { $lines += "# $descLine" }
        } else {
            $lines += '#startdesc'
            foreach ($descLine in $descLines) { $lines += "# $descLine" }
            $lines += '#enddesc'
        }
    }

    if ($EnforceSignatureCheck) { $lines += '#scriptcheck:yes' }
    if (-not $RunAs32Bit) { $lines += '#host:64' }

    foreach ($entry in $IncludeGroups) {
        $result = Format-WizardGroupDirective -Entry $entry -Directive 'group'
        $lines += $result.Line
        if ($result.Warning) { $warnings += $result.Warning; $lines += "# WARNING: $($result.Warning)" }
    }
    foreach ($entry in $ExcludeGroups) {
        $result = Format-WizardGroupDirective -Entry $entry -Directive 'excludegroup'
        $lines += $result.Line
        if ($result.Warning) { $warnings += $result.Warning; $lines += "# WARNING: $($result.Warning)" }
    }
    foreach ($w in $UnsupportedTargetWarnings) {
        $warnings += $w
        $lines += "# WARNING: $w"
    }

    if ($AssignAll) { $lines += '#assignall' }
    if ($AssignDevices) { $lines += '#assigndevices' }
    if ($AssignUsers) { $lines += '#assignusers' }
    if ($NoAssignments) { $lines += '#noassignments' }

    # Deliberately not a live #typeoverride:yes. The doubled '#' below cannot
    # match Parsing.ps1's directive regex (the second '#' isn't whitespace), so
    # this stays inert until a human deletes one '#' on purpose - a regular
    # export must never silently re-enable an override.
    $lines += '##typeoverride:yes'
    $lines += "# Delete one '#' above (making it '#typeoverride:yes') to force this file's #type: over its folder when deployed."

    # Informational only - never a directive: a scope tag id doesn't denote the
    # same tag in another tenant, and Graph rejects unknown ones outright, so
    # carrying it as a live directive would break cross-tenant promotion.
    $meaningfulTags = @($RoleScopeTagIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) -and [string]$_ -ne '0' })
    if ($meaningfulTags.Count -gt 0) {
        $allTags = @($RoleScopeTagIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
        $lines += "# roleScopeTagIds: $($allTags -join ', ')"
    }

    if ($OriginalFileName) {
        $lines += "# original Intune fileName: $OriginalFileName"
    }

    $lines += $script:WizardTemplateEndMarker

    [pscustomobject]@{
        Text     = (($lines -join $NewLine) + $NewLine)
        Warnings = @($warnings)
    }
}

# Strips the "# Exported ... by intune-script-wizard ..." line that
# New-WizardTemplateHeader stamps fresh on every export, before an
# unchanged-content comparison. Without this, that line alone (never
# byte-identical between two separate runs, no matter how close together)
# would make Resolve-WizardTemplateConflict's equality check fail every
# single time, defeating the "Unchanged" path it exists for - see the
# comment on that check below. The pattern also matches the older
# "Exported from tenant <id> on ..." form so a template exported by a
# pre-redaction version of the wizard still compares as unchanged.
function Get-WizardTemplateComparisonBytes {
    param([Parameter(Mandatory)][byte[]]$Bytes)

    $text = [System.Text.Encoding]::UTF8.GetString($Bytes)
    $lines = @($text -split "`r?`n" | Where-Object { $_ -notmatch '^# Exported .* by intune-script-wizard ' })
    return [System.Text.Encoding]::UTF8.GetBytes($lines -join "`n")
}
