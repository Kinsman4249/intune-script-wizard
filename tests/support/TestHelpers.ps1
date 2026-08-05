# TestHelpers.ps1
# Shared harness for the offline regression suite, dot-sourced into
# Invoke-WizardTests.ps1 (the runner) before any of the tests/areas/*.ps1
# files. Everything here runs in the runner's scope, so Check's $script:pass /
# $script:fail update the runner's counters, and $repo/$stubs/$scratch (set by
# the runner) are visible to these helpers when they are called.

$bodyA = "# device script A`nWrite-Host 'a'`n"
$bodyB = "# user script B`nWrite-Host 'b'`n"

function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { Write-Host "PASS  $Name" -ForegroundColor Green; $script:pass++ }
    else     { Write-Host "FAIL  $Name  $Detail" -ForegroundColor Red;  $script:fail++ }
}

function New-Workspace {
    param([array]$Scripts)
    $ws = Join-Path $scratch "ws-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $ws -Force | Out-Null
    foreach ($s in $Scripts) {
        $full = Join-Path $ws $s.Rel
        New-Item -ItemType Directory -Path (Split-Path $full) -Force | Out-Null
        Set-Content -LiteralPath $full -Value $s.Body -NoNewline
    }
    return $ws
}

function Invoke-Wizard {
    param([string]$Workspace, [hashtable]$State, [string[]]$WizardArgs = @())
    $statePath = Join-Path $Workspace '_state.json'
    $callsPath = Join-Path $Workspace '_calls.jsonl'
    ($State | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $statePath
    Set-Content -LiteralPath $callsPath -Value '' -NoNewline

    $env:WIZTEST_STATE = $statePath
    $env:WIZTEST_CALLS = $callsPath
    $env:PSModulePath  = $stubs

    $out = & pwsh -NoProfile -File (Join-Path $repo 'Deploy-IntuneScripts.ps1') -Path $Workspace @WizardArgs 2>&1
    $calls = @()
    $rawCalls = Get-Content -LiteralPath $callsPath -Raw
    if ($rawCalls -and $rawCalls.Trim()) {
        $calls = Get-Content -LiteralPath $callsPath | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable }
    }
    return [pscustomobject]@{
        Output   = ($out | Out-String)
        ExitCode = $LASTEXITCODE
        Calls    = $calls
        State    = (Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable)
    }
}

# Helpers for the restore-edge-case tests: they need a workspace with a
# hand-written backup file in it, rather than one produced by a deploy run.
function New-BackupWorkspace {
    param([hashtable]$State, [hashtable[]]$Backups)
    $ws = Join-Path $scratch "ws-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path (Join-Path $ws 'backups') -Force | Out-Null
    foreach ($b in $Backups) {
        ($b.Content | ConvertTo-Json -Depth 20) |
            Set-Content -LiteralPath (Join-Path $ws "backups/$($b.Name)")
    }
    ($State | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath (Join-Path $ws '_state.json')
    Set-Content -LiteralPath (Join-Path $ws '_calls.jsonl') -Value '' -NoNewline
    return $ws
}
function Invoke-Restore {
    param([string]$Workspace, [string[]]$WizardArgs)
    $env:WIZTEST_STATE = Join-Path $Workspace '_state.json'
    $env:WIZTEST_CALLS = Join-Path $Workspace '_calls.jsonl'
    $env:PSModulePath  = $stubs
    $out = & pwsh -NoProfile -File (Join-Path $repo 'Deploy-IntuneScripts.ps1') -Path $Workspace @WizardArgs 2>&1 | Out-String
    $code = $LASTEXITCODE
    $calls = @()
    foreach ($line in (Get-Content -LiteralPath $env:WIZTEST_CALLS | Where-Object { $_ })) {
        $calls += ($line | ConvertFrom-Json -AsHashtable)
    }
    return [pscustomobject]@{
        Output = $out; ExitCode = $code; Calls = $calls
        State = (Get-Content -LiteralPath $env:WIZTEST_STATE -Raw | ConvertFrom-Json -AsHashtable)
    }
}
function New-BackupContent {
    param([string]$Id, [string]$Name, [string]$Body, $Tags = @('0'), $Stamp = $null, [bool]$Run32 = $true)
    $content = @{
        SchemaVersion = 3; Id = $Id; DisplayName = $Name; Description = 'd'
        FileName = 'x.ps1'
        ScriptContent = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Body))
        RunAsAccount = 'system'; EnforceSignatureCheck = $false; RunAs32Bit = $Run32
        Assignments = @(); ReplacedByDisplayName = ''; ReplacedByContentHash = ''
    }
    if ($null -ne $Tags)  { $content['RoleScopeTagIds'] = $Tags }
    if ($Stamp)           { $content['BackedUpAt'] = $Stamp }
    return $content
}
function New-TenantScript {
    param([string]$Id, [string]$Name, [string]$Body, $Tags = @('0'), [bool]$Run32 = $true, $Assignments = @())
    return @{
        id = $Id; displayName = $Name; description = 'd'; fileName = 'x.ps1'
        scriptContent = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Body))
        runAsAccount = 'system'; enforceSignatureCheck = $false; runAs32Bit = $Run32
        roleScopeTagIds = $Tags; lastModifiedDateTime = (Get-Date).ToString('o')
        assignments = $Assignments
    }
}
