# Stub Graph auth module for offline testing of the wizard.
# State and a call log live in JSON files pointed at by env vars.

function Get-StubState { Get-Content -LiteralPath $env:WIZTEST_STATE -Raw | ConvertFrom-Json -AsHashtable }
function Set-StubState { param($S) ($S | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $env:WIZTEST_STATE }
function Add-StubCall {
    param($Name, $Data)
    $entry = @{ call = $Name; data = $Data } | ConvertTo-Json -Depth 20 -Compress
    Add-Content -LiteralPath $env:WIZTEST_CALLS -Value $entry
}

function Get-MgContext {
    [pscustomobject]@{
        Scopes   = @('DeviceManagementConfiguration.ReadWrite.All')
        TenantId = 'stub-tenant'
        Account  = 'stub@example.com'
        AuthType = 'Delegated'
    }
}

function Connect-MgGraph {
    param([string[]]$Scopes, [switch]$NoWelcome)
    Add-StubCall 'Connect-MgGraph' @{ scopes = $Scopes }
}

function Invoke-MgGraphRequest {
    param(
        [string]$Method,
        [string]$Uri,
        $Body,
        [string]$ContentType,
        [string]$OutputType
    )

    Add-StubCall 'Invoke-MgGraphRequest' @{ method = $Method; uri = $Uri; body = "$Body" }

    $state = Get-StubState

    if ($Method -eq 'GET' -and $Uri -match '^/v1\.0/groups\?') {
        # Pull the display name back out of the encoded $filter and match it
        # against the fake directory in the state file.
        $decoded = [uri]::UnescapeDataString($Uri)
        if ($decoded -notmatch "displayName eq '(?<name>.*?)'(&|$)") {
            throw "Stub: unrecognised group filter in $Uri"
        }
        $wanted = $Matches['name'].Replace("''", "'")
        $found = @($state['groups'] | Where-Object { $_['displayName'] -eq $wanted })
        return @{ value = @($found | ForEach-Object { @{ id = $_['id']; displayName = $_['displayName'] } }) }
    }

    if ($Method -eq 'GET' -and $Uri -match '/deviceManagementScripts/([^/]+)/assignments$') {
        $id = $Matches[1]
        $script = $state['scripts'] | Where-Object { $_['id'] -eq $id }
        return @{ value = @($script['assignments']) }
    }

    if ($Method -eq 'POST' -and $Uri -match '/deviceManagementScripts/([^/]+)/assign$') {
        $id = $Matches[1]
        $parsed = $Body | ConvertFrom-Json -AsHashtable
        foreach ($s in $state['scripts']) {
            if ($s['id'] -eq $id) { $s['assignments'] = @($parsed['deviceManagementScriptAssignments']) }
        }
        Set-StubState $state
        return $null
    }

    throw "Stub Invoke-MgGraphRequest: unhandled $Method $Uri"
}

Export-ModuleMember -Function Get-MgContext, Connect-MgGraph, Invoke-MgGraphRequest
