# Matching.ps1
# Content hashing (exact-duplicate detection) and fuzzy string similarity
# (near-duplicate name/description detection).

function Get-WizardFileHash {
    # Lower-cased so it compares safely against the hashes GraphOps computes,
    # even if a caller later switches to -ceq or a hashtable lookup.
    param([Parameter(Mandatory)][string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-LevenshteinDistance {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$A,
        [Parameter(Mandatory)][AllowEmptyString()][string]$B
    )

    $lenA = $A.Length
    $lenB = $B.Length
    if ($lenA -eq 0) { return $lenB }
    if ($lenB -eq 0) { return $lenA }

    $prev = 0..$lenB
    for ($i = 1; $i -le $lenA; $i++) {
        $curr = New-Object 'int[]' ($lenB + 1)
        $curr[0] = $i
        for ($j = 1; $j -le $lenB; $j++) {
            $cost = if ($A[$i - 1] -eq $B[$j - 1]) { 0 } else { 1 }
            $curr[$j] = [Math]::Min(
                [Math]::Min($curr[$j - 1] + 1, $prev[$j] + 1),
                $prev[$j - 1] + $cost
            )
        }
        $prev = $curr
    }
    return $prev[$lenB]
}

function Get-StringSimilarity {
    # Returns a 0.0-1.0 similarity ratio (1.0 = identical).
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$A,
        [Parameter(Mandatory)][AllowEmptyString()][string]$B
    )

    $a = $A.Trim().ToLowerInvariant()
    $b = $B.Trim().ToLowerInvariant()
    $maxLen = [Math]::Max($a.Length, $b.Length)
    if ($maxLen -eq 0) { return 1.0 }

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

    if ($nameScore -lt $script:DescriptionCompareFloor) { return $nameScore }
    if ([string]::IsNullOrWhiteSpace($LocalDescription) -or
        [string]::IsNullOrWhiteSpace($ExistingDescription)) {
        return $nameScore
    }

    $max = $script:DescriptionCompareMaxLength
    $a = if ($LocalDescription.Length    -gt $max) { $LocalDescription.Substring(0, $max) }    else { $LocalDescription }
    $b = if ($ExistingDescription.Length -gt $max) { $ExistingDescription.Substring(0, $max) } else { $ExistingDescription }

    $descScore = Get-StringSimilarity -A $a -B $b
    return (0.7 * $nameScore) + (0.3 * $descScore)
}
