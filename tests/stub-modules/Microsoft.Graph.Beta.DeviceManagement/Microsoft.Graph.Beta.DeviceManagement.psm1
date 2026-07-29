# Stub Intune device management module for offline testing of the wizard.

function Get-StubState2 { Get-Content -LiteralPath $env:WIZTEST_STATE -Raw | ConvertFrom-Json -AsHashtable }
function Set-StubState2 { param($S) ($S | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $env:WIZTEST_STATE }
function Add-StubCall2 {
    param($Name, $Data)
    (@{ call = $Name; data = $Data } | ConvertTo-Json -Depth 20 -Compress) |
        Add-Content -LiteralPath $env:WIZTEST_CALLS
}

function ConvertTo-StubScriptObject {
    param($H)
    [pscustomobject]@{
        Id                    = $H['id']
        DisplayName           = $H['displayName']
        Description           = $H['description']
        FileName              = $H['fileName']
        ScriptContent         = $H['scriptContent']
        RunAsAccount          = $H['runAsAccount']
        EnforceSignatureCheck = [bool]$H['enforceSignatureCheck']
        RunAs32BitOnWindows64 = [bool]$H['runAs32Bit']
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

Export-ModuleMember -Function Get-MgBetaDeviceManagementScript, New-MgBetaDeviceManagementScript, Update-MgBetaDeviceManagementScript
