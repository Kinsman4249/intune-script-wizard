#Requires -Version 7.0
<#
.SYNOPSIS
    Offline regression tests for Deploy-IntuneScripts.ps1.

.DESCRIPTION
    Injects stub Microsoft.Graph.Authentication and
    Microsoft.Graph.Beta.DeviceManagement modules via PSModulePath, so the real
    entry point runs end to end against an in-memory tenant with no network,
    credentials or Intune licence involved. Each scenario runs in its own pwsh
    process because the wizard calls exit on some paths.

    This file is only the runner: it sets up the shared scratch space and
    counters, dot-sources the shared harness (support/TestHelpers.ps1) and then
    every area file under tests/areas/ in order. Because each area file is
    dot-sourced into this scope, they all share the same Check counters and
    $repo/$stubs/$scratch, exactly as when this suite was one large file - just
    split by topic so no single file runs past 500 lines.

    Run:  pwsh -NoProfile -File tests/Invoke-WizardTests.ps1
    Exits with the number of failed checks.

.PARAMETER WorkRoot
    Where scratch workspaces are created. Defaults to a temp folder, removed
    on exit unless -KeepWorkspaces is passed.

.PARAMETER KeepWorkspaces
    Leave the generated workspaces on disk for inspection after a failure.
#>
[CmdletBinding()]
param(
    [string]$WorkRoot,
    [switch]$KeepWorkspaces
)

$ErrorActionPreference = 'Stop'
$repo  = Split-Path -Parent $PSScriptRoot
$stubs = Join-Path $PSScriptRoot 'stub-modules'

if (-not $WorkRoot) {
    $WorkRoot = Join-Path ([System.IO.Path]::GetTempPath()) "wizard-tests-$([guid]::NewGuid().ToString('N').Substring(0,8))"
}
New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null
$scratch = $WorkRoot

# Retries are real waits, and the suite drives the throttle path deliberately.
# The wizard reads this to shrink its backoff base so a retry test costs
# milliseconds instead of half a minute; nothing in normal use sets it.
$env:WIZARD_RETRY_BASE_SECONDS = '0.05'

$pass = 0; $fail = 0

# Shared harness (Check, workspace/backup/tenant helpers, bodyA/bodyB) first,
# then each topic area in order. Dot-sourcing keeps them all in this scope, so
# an area that sets a variable or dot-sources a lib file makes it available to
# the areas after it - the same execution model the single-file suite had.
. (Join-Path $PSScriptRoot 'support/TestHelpers.ps1')

$areaDir = Join-Path $PSScriptRoot 'areas'
foreach ($area in (Get-ChildItem -LiteralPath $areaDir -Filter '*.ps1' | Sort-Object Name)) {
    . $area.FullName
}

Write-Host ""
Write-Host "$pass passed, $fail failed" -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })

if ($KeepWorkspaces) {
    Write-Host "Workspaces kept at $WorkRoot"
} else {
    Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
}

exit $fail
