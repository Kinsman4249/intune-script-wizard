# Stub Intune device management module for offline testing of the wizard.

function Get-StubState2 { Get-Content -LiteralPath $env:WIZTEST_STATE -Raw | ConvertFrom-Json -AsHashtable }
function Set-StubState2 { param($S) ($S | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $env:WIZTEST_STATE }
function Add-StubCall2 {
    param($Name, $Data)
    (@{ call = $Name; data = $Data } | ConvertTo-Json -Depth 20 -Compress) |
        Add-Content -LiteralPath $env:WIZTEST_CALLS
}

function Deny-StubScopeTag2 {
    # 'rejectScopeTag' names a scope tag id the fake tenant refuses, the way a
    # real one refuses a tag that has been deleted since the backup was taken.
    # A write carrying it is turned down whole - which is the point: the
    # script's content never lands either, unless the caller retries.
    param($State, [string[]]$RoleScopeTagIds)

    $reject = [string]$State['rejectScopeTag']
    if ($reject -and (@($RoleScopeTagIds) -contains $reject)) {
        throw "Stub: tenant rejected the request - invalid role scope tag id '$reject'"
    }
}

function ConvertTo-StubScriptObject {
    param($H)
    # scriptContent is Edm.Binary on the wire, and the real SDK deserialises it
    # to a byte[] rather than leaving it as the base64 text the service sent.
    # The stub models that, because handing back a base64 string instead let two
    # separate byte[]-handling bugs - content hashing in GraphOps, and the
    # backup writer storing a JSON array of numbers - both pass a green suite.
    $contentBytes = if ($H['scriptContent']) {
        [System.Convert]::FromBase64String($H['scriptContent'])
    } else {
        $null
    }
    [pscustomobject]@{
        Id                    = $H['id']
        DisplayName           = $H['displayName']
        Description           = $H['description']
        FileName              = $H['fileName']
        ScriptContent         = $contentBytes
        RunAsAccount          = $H['runAsAccount']
        EnforceSignatureCheck = [bool]$H['enforceSignatureCheck']
        RunAs32Bit            = [bool]$H['runAs32Bit']
        RoleScopeTagIds       = @($H['roleScopeTagIds'])
        LastModifiedDateTime  = [datetimeoffset]::Parse($H['lastModifiedDateTime'])
    }
}

function Get-MgBetaDeviceManagementScript {
    param(
        [string]$DeviceManagementScriptId,
        [switch]$All,
        [string[]]$Property
    )
    $state = Get-StubState2
    if ($DeviceManagementScriptId) {
        # 'getError' makes a single-script read fail the way a throttle or an
        # outage does, as opposed to the "not found" below. The two must not be
        # treated alike: only the second one means the script was deleted.
        if ($state['getError']) { throw [string]$state['getError'] }
        $found = $state['scripts'] | Where-Object { $_['id'] -eq $DeviceManagementScriptId }
        if (-not $found) { throw "Stub: script $DeviceManagementScriptId not found" }
        return ConvertTo-StubScriptObject $found
    }
    return @($state['scripts'] | ForEach-Object { ConvertTo-StubScriptObject $_ })
}

function New-MgBetaDeviceManagementScript {
    param(
        [string]$DisplayName, [string]$Description, [string]$FileName,
        [string]$ScriptContentInputFile, [string]$RunAsAccount,
        [switch]$EnforceSignatureCheck, [switch]$RunAs32Bit,
        [string[]]$RoleScopeTagIds
    )
    Add-StubCall2 'New-MgBetaDeviceManagementScript' @{
        displayName = $DisplayName; runAsAccount = $RunAsAccount
        runAs32Bit = [bool]$RunAs32Bit; enforceSignatureCheck = [bool]$EnforceSignatureCheck
        roleScopeTagIds = @($RoleScopeTagIds)
    }
    $state = Get-StubState2
    # 'failCreate' names a display name the fake tenant rejects, so the tests can
    # exercise the per-script failure path without a real 400 from Graph.
    if ($state['failCreate'] -and $DisplayName -eq $state['failCreate']) {
        throw "Stub: tenant rejected '$DisplayName' (BadRequest)"
    }
    Deny-StubScopeTag2 -State $state -RoleScopeTagIds $RoleScopeTagIds
    $id = "new-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $bytes = [System.IO.File]::ReadAllBytes($ScriptContentInputFile)
    $state['scripts'] += @{
        id = $id; displayName = $DisplayName; description = $Description
        fileName = $FileName; scriptContent = [Convert]::ToBase64String($bytes)
        runAsAccount = $RunAsAccount; enforceSignatureCheck = [bool]$EnforceSignatureCheck
        runAs32Bit = [bool]$RunAs32Bit; roleScopeTagIds = @($RoleScopeTagIds)
        lastModifiedDateTime = (Get-Date).ToString('o'); assignments = @()
    }
    Set-StubState2 $state
    return [pscustomobject]@{ Id = $id }
}

function Update-MgBetaDeviceManagementScript {
    param(
        [string]$DeviceManagementScriptId,
        [string]$DisplayName, [string]$Description, [string]$FileName,
        [string]$ScriptContentInputFile, [string]$RunAsAccount,
        [switch]$EnforceSignatureCheck, [switch]$RunAs32Bit,
        [string[]]$RoleScopeTagIds
    )
    Add-StubCall2 'Update-MgBetaDeviceManagementScript' @{
        id = $DeviceManagementScriptId; displayName = $DisplayName
        roleScopeTagIds = @($RoleScopeTagIds)
    }
    $state = Get-StubState2
    Deny-StubScopeTag2 -State $state -RoleScopeTagIds $RoleScopeTagIds
    foreach ($s in $state['scripts']) {
        if ($s['id'] -ne $DeviceManagementScriptId) { continue }
        $s['displayName'] = $DisplayName
        $s['description'] = $Description
        $s['fileName'] = $FileName
        $s['scriptContent'] = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($ScriptContentInputFile))
        $s['runAsAccount'] = $RunAsAccount
        $s['enforceSignatureCheck'] = [bool]$EnforceSignatureCheck
        $s['runAs32Bit'] = [bool]$RunAs32Bit
        if ($RoleScopeTagIds) { $s['roleScopeTagIds'] = @($RoleScopeTagIds) }
        $s['lastModifiedDateTime'] = (Get-Date).ToString('o')
    }
    Set-StubState2 $state
}

function Remove-MgBetaDeviceManagementScript {
    param([string]$DeviceManagementScriptId)
    Add-StubCall2 'Remove-MgBetaDeviceManagementScript' @{ id = $DeviceManagementScriptId }
    $state = Get-StubState2
    $before = @($state['scripts']).Count
    $state['scripts'] = @($state['scripts'] | Where-Object { $_['id'] -ne $DeviceManagementScriptId })
    if (@($state['scripts']).Count -eq $before) { throw "Stub: script $DeviceManagementScriptId not found" }
    Set-StubState2 $state
}

Export-ModuleMember -Function Get-MgBetaDeviceManagementScript, New-MgBetaDeviceManagementScript, Update-MgBetaDeviceManagementScript, Remove-MgBetaDeviceManagementScript
