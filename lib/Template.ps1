# Template.ps1
# Tenant -> .ps1 template export. Regenerates the wizard's own meta-comment
# directives (#scriptname:, #type:, #group:, ...) from a live Intune script's
# Graph state, so a script edited in one tenant can be promoted into another
# via -SourceRepo. See handoff.md "Why this feature exists" for the design.
#
# Nothing in this file is wired into Deploy-IntuneScripts.ps1 yet - that is a
# later stage. Every function here is self-contained and independently
# testable by dot-sourcing the lib/ chain.

# The two lines that bound a template header inside a .ps1 file. Shared
# between the writer (New-WizardTemplateHeader) and the stripper
# (Remove-WizardTemplateHeader) so they can never drift out of sync with
# each other.
$script:WizardTemplateStartMarker = '# --- intune-script-wizard template ---'
$script:WizardTemplateEndMarker   = '# --- end intune-script-wizard template ---'

# One of these is created per -BackupAll run (not per script), so the group
# name cache and the "apply to the rest" prompt answer survive the whole loop.
function New-WizardTemplateRunState {
    [pscustomobject]@{
        # id -> display name, $null included for a resolved-but-missing group.
        # Shared with Resolve-WizardGroupDisplayName's own cache contract.
        GroupNames     = @{}
        # Flipped to $false the first time a group lookup fails for a reason
        # other than "not found" (i.e. GroupMember.Read.All was declined), so
        # the rest of the run stops trying and degrades to GUIDs quietly.
        GroupScopeOk   = $true
        # Case-insensitive: two tenant scripts whose sanitised names collide
        # must be caught regardless of case, same as the filesystem they're
        # about to land on.
        WrittenThisRun = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        # $null until an "apply to the rest" answer ('Write' or 'Skip') is
        # given at a conflict prompt; every later conflict then reuses it
        # instead of asking again.
        BulkAnswer     = $null
        Written        = 0
        Unchanged      = 0
        Excluded       = 0
        Skipped        = 0
        Failed         = 0
        Warnings       = @()
    }
}

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
# exactly what Get-ScriptMetadata (lib/Parsing.ps1) parses back out; see the
# mapping table in handoff.md.
function New-WizardTemplateHeader {
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][datetime]$ExportedAt,
        [Parameter(Mandatory)][string]$DisplayName,
        [AllowEmptyString()][string]$Description = '',
        [Parameter(Mandatory)][ValidateSet('user', 'device')][string]$Type,
        [switch]$EnforceSignatureCheck,
        # The tenant's actual RunAs32Bit value. #host:64 is only emitted when
        # this is $false - see the mapping table in handoff.md.
        [bool]$RunAs32Bit = $true,
        [switch]$NoAssignments,
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

    $warnings = @()
    $lines = @()
    $lines += $script:WizardTemplateStartMarker
    $lines += "# Exported from tenant $TenantId on $($ExportedAt.ToString('o')) by intune-script-wizard $script:WizardVersion."

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

    if ($NoAssignments) { $lines += '#noassignments' }

    # Deliberately not a live #typeoverride:yes - see handoff.md 4.2.1. The
    # doubled '#' below cannot match Parsing.ps1's directive regex (the
    # second '#' isn't whitespace), so this stays inert until a human deletes
    # one '#' on purpose.
    $lines += '##typeoverride:yes'
    $lines += "# Delete one '#' above (making it '#typeoverride:yes') to force this file's #type: over its folder when deployed."

    # Informational only - never a directive. See handoff.md 4.6 for why:
    # scope tag ids don't denote the same tag in another tenant, and Graph
    # rejects unknown ones outright.
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

# Shows a diff between a template file already on disk and the bytes about to
# replace it, for the [D]iff option at a conflict prompt. Prefers `git diff
# --no-index` (works even outside a repo, and understands binary vs text
# better than a naive line compare); falls back to Compare-Object when git
# isn't available. A failing diff only warns - it must never abort the
# prompt loop it was called from.
function Show-WizardTemplateDiff {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][byte[]]$NewBytes
    )

    $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) "intune-wizard-diff-$([guid]::NewGuid().ToString('N')).ps1"
    try {
        [System.IO.File]::WriteAllBytes($tempFile, $NewBytes)

        $gitAvailable = $false
        try {
            $global:LASTEXITCODE = 0
            & git --version 2>$null | Out-Null
            $gitAvailable = ($LASTEXITCODE -eq 0)
        } catch {
            $gitAvailable = $false
        }

        if ($gitAvailable) {
            # git diff exits non-zero when the files differ, which is the
            # expected/normal case here - not a command failure.
            & git diff --no-index -- $Path $tempFile
        } else {
            Compare-Object -ReferenceObject (Get-Content -LiteralPath $Path) -DifferenceObject (Get-Content -LiteralPath $tempFile) |
                Format-Table -AutoSize | Out-Host
        }
    } catch {
        Write-Warning "Could not produce a diff for '$Path': $($_.Exception.Message)."
    } finally {
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    }
}

# Decides what to do about a template file that already exists on disk.
# Returns 'Write', 'Unchanged', or 'Skip'. Order matters as much as the
# prompt text - see handoff.md 4.7 for why each check comes before the next.
function Resolve-WizardTemplateConflict {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][byte[]]$NewBytes,
        [Parameter(Mandatory)]$State
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'Write' }

    $existing = [System.IO.File]::ReadAllBytes($Path)
    if (Test-WizardBytesEqual -A $existing -B $NewBytes) {
        # Without this, every -BackupAll would prompt once per script,
        # forever - most runs touch nothing that changed since the last one.
        $State.Unchanged++
        return 'Unchanged'
    }

    if ($State.BulkAnswer) { return $State.BulkAnswer }

    if (-not (Test-WizardInteractive)) {
        Write-Warning "'$Path' already exists and differs from the tenant's current script, but this session cannot prompt; skipping it. Re-run interactively, or delete the file, to update it."
        return 'Skip'
    }

    while ($true) {
        # [string](...) matters: Read-Host returns $null at end-of-input, and
        # PowerShell's switch skips a $null input entirely - including its
        # default branch - which would fall all the way out of this function
        # with no return value at all. Coercing to a string first makes
        # end-of-input land on the documented default of Skip, the same trap
        # documented at Deploy-IntuneScripts.ps1:222-225.
        $choice = [string](Read-Host "'$Path' already exists and differs. [O]verwrite / [S]kip / [D]iff / overwrite [A]ll / skip a[L]l? (default: S)")
        switch -Regex ($choice) {
            '^[Oo]' { return 'Write' }
            '^[Dd]' { Show-WizardTemplateDiff -Path $Path -NewBytes $NewBytes; continue }
            '^[Aa]' { $State.BulkAnswer = 'Write'; return 'Write' }
            '^[Ll]' { $State.BulkAnswer = 'Skip'; return 'Skip' }
            default { return 'Skip' }
        }
    }
}

# Exports one tenant script's current state as a template file. The whole
# point of this function: everything it needs (the script object and its
# assignments) is already read by the time Backup-WizardScript calls it, so
# the only NEW Graph traffic this adds is reverse group lookups - capped at
# one per unique group per run via $State.GroupNames.
function Export-WizardScriptTemplate {
    param(
        [Parameter(Mandatory)]$Script,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Assignments,
        [Parameter(Mandatory)][string]$TemplateRoot,
        [Parameter(Mandatory)]$State
    )

    $type = if ($Script.RunAsAccount.ToString() -eq 'user') { 'user' } else { 'device' }
    $targetDir = Join-Path $TemplateRoot $type
    try {
        if (-not (Test-Path -LiteralPath $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir -Force -ErrorAction Stop | Out-Null
        }
    } catch {
        $State.Failed++
        Write-Warning "Could not create '$targetDir' to export a template for '$($Script.DisplayName)': $($_.Exception.Message)."
        return $null
    }

    $rawBytes = Get-WizardScriptContentBytes -Content $Script.ScriptContent
    if (-not $rawBytes) {
        $State.Failed++
        Write-Warning "'$($Script.DisplayName)' came back with no content; skipping its template export."
        return $null
    }

    # Strip any header this script already carries from an earlier export
    # BEFORE checking #notemplate, so a previously-written header can never
    # hide (or fake) the tag - see handoff.md 4.5 step 2.
    $bodyBytes = Remove-WizardTemplateHeader -Bytes $rawBytes

    if (Test-WizardTemplateExcluded -Bytes $bodyBytes) {
        $State.Excluded++
        $safeName = Get-WizardSafeFileName -Name $Script.DisplayName -Fallback "script-$($Script.Id)"
        $existingPath = Join-Path $targetDir "$safeName.ps1"
        if (Test-Path -LiteralPath $existingPath -PathType Leaf) {
            # Never auto-deleted: silently removing a file from a directory
            # the user may have since put under git and hand-curated is the
            # wrong default.
            Write-Warning "'$($Script.DisplayName)' now carries #notemplate, but a template file still exists at '$existingPath' from an earlier export. It is not deleted automatically - remove it by hand once you're sure it should no longer be templated."
        }
        return $null
    }

    $includeGroups = @()
    $excludeGroups = @()
    $unsupportedWarnings = @()
    $noAssignments = ($Assignments.Count -eq 0)

    foreach ($assignment in $Assignments) {
        $target = $assignment['target']
        if (-not $target) { continue }
        switch ([string]$target['@odata.type']) {
            '#microsoft.graph.groupAssignmentTarget' {
                $groupId = [string]$target['groupId']
                $includeGroups += @{ Id = $groupId; Name = (Resolve-WizardGroupDisplayName -Id $groupId -State $State) }
            }
            '#microsoft.graph.exclusionGroupAssignmentTarget' {
                $groupId = [string]$target['groupId']
                $excludeGroups += @{ Id = $groupId; Name = (Resolve-WizardGroupDisplayName -Id $groupId -State $State) }
            }
            '#microsoft.graph.allLicensedUsersAssignmentTarget' { }
            '#microsoft.graph.allDevicesAssignmentTarget' { }
            default {
                $unsupportedWarnings += "Assignment target of type '$($target['@odata.type'])' on '$($Script.DisplayName)' cannot be expressed by any #group:/#excludegroup: directive; the JSON backup is the record of it."
            }
        }
    }

    $newLine = if (Test-WizardBodyUsesCrlf -Bytes $bodyBytes) { "`r`n" } else { "`n" }

    $headerResult = New-WizardTemplateHeader `
        -TenantId (Get-MgContext).TenantId `
        -ExportedAt (Get-Date) `
        -DisplayName $Script.DisplayName `
        -Description ([string]$Script.Description) `
        -Type $type `
        -EnforceSignatureCheck:([bool]$Script.EnforceSignatureCheck) `
        -RunAs32Bit (Get-WizardScriptRunAs32Bit -Script $Script) `
        -NoAssignments:$noAssignments `
        -IncludeGroups $includeGroups `
        -ExcludeGroups $excludeGroups `
        -UnsupportedTargetWarnings $unsupportedWarnings `
        -RoleScopeTagIds @($Script.RoleScopeTagIds) `
        -OriginalFileName $Script.FileName `
        -NewLine $newLine

    foreach ($w in $headerResult.Warnings) {
        Write-Warning "'$($Script.DisplayName)': $w"
        $State.Warnings += $w
    }

    $headerBytes = [System.Text.Encoding]::UTF8.GetBytes($headerResult.Text)
    $finalBytes = $headerBytes + $bodyBytes

    # No timestamp in the filename - a template's value is a stable path
    # across exports, unlike a backup's.
    $safeName = Get-WizardSafeFileName -Name $Script.DisplayName -Fallback "script-$($Script.Id)"
    $fileName = "$safeName.ps1"
    if ($State.WrittenThisRun.Contains($fileName)) {
        # Two tenant scripts sanitising to the same name: append -2, -3, ...
        # and warn. Never prompts - this is a naming collision within THIS
        # run, not a conflict with something already on disk.
        $attempt = 2
        while ($State.WrittenThisRun.Contains("$safeName-$attempt.ps1")) { $attempt++ }
        $fileName = "$safeName-$attempt.ps1"
        Write-Warning "Two tenant scripts sanitise to the same template filename '$safeName.ps1'; '$($Script.DisplayName)' was exported as '$fileName' instead."
    }
    $path = Join-Path $targetDir $fileName

    $action = Resolve-WizardTemplateConflict -Path $path -NewBytes $finalBytes -State $State
    if ($action -ne 'Write') {
        if ($action -eq 'Skip') { $State.Skipped++ }
        return $null
    }

    $temp = "$path.$([guid]::NewGuid().ToString('N').Substring(0, 8)).tmp"
    try {
        [System.IO.File]::WriteAllBytes($temp, $finalBytes)
        Move-Item -LiteralPath $temp -Destination $path -Force -ErrorAction Stop
    } catch {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        $State.Failed++
        Write-Warning "Could not write the template for '$($Script.DisplayName)' to '$path': $($_.Exception.Message)."
        return $null
    }

    [void]$State.WrittenThisRun.Add($fileName)
    $State.Written++
    Write-Host "  Exported template '$($Script.DisplayName)' -> $path" -ForegroundColor DarkGray
    return $path
}

# Prints the final tally at the end of a run that exported templates, in the
# style of Write-WizardRunSummary (Deploy-IntuneScripts.ps1).
function Write-WizardTemplateSummary {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$TemplateRoot
    )

    Write-Host ""
    Write-Host "Templates: $($State.Written) written, $($State.Unchanged) unchanged, $($State.Excluded) excluded (#notemplate), $($State.Skipped) skipped, $($State.Failed) failed"
    Write-Host "  -> $TemplateRoot" -ForegroundColor DarkGray
    Write-Host "  Deploy them to another tenant with: -SourceRepo <url>  (or -Path $TemplateRoot)" -ForegroundColor DarkGray
}
