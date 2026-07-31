#Requires -Version 7.0
<#
.SYNOPSIS
    Verifies that everything under a deployed -Path root really landed in the
    tenant byte for byte, with the settings and assignments its meta comments
    asked for.

.DESCRIPTION
    Run this straight after `Deploy-IntuneScripts.ps1 -Path <root>` against a
    dev tenant. It parses the same local scripts the wizard did, reads each one
    back out of Intune, and checks:

      - the script exists in the tenant under its expected display name
      - the uploaded content is BYTE IDENTICAL to the local file (SHA256 of the
        local bytes vs SHA256 of the bytes Graph hands back). A hash comparison
        catches the encoding-level damage an eyeball never will: a BOM added or
        stripped, CRLF flipped to LF, a trailing newline lost, or content that
        round-tripped through the wrong base64 handling.
      - runAsAccount matches the user//device/ folder (or #type:)
      - enforceSignatureCheck matches #scriptcheck:
      - runAs32BitOnWindows64 matches #host:
      - the assignment set matches #group:/#excludegroup:/#noassignments, target
        for target, with no extras left over from an earlier run

    This is the automated half of generated/CHECKLIST.md: everything here is a
    fact the tenant can be asked for. The checklist still covers what it can't -
    that a script actually *runs* correctly on a real device or user.

    Read-only. It never creates, updates or deletes anything in the tenant, so
    it is safe to re-run at any point.

.PARAMETER Path
    The deployed -Path root to verify, e.g. e2e-tests/generated/main. Must be
    the same folder that was passed to Deploy-IntuneScripts.ps1.

.PARAMETER AllowTypeOverride
    Pass this if the deploy being verified was run with -AllowTypeOverride, so
    the expected types are worked out the same way.

.PARAMETER AcceptModuleInstall
    Install missing required Graph modules without prompting.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [switch]$AllowTypeOverride,
    [switch]$AcceptModuleInstall
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$repo = Split-Path -Parent $here

. (Join-Path $repo 'lib/Errors.ps1')
. (Join-Path $repo 'lib/Logging.ps1')
. (Join-Path $repo 'lib/Storage.ps1')
. (Join-Path $repo 'lib/Prereqs.ps1')
. (Join-Path $repo 'lib/Parsing.ps1')
. (Join-Path $repo 'lib/Matching.ps1')
. (Join-Path $repo 'lib/GraphOps.ps1')

if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    throw "-Path '$Path' does not exist or is not a folder."
}
$resolvedPath = (Resolve-Path -LiteralPath $Path).Path

$script:Passed = 0
$script:Failed = 0
function Check {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) {
        Write-Host "  PASS  $Name" -ForegroundColor Green
        $script:Passed++
    } else {
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        if ($Detail) { Write-Host "        $Detail" -ForegroundColor Red }
        $script:Failed++
    }
}

# Renders one assignment target as a short comparable string, so expected and
# actual sets can be compared (and printed) without wading through nested JSON.
function ConvertTo-TargetKey {
    param([Parameter(Mandatory)][AllowNull()]$Target)
    if (-not $Target) { return '<none>' }
    $type = [string]$Target['@odata.type'] -replace '^#microsoft\.graph\.', ''
    $groupId = [string]$Target['groupId']
    if ($groupId) { return "$type($groupId)" }
    return $type
}

$localScripts = @(Find-WizardScripts -RootPath $resolvedPath -AllowTypeOverride:$AllowTypeOverride)
if ($localScripts.Count -eq 0) {
    throw "No scripts found under '$resolvedPath'. Point -Path at a deployed root such as e2e-tests/generated/main."
}

Write-Host ""
Write-Host "Verifying $($localScripts.Count) deployed script(s) from $resolvedPath" -ForegroundColor Cyan

Test-WizardPSVersion
Install-WizardModules -AcceptInstall:$AcceptModuleInstall
Import-WizardModules

# Group display names in the local set have to be resolved to ids before the
# expected assignment targets can be compared against what the tenant holds.
$additionalScopes = @()
if (Test-WizardNeedsGroupScope -Scripts $localScripts) { $additionalScopes += $script:GroupReadScope }

try {
    Connect-WizardGraph -AdditionalScopes $additionalScopes
    Resolve-WizardGroupReferences -Scripts $localScripts

    $tenant = @(Get-MgBetaDeviceManagementScript -All -Property id, displayName)

    foreach ($meta in $localScripts) {
        Write-Host ""
        Write-Host "== $($meta.DisplayName) [$($meta.Type)] ==" -ForegroundColor Cyan

        $found = @($tenant | Where-Object { $_.DisplayName -eq $meta.DisplayName })
        Check 'exists in the tenant' ($found.Count -eq 1) "found $($found.Count) script(s) named '$($meta.DisplayName)'"
        if ($found.Count -ne 1) { continue }
        $id = $found[0].Id

        try {
            $full = Get-MgBetaDeviceManagementScript -DeviceManagementScriptId $id
        } catch {
            Check 'readable from the tenant' $false (Get-WizardErrorSummary -ErrorRecord $_)
            continue
        }

        # --- content, byte for byte -------------------------------------
        $remoteBytes = Get-WizardScriptContentBytes -Content $full.ScriptContent
        if (-not $remoteBytes) {
            Check 'content is byte-identical to the local file' $false 'the tenant returned no script content'
        } else {
            $localHash  = Get-WizardFileHash -Path $meta.Path
            $remoteHash = Get-WizardBytesHash -Bytes $remoteBytes
            $localSize  = (Get-Item -LiteralPath $meta.Path).Length
            Check 'content is byte-identical to the local file' ($localHash -eq $remoteHash) `
                "local $localHash ($localSize bytes) vs tenant $remoteHash ($($remoteBytes.Length) bytes) - check for a BOM, CRLF/LF, or a lost trailing newline"
        }

        # --- settings ----------------------------------------------------
        Check 'runAsAccount matches' ([string]$full.RunAsAccount -eq $meta.RunAsAccount) `
            "expected '$($meta.RunAsAccount)', tenant has '$($full.RunAsAccount)'"
        Check 'enforceSignatureCheck matches' ([bool]$full.EnforceSignatureCheck -eq [bool]$meta.EnforceSignatureCheck) `
            "expected $([bool]$meta.EnforceSignatureCheck), tenant has $([bool]$full.EnforceSignatureCheck)"
        Check 'runAs32Bit matches' ([bool]$full.RunAs32BitOnWindows64 -eq [bool]$meta.RunAs32Bit) `
            "expected $([bool]$meta.RunAs32Bit), tenant has $([bool]$full.RunAs32BitOnWindows64)"
        Check 'fileName matches' ([string]$full.FileName -eq $meta.FileName) `
            "expected '$($meta.FileName)', tenant has '$($full.FileName)'"
        Check 'description matches' ([string]$full.Description -eq [string]$meta.Description) `
            "expected '$($meta.Description)', tenant has '$($full.Description)'"

        # --- assignments -------------------------------------------------
        $expected = @(Get-WizardDesiredAssignments `
            -Type $meta.Type `
            -NoAssignments:$meta.NoAssignments `
            -IncludeGroupIds $meta.IncludeGroupIds `
            -ExcludeGroupIds $meta.ExcludeGroupIds)
        $expectedKeys = @($expected | ForEach-Object { ConvertTo-TargetKey -Target $_['target'] } | Sort-Object)

        try {
            $actual = @(Get-WizardScriptAssignments -Id $id)
        } catch {
            Check 'assignments readable' $false (Get-WizardErrorSummary -ErrorRecord $_)
            continue
        }
        $actualKeys = @($actual | ForEach-Object { ConvertTo-TargetKey -Target $_['target'] } | Sort-Object)

        Check 'assignment set matches exactly' (($expectedKeys -join '|') -eq ($actualKeys -join '|')) `
            "expected [$($expectedKeys -join ', ')] but tenant has [$($actualKeys -join ', ')]"
    }
} finally {
    Disconnect-WizardGraph
}

Write-Host ""
if ($script:Failed -gt 0) {
    Write-Host "$($script:Passed) passed, $($script:Failed) failed" -ForegroundColor Red
    exit 1
}
Write-Host "$($script:Passed) passed, 0 failed" -ForegroundColor Green
exit 0
