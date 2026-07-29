# GraphOps.ps1
# Microsoft Graph (beta) interaction: auth and scopes, group-reference
# resolution, reading existing scripts, create/update, and assignments.
# Backup and restore live in Backup.ps1.
#
# Cmdlet naming: Get/New/Update-MgBetaDeviceManagementScript are documented and
# stable. Assignments are deliberately NOT done with per-item cmdlets - see the
# comment above Set-WizardWholeAssignment for why.

$script:RequiredScopes = @('DeviceManagementConfiguration.ReadWrite.All')

# Only requested when at least one script names a group by display name rather
# than by GUID. Asking for it unconditionally would force every user to re-consent
# to a directory read they may never need.
$script:GroupReadScope = 'GroupMember.Read.All'

# Relative Graph URIs. Invoke-MgGraphRequest prefixes the endpoint of whichever
# cloud the session connected to, so this keeps working in GCC High / DoD /
# 21Vianet without any per-cloud base URL of our own.
$script:ScriptsUri = '/beta/deviceManagement/deviceManagementScripts'

function Connect-WizardGraph {
    param(
        # Extra scopes needed by this particular run, e.g. the directory read
        # used to turn a #group:"Name" into an object id.
        [string[]]$AdditionalScopes = @()
    )

    $scopes = @($script:RequiredScopes) + @($AdditionalScopes) | Select-Object -Unique

    $context = Get-MgContext
    if (-not $context -or ($scopes | Where-Object { $_ -notin $context.Scopes })) {
        Write-WizardDebug "Connecting to Graph with scopes: $($scopes -join ', ')"
        Connect-MgGraph -Scopes $scopes -NoWelcome
    }
    $context = Get-MgContext
    Write-WizardDebug "Graph context: tenant=$($context.TenantId) account=$($context.Account) type=$($context.AuthType)"
}

function Resolve-WizardGroupName {
    # Turns a group display name into its object id. Exact match only; a name
    # that matches zero or more than one group is an error rather than a guess,
    # because guessing here silently targets the wrong set of machines.
    param([Parameter(Mandatory)][string]$Name)

    # OData string literals escape a single quote by doubling it.
    $literal = $Name.Replace("'", "''")
    $filter = [uri]::EscapeDataString("displayName eq '$literal'")
    $uri = '/v1.0/groups?$filter=' + $filter + '&$select=id,displayName'

    Write-WizardDebug "GET $uri"
    $response = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType Hashtable
    $matched = @($response['value'])

    if ($matched.Count -eq 0) {
        throw "No group found with display name '$Name'. Check the spelling, or use the group's object GUID instead."
    }
    if ($matched.Count -gt 1) {
        $ids = ($matched | ForEach-Object { $_['id'] }) -join ', '
        throw "Group name '$Name' is ambiguous - $($matched.Count) groups share it ($ids). Use the object GUID instead."
    }

    Write-WizardDebug "  '$Name' -> $($matched[0]['id'])"
    return $matched[0]['id']
}

function Resolve-WizardGroupReferences {
    # Fills IncludeGroupIds/ExcludeGroupIds on every script's metadata. Runs as a
    # pre-flight over the whole set so a typo aborts before any script is
    # deployed, rather than leaving a half-applied run behind. Names are resolved
    # once each per run even when several scripts share a group.
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Scripts)

    $cache = @{}

    $resolve = {
        param([string]$Ref)
        $parsed = [guid]::Empty
        if ([guid]::TryParse($Ref, [ref]$parsed)) { return $parsed.ToString() }
        if (-not $cache.ContainsKey($Ref)) { $cache[$Ref] = Resolve-WizardGroupName -Name $Ref }
        return $cache[$Ref]
    }

    foreach ($meta in $Scripts) {
        $meta.IncludeGroupIds = @(foreach ($ref in $meta.GroupRefs)        { & $resolve $ref })
        $meta.ExcludeGroupIds = @(foreach ($ref in $meta.ExcludeGroupRefs) { & $resolve $ref })

        # Two different names or a name and a GUID can land on the same group.
        # Only detectable after resolution, and it would be rejected by Graph anyway.
        $clash = $meta.IncludeGroupIds | Where-Object { $_ -in $meta.ExcludeGroupIds }
        if ($clash) {
            throw "'$($meta.Path)': the same group resolves to both an include and an exclude target ($($clash -join ', '))."
        }

        if ($meta.IncludeGroupIds.Count -or $meta.ExcludeGroupIds.Count) {
            Write-WizardDebug "$($meta.DisplayName): include=[$($meta.IncludeGroupIds -join ',')] exclude=[$($meta.ExcludeGroupIds -join ',')]"
        }
    }
}

function Test-WizardNeedsGroupScope {
    # True when any reference is a display name (GUIDs need no directory read).
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Scripts)

    foreach ($meta in $Scripts) {
        foreach ($ref in (@($meta.GroupRefs) + @($meta.ExcludeGroupRefs))) {
            $parsed = [guid]::Empty
            if (-not [guid]::TryParse($ref, [ref]$parsed)) { return $true }
        }
    }
    return $false
}

function Get-WizardAssignmentTargetType {
    param([Parameter(Mandatory)][ValidateSet('user', 'device')][string]$Type)
    if ($Type -eq 'user') { 'allLicensedUsersAssignmentTarget' } else { 'allDevicesAssignmentTarget' }
}

function Get-WizardExistingScripts {
    # Returns all existing deviceManagementScripts with a content SHA256 hash,
    # using a local cache (keyed by LastModifiedDateTime) so unchanged scripts
    # don't need their content re-downloaded on every run.
    param(
        [Parameter(Mandatory)][string]$CachePath
    )

    $cache = @{}
    if (Test-Path -LiteralPath $CachePath) {
        try {
            (Get-Content -LiteralPath $CachePath -Raw | ConvertFrom-Json) | ForEach-Object {
                $cache[$_.Id] = $_
            }
            Write-WizardDebug "Loaded $($cache.Count) cached script hashes from $CachePath"
        } catch {
            Write-Warning "Could not read cache file '$CachePath', rebuilding it."
        }
    }

    $existing = Get-MgBetaDeviceManagementScript -All -Property id, displayName, description, lastModifiedDateTime
    Write-WizardDebug "Tenant returned $(@($existing).Count) existing scripts"

    $results = @()
    foreach ($item in $existing) {
        # Guard against a null timestamp: without it the cache key is meaningless,
        # so fall back to always re-hashing that one script.
        $modified = if ($item.LastModifiedDateTime) { $item.LastModifiedDateTime.ToString('o') } else { $null }

        $cached = $cache[$item.Id]
        if ($modified -and $cached -and $cached.LastModifiedDateTime -eq $modified) {
            $hash = ([string]$cached.ContentHash).ToLowerInvariant()
            Write-WizardDebug "  cache hit for $($item.Id) '$($item.DisplayName)'"
        } else {
            Write-WizardDebug "  downloading content for $($item.Id) '$($item.DisplayName)'"
            $full = Get-MgBetaDeviceManagementScript -DeviceManagementScriptId $item.Id -Property scriptContent
            $bytes = [System.Convert]::FromBase64String($full.ScriptContent)
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try {
                $hash = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
            } finally {
                $sha.Dispose()
            }
        }

        $results += [pscustomobject]@{
            Id                   = $item.Id
            DisplayName          = $item.DisplayName
            Description          = $item.Description
            LastModifiedDateTime = $modified
            ContentHash          = $hash
        }
    }

    $results | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $CachePath
    return $results
}

function Get-WizardScriptAssignments {
    # Reads assignments as raw JSON rather than through the typed SDK cmdlet.
    # The typed model only surfaces properties it knows about, and anything it
    # doesn't recognise lands in AdditionalProperties - so a group target could
    # lose its groupId or assignment-filter id on the way into a backup. Raw
    # hashtables round-trip whatever the service actually sent.
    param([Parameter(Mandatory)][string]$Id)

    $uri = "$script:ScriptsUri/$Id/assignments"
    $all = @()
    while ($uri) {
        Write-WizardDebug "GET $uri"
        $response = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType Hashtable
        if ($response['value']) { $all += @($response['value']) }
        $uri = $response['@odata.nextLink']
    }
    Write-WizardDebug "  $($all.Count) assignment(s) on $Id"
    return $all
}

function ConvertTo-WizardAssignmentPayload {
    # Reduces a returned assignment to the shape the assign action accepts.
    # 'id' is dropped on purpose: assignment ids belong to the script they were
    # read from, so replaying them against a recreated script would be invalid.
    param([Parameter(Mandatory)]$Assignment)

    $target = $Assignment['target']
    if (-not $target) { return $null }

    return @{
        '@odata.type' = '#microsoft.graph.deviceManagementScriptAssignment'
        'target'      = $target
    }
}

function Set-WizardWholeAssignment {
    # Replaces a script's entire assignment set in one call.
    #
    # The beta module exposes only Get-MgBetaDeviceManagementScriptAssignment;
    # there is no documented New-/Remove- counterpart, because assignments on
    # deviceManagementScript are managed through the 'assign' action rather than
    # as a writable collection:
    #   POST /beta/deviceManagement/deviceManagementScripts/{id}/assign
    #   https://learn.microsoft.com/en-us/graph/api/intune-shared-devicemanagementscript-assign?view=graph-rest-beta
    # Being a single full replacement, this also removes the window in which a
    # script sat unassigned between a delete loop and a re-add loop.
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Assignments
    )

    $body = @{ deviceManagementScriptAssignments = @($Assignments) }
    $json = $body | ConvertTo-Json -Depth 10
    $uri = "$script:ScriptsUri/$Id/assign"

    Write-WizardDebug "POST $uri"
    Write-WizardDebug "  body: $json"
    Invoke-MgGraphRequest -Method POST -Uri $uri -Body $json -ContentType 'application/json' | Out-Null
}

function New-WizardAssignmentEntry {
    param([Parameter(Mandatory)][hashtable]$Target)
    return @{
        '@odata.type' = '#microsoft.graph.deviceManagementScriptAssignment'
        'target'      = $Target
    }
}

function Get-WizardDesiredAssignments {
    # Builds the assignment set a script's metadata asks for.
    #
    #   #noassignments                -> no assignments at all
    #   #group: one or more           -> a groupAssignmentTarget per group
    #   no #group:                    -> the all-users / all-devices default
    #   #excludegroup: one or more    -> an exclusionGroupAssignmentTarget per
    #                                    group, on top of whichever include
    #                                    targets the rules above produced
    #
    # Exclusions without any #group: are deliberately allowed: "everyone except
    # the pilot ring" is a normal Intune pattern and needs the default include.
    param(
        [Parameter(Mandatory)][ValidateSet('user', 'device')][string]$Type,
        [switch]$NoAssignments,
        [string[]]$IncludeGroupIds = @(),
        [string[]]$ExcludeGroupIds = @()
    )

    if ($NoAssignments) { return @() }

    $assignments = @()

    if ($IncludeGroupIds.Count -gt 0) {
        foreach ($groupId in $IncludeGroupIds) {
            $assignments += New-WizardAssignmentEntry -Target @{
                '@odata.type' = '#microsoft.graph.groupAssignmentTarget'
                'groupId'     = $groupId
            }
        }
    } else {
        $assignments += New-WizardAssignmentEntry -Target @{
            '@odata.type' = "#microsoft.graph.$(Get-WizardAssignmentTargetType -Type $Type)"
        }
    }

    foreach ($groupId in $ExcludeGroupIds) {
        $assignments += New-WizardAssignmentEntry -Target @{
            '@odata.type' = '#microsoft.graph.exclusionGroupAssignmentTarget'
            'groupId'     = $groupId
        }
    }

    return $assignments
}

function Get-WizardAssignmentSummary {
    # Human-readable description of where a script will land. Uses the refs as
    # written in the file rather than resolved GUIDs, so -DryRun output reads
    # the way the script author wrote it.
    param([Parameter(Mandatory)]$Meta)

    if ($Meta.NoAssignments) { return 'no assignments' }

    $summary = if (@($Meta.GroupRefs).Count -gt 0) {
        "group(s): $(@($Meta.GroupRefs) -join ', ')"
    } elseif ($Meta.Type -eq 'user') {
        'all users'
    } else {
        'all devices'
    }

    if (@($Meta.ExcludeGroupRefs).Count -gt 0) {
        $summary += ", excluding: $(@($Meta.ExcludeGroupRefs) -join ', ')"
    }
    return $summary
}

function Set-WizardAssignments {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)]$Meta)

    # @(...) is load-bearing: a function returning an empty array hands back
    # $null through the pipeline, which the -Assignments parameter rejects.
    # Without it, #noassignments fails instead of clearing the assignments.
    $assignments = @(Get-WizardDesiredAssignments `
        -Type $Meta.Type `
        -NoAssignments:$Meta.NoAssignments `
        -IncludeGroupIds $Meta.IncludeGroupIds `
        -ExcludeGroupIds $Meta.ExcludeGroupIds)

    Set-WizardWholeAssignment -Id $Id -Assignments $assignments
}

function New-WizardScript {
    param([Parameter(Mandatory)]$Meta)

    Write-Host "Creating '$($Meta.DisplayName)' ($($Meta.Type))..."
    Write-WizardDebug "New script: file=$($Meta.FileName) runAs=$($Meta.RunAsAccount) 32bit=$($Meta.RunAs32Bit) sigCheck=$($Meta.EnforceSignatureCheck) noAssign=$($Meta.NoAssignments)"

    $script = New-MgBetaDeviceManagementScript `
        -DisplayName $Meta.DisplayName `
        -Description $Meta.Description `
        -FileName $Meta.FileName `
        -ScriptContentInputFile $Meta.Path `
        -RunAsAccount $Meta.RunAsAccount `
        -EnforceSignatureCheck:$Meta.EnforceSignatureCheck `
        -RunAs32Bit:$Meta.RunAs32Bit

    Write-WizardDebug "Created $($script.Id)"
    Set-WizardAssignments -Id $script.Id -Meta $Meta
    return $script
}

function Update-WizardScript {
    param(
        [Parameter(Mandatory)]$Meta,
        [Parameter(Mandatory)][string]$ExistingId,
        [Parameter(Mandatory)][string]$BackupDir
    )

    Backup-WizardScript -Id $ExistingId -BackupDir $BackupDir | Out-Null

    Write-Host "Updating '$($Meta.DisplayName)' ($($Meta.Type))..."
    Write-WizardDebug "Update $ExistingId from $($Meta.Path)"

    Update-MgBetaDeviceManagementScript `
        -DeviceManagementScriptId $ExistingId `
        -DisplayName $Meta.DisplayName `
        -Description $Meta.Description `
        -FileName $Meta.FileName `
        -ScriptContentInputFile $Meta.Path `
        -RunAsAccount $Meta.RunAsAccount `
        -EnforceSignatureCheck:$Meta.EnforceSignatureCheck `
        -RunAs32Bit:$Meta.RunAs32Bit | Out-Null

    Set-WizardAssignments -Id $ExistingId -Meta $Meta
}

