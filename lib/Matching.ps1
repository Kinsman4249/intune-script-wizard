# Matching.ps1
# Content hashing (exact-duplicate detection) and fuzzy string similarity
# (near-duplicate name/description detection).

function Get-WizardFileHash {
    param([Parameter(Mandatory)][string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-WizardStringHash {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
    } finally {
        $sha.Dispose()
    }
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
