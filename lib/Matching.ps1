# Matching.ps1
# Content hashing (exact-duplicate detection) and fuzzy string similarity
# (near-duplicate name/description detection).

# Turns a script's content into a short "fingerprint" (hash) so two scripts with
# identical content can be recognized as duplicates without comparing every byte.
function Get-WizardBytesHash {
    # SHA256 of a byte array, lower-cased hex. Used for content downloaded from
    # Intune; the local-file side goes through Get-WizardFileHash. Both must
    # produce the same casing or exact-duplicate detection silently stops working.
    param([Parameter(Mandatory)][byte[]]$Bytes)

    # SHA256 is a one-way hashing algorithm: same input always gives the same
    # fixed-length output, and even a tiny change in input changes the output a lot.
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        # ComputeHash returns raw bytes; ToString('x2') turns each byte into a
        # 2-digit hex string (like "4f"), then -join '' glues them into one string.
        return (($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally {
        # .NET crypto objects hold unmanaged resources, so Dispose() must run even
        # if ComputeHash throws - that's what try/finally guarantees here.
        $sha.Dispose()
    }
}

# Computes the same kind of fingerprint as above, but reads it straight from a
# file on disk instead of a byte array already in memory.
function Get-WizardFileHash {
    # Lower-cased so it compares safely against the hashes GraphOps computes,
    # even if a caller later switches to -ceq or a hashtable lookup.
    param([Parameter(Mandatory)][string]$Path)

    try {
        # Get-FileHash is a built-in PowerShell cmdlet that hashes a file's contents.
        # -LiteralPath (vs -Path) means the string is used exactly as given, without
        # treating characters like [ ] as wildcards.
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    } catch {
        # The file was scanned minutes ago, so it can have been moved, deleted or
        # locked by an editor since. Name it: "access denied" on its own is not
        # enough to find the culprit in a folder of fifty scripts.
        throw "Could not read '$Path' to hash it: $($_.Exception.Message). It may have been moved, deleted or locked since the scan started."
    }
}

# Levenshtein distance = the minimum number of single-character edits (insert,
# delete, or substitute) needed to turn string A into string B. Lower = more
# similar; 0 means the strings are identical. Example: "cat" -> "cart" is 1 (one
# insert). This is the classic "edit distance" algorithm used by spell-checkers.
function Get-LevenshteinDistance {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$A,
        [Parameter(Mandatory)][AllowEmptyString()][string]$B
    )

    $lenA = $A.Length
    $lenB = $B.Length
    # If one string is empty, the distance is just the length of the other
    # (every character in it would need to be inserted/deleted).
    if ($lenA -eq 0) { return $lenB }
    if ($lenB -eq 0) { return $lenA }

    # This works by building a grid where cell [i,j] holds the edit distance
    # between the first i characters of A and the first j characters of B. Only
    # the previous row is kept ($prev), not the whole grid, to save memory -
    # each new row ($curr) only ever needs the row above it to be computed.
    # $prev starts as 0,1,2,...,lenB: the distance from an empty A to each
    # growing prefix of B (i.e. that many inserts).
    $prev = 0..$lenB
    for ($i = 1; $i -le $lenA; $i++) {
        $curr = New-Object 'int[]' ($lenB + 1)
        $curr[0] = $i
        for ($j = 1; $j -le $lenB; $j++) {
            # No cost if the characters already match; otherwise 1 for a substitution.
            $cost = if ($A[$i - 1] -eq $B[$j - 1]) { 0 } else { 1 }
            # Take the cheapest of: delete a char, insert a char, or substitute a char.
            $curr[$j] = [Math]::Min(
                [Math]::Min($curr[$j - 1] + 1, $prev[$j] + 1),
                $prev[$j - 1] + $cost
            )
        }
        # This row becomes "previous" for the next iteration.
        $prev = $curr
    }
    # The bottom-right cell of the grid holds the answer for the full strings.
    return $prev[$lenB]
}

# Converts the raw edit-distance count above into an easier-to-use 0.0-1.0 score,
# so callers don't need to know the string lengths to judge "how similar".
function Get-StringSimilarity {
    # Returns a 0.0-1.0 similarity ratio (1.0 = identical).
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$A,
        [Parameter(Mandatory)][AllowEmptyString()][string]$B
    )

    # Trim whitespace and lower-case so "MyScript" and "myscript " compare equal.
    $a = $A.Trim().ToLowerInvariant()
    $b = $B.Trim().ToLowerInvariant()
    $maxLen = [Math]::Max($a.Length, $b.Length)
    if ($maxLen -eq 0) { return 1.0 }

    # Normalize distance by the longer string's length, then flip it so 1.0 means
    # "no edits needed" (identical) instead of "many edits needed".
    $distance = Get-LevenshteinDistance -A $a -B $b
    return 1.0 - ($distance / $maxLen)
}

# Similarity at/above this (but below 1.0) counts as a "fuzzy" match worth
# prompting about. Below this, names are treated as unrelated.
$script:FuzzyMatchThreshold = 0.75

# Below this name similarity a pair is so clearly unrelated that comparing the
# descriptions too would only waste time. Levenshtein is O(n*m) and interpreted
# here, so this short-circuit matters once a tenant has many scripts.
$script:DescriptionCompareFloor = 0.50

# Descriptions are truncated to this many characters before comparison. Keeps
# the O(n*m) cost bounded; the opening lines carry the distinguishing text anyway.
$script:DescriptionCompareMaxLength = 200

# The top-level "how similar are these two scripts" function that the rest of
# the wizard calls (see Resolve-FuzzyAction / Invoke-WizardScriptDeployment in
# Deploy-IntuneScripts.ps1) to warn about likely near-duplicates before deploying.
function Get-WizardMatchScore {
    # Combined name/description similarity, as documented in the wizard's help.
    # When either side has no description there is nothing to compare, so the
    # name score stands alone. Otherwise the name dominates (70/30): two scripts
    # with near-identical names but genuinely different descriptions are more
    # likely to be different scripts than a rename of the same one.
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$LocalName,
        [Parameter(Mandatory)][AllowEmptyString()][string]$LocalDescription,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExistingName,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExistingDescription
    )

    $nameScore = Get-StringSimilarity -A $LocalName -B $ExistingName

    # Names are already too different to bother comparing descriptions - see the
    # $script:DescriptionCompareFloor comment above for why this early-out exists.
    if ($nameScore -lt $script:DescriptionCompareFloor) { return $nameScore }
    if ([string]::IsNullOrWhiteSpace($LocalDescription) -or
        [string]::IsNullOrWhiteSpace($ExistingDescription)) {
        return $nameScore
    }

    # Cap both descriptions to the same max length before comparing (see
    # $script:DescriptionCompareMaxLength above). The one-line if/else here is
    # PowerShell's inline conditional: "if too long, take just the first $max
    # characters; otherwise use the string as-is."
    $max = $script:DescriptionCompareMaxLength
    $a = if ($LocalDescription.Length    -gt $max) { $LocalDescription.Substring(0, $max) }    else { $LocalDescription }
    $b = if ($ExistingDescription.Length -gt $max) { $ExistingDescription.Substring(0, $max) } else { $ExistingDescription }

    $descScore = Get-StringSimilarity -A $a -B $b
    # Weighted blend: 70% name similarity + 30% description similarity.
    return (0.7 * $nameScore) + (0.3 * $descScore)
}
