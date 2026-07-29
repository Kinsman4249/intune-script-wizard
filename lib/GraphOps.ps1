# GraphOps.ps1
# Microsoft Graph (beta) interaction: auth and scopes, group-reference
# resolution, reading existing scripts, create/update, and assignments.
# Backup and restore live in Backup.ps1.
#
# Cmdlet naming: Get/New/Update-MgBetaDeviceManagementScript are documented and
# stable. Assignments are deliberately NOT done with per-item cmdlets - see the
# comment above Set-WizardWholeAssignment for why.

# "Scopes" are the specific permissions this app asks the signed-in user (or
# admin) to grant, e.g. "let me read and write Intune device management config".
$script:RequiredScopes = @('DeviceManagementConfiguration.ReadWrite.All')

# Only requested when at least one script names a group by display name rather
# than by GUID. Asking for it unconditionally would force every user to re-consent
# to a directory read they may never need.
$script:GroupReadScope = 'GroupMember.Read.All'

# Relative Graph URIs. Invoke-MgGraphRequest prefixes the endpoint of whichever
# cloud the session connected to, so this keeps working in GCC High / DoD /
# 21Vianet without any per-cloud base URL of our own.
$script:ScriptsUri = '/beta/deviceManagement/deviceManagementScripts'

# Signs the current PowerShell session in to Microsoft Graph, requesting only
# the permission scopes this run actually needs.
function Connect-WizardGraph {
    # param() declares this function's inputs. Each [type] before a name is a
    # type constraint; [string[]] means "an array of strings".
    param(
        # Extra scopes needed by this particular run, e.g. the directory read
        # used to turn a #group:"Name" into an object id.
        [string[]]$AdditionalScopes = @()
    )

    # Combine the always-needed scopes with any extra ones, then drop duplicates.
    $scopes = @($script:RequiredScopes) + @($AdditionalScopes) | Select-Object -Unique

    # try/catch runs the try block, and if anything inside throws an error, jumps
    # to catch instead of crashing the whole script.
    try {
        # Get-MgContext returns details of an existing Graph sign-in, or nothing
        # if there isn't one yet.
        $context = Get-MgContext
        if (-not $context -or ($scopes | Where-Object { $_ -notin $context.Scopes })) {
            Write-WizardDebug "Connecting to Graph with scopes: $($scopes -join ', ')"
            # Connect-MgGraph is the SDK cmdlet that opens the sign-in flow
            # (browser or device code) and establishes the Graph session.
            Connect-MgGraph -Scopes $scopes -NoWelcome -ErrorAction Stop
        }
    } catch {
        # Sign-in covers a lot of distinct failures (cancelled browser prompt,
        # blocked device-code flow, conditional access, an admin who has not
        # consented to the scope). The SDK's own message is kept, with the
        # scopes appended because "which permission?" is the first question.
        throw "Could not sign in to Microsoft Graph: $(Get-WizardErrorSummary -ErrorRecord $_). Scopes requested: $($scopes -join ', '). Check the account has Intune administrator rights and that an admin has consented to these scopes."
    }

    $context = Get-MgContext
    if (-not $context) {
        throw "Microsoft Graph reported a successful sign-in but returned no session context. Run Disconnect-MgGraph and try again."
    }

    # A tenant can hand back fewer scopes than were asked for (an admin consent
    # policy trimming the request). Catching that now turns a later, confusing
    # 403 on a specific call into one clear message up front.
    $granted = @($context.Scopes)
    $notGranted = @($scopes | Where-Object { $_ -notin $granted })
    if ($notGranted.Count -gt 0) {
        throw "Signed in as $($context.Account), but the tenant did not grant: $($notGranted -join ', '). An administrator needs to consent to these scopes before the wizard can run."
    }

    Write-WizardDebug "Graph context: tenant=$($context.TenantId) account=$($context.Account) type=$($context.AuthType)"
}

function Resolve-WizardGroupName {
    # Turns a group display name into its object id. Exact match only; a name
    # that matches zero or more than one group is an error rather than a guess,
    # because guessing here silently targets the wrong set of machines.
    # [Parameter(Mandatory)] means the caller must supply -Name or PowerShell
    # will stop and prompt for it.
    param([Parameter(Mandatory)][string]$Name)

    # OData string literals escape a single quote by doubling it.
    $literal = $Name.Replace("'", "''")
    # OData is the query language Graph uses in URLs, e.g. $filter=... below
    # is like a "WHERE" clause. EscapeDataString URL-encodes it so spaces and
    # quotes don't break the request.
    $filter = [uri]::EscapeDataString("displayName eq '$literal'")
    # $select limits which fields come back, keeping the response small.
    $uri = '/v1.0/groups?$filter=' + $filter + '&$select=id,displayName'

    Write-WizardDebug "GET $uri"
    try {
        # Invoke-MgGraphRequest is a low-level call: it hits the Graph REST API
        # directly with whatever URI/method you give it, rather than going
        # through a typed cmdlet. -OutputType Hashtable gets back plain
        # key/value data instead of a strongly-typed .NET object.
        $response = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType Hashtable
    } catch {
        throw "Could not look up group '$Name' in Entra ID: $(Get-WizardErrorSummary -ErrorRecord $_). This needs the $script:GroupReadScope scope; if consent was declined, use the group's object GUID in #group: instead."
    }
    # Graph list responses wrap results in a 'value' array under that key.
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

    # A hashtable used as a simple cache: group name -> already-resolved id.
    $cache = @{}

    # A scriptblock is a chunk of code stored in a variable, like a small
    # inline function. It's defined once here and invoked below with '& $resolve'.
    $resolve = {
        param([string]$Ref)
        $parsed = [guid]::Empty
        # If the reference already looks like a GUID, no lookup is needed.
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

# Maps our simple 'user'/'device' choice to the Graph @odata.type name used
# when no specific group is targeted (i.e. "assign to everyone").
function Get-WizardAssignmentTargetType {
    # ValidateSet restricts the parameter to only these two values; PowerShell
    # rejects anything else before the function body even runs.
    param([Parameter(Mandatory)][ValidateSet('user', 'device')][string]$Type)
    if ($Type -eq 'user') { 'allLicensedUsersAssignmentTarget' } else { 'allDevicesAssignmentTarget' }
}

function Get-WizardExistingScripts {
    # Returns all existing deviceManagementScripts with a content SHA256 hash,
    # using a local cache (keyed by LastModifiedDateTime) so unchanged scripts
    # don't need their content re-downloaded on every run.
    # (deviceManagementScript is Intune's Graph object type for a PowerShell
    # script uploaded for devices to run.)
    param(
        [Parameter(Mandatory)][string]$CachePath
    )

    $cache = @{}
    try {
        $cached = Read-WizardJsonFile -Path $CachePath
        foreach ($entry in @($cached)) {
            if ($entry -and $entry.Id) { $cache[$entry.Id] = $entry }
        }
        if ($cache.Count -gt 0) {
            Write-WizardDebug "Loaded $($cache.Count) cached script hashes from $CachePath"
        }
    } catch {
        # The cache is a pure optimisation, so a damaged one costs a slower run
        # and nothing else.
        Write-Warning "Could not read cache file '$CachePath' ($($_.Exception.Message)), rebuilding it."
    }

    try {
        # A typed SDK cmdlet (as opposed to Invoke-MgGraphRequest above): it
        # knows the deviceManagementScript shape and returns .NET objects.
        # -All follows pagination automatically; -Property limits which fields
        # come back, so full script content isn't downloaded for every item.
        $existing = Get-MgBetaDeviceManagementScript -All -Property id, displayName, description, lastModifiedDateTime
    } catch {
        throw "Could not read the existing scripts from Intune: $(Get-WizardErrorSummary -ErrorRecord $_). Without that list the wizard cannot tell a new script from an existing one, so it will not deploy anything."
    }
    Write-WizardDebug "Tenant returned $(@($existing).Count) existing scripts"

    $results = @()
    foreach ($item in $existing) {
        # Guard against a null timestamp: without it the cache key is meaningless,
        # so fall back to always re-hashing that one script.
        $modified = if ($item.LastModifiedDateTime) { $item.LastModifiedDateTime.ToString('o') } else { $null }

        $cached = $cache[$item.Id]
        # A cached entry with no hash is one a previous run could not read;
        # retry it rather than caching the failure forever.
        if ($modified -and $cached -and $cached.ContentHash -and $cached.LastModifiedDateTime -eq $modified) {
            $hash = ([string]$cached.ContentHash).ToLowerInvariant()
            Write-WizardDebug "  cache hit for $($item.Id) '$($item.DisplayName)'"
        } else {
            # One unreadable script in the tenant must not stop the whole run:
            # its hash is left null, which matches nothing, so the worst case is
            # that a local script is treated as new and matched by name instead.
            $hash = $null
            try {
                Write-WizardDebug "  downloading content for $($item.Id) '$($item.DisplayName)'"
                # This time asking specifically for scriptContent, which Graph
                # stores as a base64-encoded string (text-safe encoding of the
                # raw script bytes) - it has to be decoded back to bytes before
                # it can be hashed or compared to a local file.
                $full = Get-MgBetaDeviceManagementScript -DeviceManagementScriptId $item.Id -Property scriptContent
                if ([string]::IsNullOrWhiteSpace($full.ScriptContent)) {
                    throw "the tenant returned no script content"
                }
                $hash = Get-WizardBytesHash -Bytes ([System.Convert]::FromBase64String($full.ScriptContent))
            } catch {
                Write-Warning "Could not hash existing script '$($item.DisplayName)' ($($item.Id)): $(Get-WizardErrorSummary -ErrorRecord $_). It will not be matched by content this run."
                Write-WizardDebug (Get-WizardErrorDetail -ErrorRecord $_)
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

    try {
        Save-WizardJsonFile -Path $CachePath -Value $results -Depth 5
    } catch {
        # A read-only -Path is a perfectly valid way to run this tool; losing the
        # cache only means the next run re-downloads content.
        Write-Warning "Could not write the hash cache to '$CachePath': $($_.Exception.Message). The next run will rebuild it."
    }
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
    # Bounded so a service that keeps handing back a nextLink cannot spin here
    # forever. An assignment set large enough to hit this does not exist.
    $page = 0
    # Graph paginates large result sets: a response can include an
    # '@odata.nextLink' URI pointing to the next page instead of returning
    # everything at once. Looping until there's no nextLink collects it all.
    while ($uri -and $page -lt 100) {
        Write-WizardDebug "GET $uri"
        try {
            $response = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType Hashtable
        } catch {
            throw "Could not read the assignments of script $Id : $(Get-WizardErrorSummary -ErrorRecord $_)"
        }
        if ($response['value']) { $all += @($response['value']) }
        $uri = $response['@odata.nextLink']
        $page++
    }
    if ($uri) {
        throw "Reading the assignments of script $Id did not finish after $page pages. Aborting rather than backing up a partial assignment set."
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

    # Build a hashtable matching the JSON shape the 'assign' action expects,
    # then serialize it to a JSON string. -Depth 10 avoids ConvertTo-Json's
    # default depth limit truncating nested objects like assignment targets.
    $body = @{ deviceManagementScriptAssignments = @($Assignments) }
    $json = $body | ConvertTo-Json -Depth 10
    $uri = "$script:ScriptsUri/$Id/assign"

    Write-WizardDebug "POST $uri"
    Write-WizardDebug "  body: $json"
    try {
        # POST sends data to the server (as opposed to GET, which only reads).
        # Out-Null discards the response since nothing here needs it.
        Invoke-MgGraphRequest -Method POST -Uri $uri -Body $json -ContentType 'application/json' | Out-Null
    } catch {
        # A 400 here is almost always a group id the tenant does not recognise,
        # which the pre-flight cannot catch for GUIDs supplied directly.
        throw "The assign action was rejected: $(Get-WizardErrorSummary -ErrorRecord $_). Check that every #group:/#excludegroup: GUID exists in this tenant."
    }
}

# Small helper: wraps a target (e.g. "this group" or "all devices") in the
# envelope shape a single assignment entry needs.
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

# Works out the desired assignment set for a script's metadata and pushes it
# to Graph as a single replace-everything call.
function Set-WizardAssignments {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)]$Meta)

    # @(...) is load-bearing: a function returning an empty array hands back
    # $null through the pipeline, which the -Assignments parameter rejects.
    # Without it, #noassignments fails instead of clearing the assignments.
    # The backtick ` at the end of a line is PowerShell's line-continuation
    # character, letting one command be written across several lines.
    $assignments = @(Get-WizardDesiredAssignments `
        -Type $Meta.Type `
        -NoAssignments:$Meta.NoAssignments `
        -IncludeGroupIds $Meta.IncludeGroupIds `
        -ExcludeGroupIds $Meta.ExcludeGroupIds)

    Set-WizardWholeAssignment -Id $Id -Assignments $assignments
}

# Creates a brand-new deviceManagementScript in Intune from local script
# metadata, then assigns it.
function New-WizardScript {
    param([Parameter(Mandatory)]$Meta)

    Write-Host "Creating '$($Meta.DisplayName)' ($($Meta.Type))..."
    Write-WizardDebug "New script: file=$($Meta.FileName) runAs=$($Meta.RunAsAccount) 32bit=$($Meta.RunAs32Bit) sigCheck=$($Meta.EnforceSignatureCheck) noAssign=$($Meta.NoAssignments)"

    try {
        # -ScriptContentInputFile lets the cmdlet read and base64-encode the
        # script file itself, so this code never has to do that by hand.
        $script = New-MgBetaDeviceManagementScript `
            -DisplayName $Meta.DisplayName `
            -Description $Meta.Description `
            -FileName $Meta.FileName `
            -ScriptContentInputFile $Meta.Path `
            -RunAsAccount $Meta.RunAsAccount `
            -EnforceSignatureCheck:$Meta.EnforceSignatureCheck `
            -RunAs32Bit:$Meta.RunAs32Bit
    } catch {
        throw "Creating '$($Meta.DisplayName)' failed: $(Get-WizardErrorSummary -ErrorRecord $_)"
    }

    if (-not $script -or -not $script.Id) {
        throw "Creating '$($Meta.DisplayName)' returned no script id, so its assignments cannot be set. Check the script in the Intune portal before re-running."
    }

    Write-WizardDebug "Created $($script.Id)"

    # Create and assign are two calls with no transaction between them. If the
    # second fails the script exists but reaches nobody, which looks exactly like
    # a script that has not deployed yet - so the id goes in the message, because
    # the next run will not find it by content hash if the file changes again.
    try {
        Set-WizardAssignments -Id $script.Id -Meta $Meta
    } catch {
        throw "'$($Meta.DisplayName)' was created in Intune as $($script.Id) but its assignments could not be set: $(Get-WizardErrorSummary -ErrorRecord $_). The script exists and is assigned to nobody; re-run to finish it, or delete it in the portal."
    }

    return $script
}

# Updates an existing deviceManagementScript's content/settings in place, after
# backing it up first, then re-applies its assignments.
function Update-WizardScript {
    param(
        [Parameter(Mandatory)]$Meta,
        [Parameter(Mandatory)][string]$ExistingId,
        [Parameter(Mandatory)][string]$BackupDir
    )

    # Deliberately not wrapped: if the backup cannot be taken, the update must
    # not happen either. That is the whole point of taking one.
    $backupPath = Backup-WizardScript -Id $ExistingId -BackupDir $BackupDir

    Write-Host "Updating '$($Meta.DisplayName)' ($($Meta.Type))..."
    Write-WizardDebug "Update $ExistingId from $($Meta.Path)"

    # Every failure from here on leaves the existing script in some intermediate
    # state, so the backup path travels with the error - restoring it is the one
    # action that always puts the tenant back the way it was.
    $restoreHint = "Restore the previous state with: -Restore '$backupPath'"

    try {
        Update-MgBetaDeviceManagementScript `
            -DeviceManagementScriptId $ExistingId `
            -DisplayName $Meta.DisplayName `
            -Description $Meta.Description `
            -FileName $Meta.FileName `
            -ScriptContentInputFile $Meta.Path `
            -RunAsAccount $Meta.RunAsAccount `
            -EnforceSignatureCheck:$Meta.EnforceSignatureCheck `
            -RunAs32Bit:$Meta.RunAs32Bit | Out-Null
    } catch {
        throw "Updating '$($Meta.DisplayName)' ($ExistingId) failed: $(Get-WizardErrorSummary -ErrorRecord $_). $restoreHint"
    }

    try {
        Set-WizardAssignments -Id $ExistingId -Meta $Meta
    } catch {
        throw "'$($Meta.DisplayName)' ($ExistingId) was updated but its assignments were not: $(Get-WizardErrorSummary -ErrorRecord $_). The new script content is live against the old assignments. $restoreHint"
    }
}

# Deletes a deviceManagementScript from Intune entirely.
function Remove-WizardScript {
    # No caller in Deploy-IntuneScripts.ps1 itself - the wizard never deletes
    # anything on its own. Used by e2e-tests/Remove-E2ETestSet.ps1 to tear
    # down scripts it created, and by hand for one-off cleanup.
    param([Parameter(Mandatory)][string]$Id)

    Write-WizardDebug "Deleting $Id"
    try {
        Remove-MgBetaDeviceManagementScript -DeviceManagementScriptId $Id
    } catch {
        throw "Could not delete script $Id : $(Get-WizardErrorSummary -ErrorRecord $_)"
    }
}

