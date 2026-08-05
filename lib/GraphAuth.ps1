# GraphAuth.ps1
# Signing in to Microsoft Graph (scopes, the fresh-session-every-run rule, the
# typed tenant confirmation) and resolving group references both ways: a
# display name to its object id for deployment, and an id back to its name for
# template export. Split out of GraphOps.ps1 as a self-contained concern.

# "Scopes" are the specific permissions this app asks the signed-in user (or
# admin) to grant, e.g. "let me read and write Intune device management config".
$script:RequiredScopes = @('DeviceManagementConfiguration.ReadWrite.All', 'DeviceManagementScripts.ReadWrite.All')

# Only requested when at least one script names a group by display name rather
# than by GUID. Asking for it unconditionally would force every user to re-consent
# to a directory read they may never need.
$script:GroupReadScope = 'GroupMember.Read.All'

# Drops any Graph session already active in this process. Called both before
# connecting (a session left over from an earlier run, or from a Connect-MgGraph
# the operator ran by hand for a different tenant earlier in the same shell,
# must never be silently reused) and once the wizard is finished. Best-effort:
# a failed or unnecessary disconnect must never throw, since it runs from a
# 'finally' block and must not mask the run's real exit code.
function Disconnect-WizardGraph {
    try {
        # The auth module may not be imported yet (e.g. -ListBackups returns
        # before Import-WizardModules ever runs), in which case there is no
        # session to drop.
        if (-not (Get-Command Get-MgContext -ErrorAction SilentlyContinue)) { return }
        if (Get-MgContext) {
            Disconnect-MgGraph -ErrorAction Stop | Out-Null
            Write-WizardDebug "Disconnected existing Microsoft Graph session."
        }
    } catch {
        Write-WizardDebug "Disconnect-MgGraph failed (ignored): $($_.Exception.Message)"
    }
}

# A second, typed confirmation on top of the interactive sign-in itself: the
# account picker in a browser sign-in flow is easy to click through on
# autopilot, and this tool changes Intune config, so it asks the operator to
# type the tenant back before touching anything. Skipped for unattended runs
# (scheduled tasks, CI) since there is nobody to answer it - the tenant/account
# is still logged prominently so it shows up in that run's own output.
function Confirm-WizardTenant {
    param([Parameter(Mandatory)]$Context)

    if (-not (Test-WizardInteractive)) {
        Write-Host "Connected to Microsoft Graph as $($Context.Account) (tenant $($Context.TenantId)). Running unattended, skipping tenant confirmation." -ForegroundColor DarkGray
        return
    }

    # The account's UPN domain (e.g. 'contoso.onmicrosoft.com' or a verified
    # custom domain) is a human-readable stand-in for the tenant - no extra
    # Graph scope needed to look it up, unlike the tenant's display name.
    $domain = ($Context.Account -split '@')[-1]
    Write-Host ""
    Write-Host "Connected to Microsoft Graph:" -ForegroundColor Yellow
    Write-Host "  Account : $($Context.Account)"
    Write-Host "  Tenant  : $($Context.TenantId)"
    Write-Host ""
    $typed = [string](Read-Host "Type the tenant domain ('$domain') to confirm this is the right tenant before anything is changed")
    if ($typed -ne $domain) {
        throw "Tenant confirmation did not match (expected '$domain', got '$typed'). Aborting before making any changes. If this is the wrong account, run Disconnect-MgGraph and re-run the wizard to sign in again."
    }
}

# Signs the current PowerShell session in to Microsoft Graph, requesting only
# the permission scopes this run actually needs.
function Connect-WizardGraph {
    # param() declares this function's inputs. Each [type] before a name is a
    # type constraint; [string[]] means "an array of strings".
    param(
        # Extra scopes needed by this particular run, e.g. the directory read
        # used to turn a #group:"Name" into an object id. Treated exactly like
        # $script:RequiredScopes: a tenant that does not grant one of these
        # fails the whole sign-in.
        [string[]]$AdditionalScopes = @(),

        # Scopes worth asking for but not worth failing over, e.g. the
        # directory read used to reverse-resolve a group id back into a name
        # for template export. A tenant that declines one of these degrades
        # (bare GUIDs instead of names) rather than blocking sign-in - see
        # Test-WizardGroupScopeGranted.
        [string[]]$OptionalScopes = @()
    )

    # Required scopes (always-needed + this run's extras) are checked strictly
    # below. Optional scopes ride along in the same consent request but are
    # deliberately left out of that check.
    $requiredScopes = @($script:RequiredScopes) + @($AdditionalScopes) | Select-Object -Unique
    $scopes = @($requiredScopes) + @($OptionalScopes) | Select-Object -Unique

    # Always start from a clean slate. Reusing an already-signed-in context
    # (the previous behaviour) meant a session opened for one tenant earlier in
    # the same shell would be used silently for this run too - exactly the
    # wrong-tenant mistake this wizard cannot afford to make quietly. Forcing a
    # fresh sign-in every time makes the account/tenant an explicit choice.
    Disconnect-WizardGraph

    # try/catch runs the try block, and if anything inside throws an error, jumps
    # to catch instead of crashing the whole script.
    try {
        Write-WizardDebug "Connecting to Graph with scopes: $($scopes -join ', ')"
        # Connect-MgGraph is the SDK cmdlet that opens the sign-in flow
        # (browser or device code) and establishes the Graph session.
        Connect-MgGraph -Scopes $scopes -NoWelcome -ErrorAction Stop
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
    $notGranted = @($requiredScopes | Where-Object { $_ -notin $granted })
    if ($notGranted.Count -gt 0) {
        throw "Signed in as $($context.Account), but the tenant did not grant: $($notGranted -join ', '). An administrator needs to consent to these scopes before the wizard can run."
    }

    Write-WizardDebug "Graph context: tenant=$($context.TenantId) account=$($context.Account) type=$($context.AuthType)"
    Confirm-WizardTenant -Context $context
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
        $response = Invoke-WizardGraphRetry -What "Looking up group '$Name'" -Call {
            Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType Hashtable
        }
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

# Reverse of Resolve-WizardGroupName: turns a group's object id back into its
# display name, for template export where only the id is known (this is what
# makes an exported template portable across tenants at all - see handoff).
#
# Unlike the forward lookup, a miss here is not fatal: a template with one
# bare GUID in it is still a usable template, so this returns $null instead
# of throwing, and leaves it to the caller to fall back to the GUID and warn.
#
# $State carries a GroupNames cache (id -> name, $null included for a miss) so
# a deleted or inaccessible group is looked up once per run, not once per
# script, and a GroupScopeOk flag: once a lookup fails for a reason other than
# "not found" (i.e. a 403 from a declined GroupMember.Read.All), every
# subsequent call short-circuits instead of repeating the same failure.
function Resolve-WizardGroupDisplayName {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)]$State
    )

    if ($State.GroupNames.ContainsKey($Id)) { return $State.GroupNames[$Id] }

    if ($State.GroupScopeOk -eq $false) { return $null }

    $uri = '/v1.0/groups/' + $Id + '?$select=id,displayName'
    Write-WizardDebug "GET $uri"
    try {
        $response = Invoke-WizardGraphRetry -What "Looking up group $Id" -Call {
            Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType Hashtable
        }
        $name = $response['displayName']
        $State.GroupNames[$Id] = $name
        Write-WizardDebug "  $Id -> '$name'"
        return $name
    } catch {
        if (Test-WizardGraphNotFound -ErrorRecord $_) {
            Write-WizardDebug "  group $Id not found (likely deleted); caching as unresolved"
        } else {
            Write-WizardDebug "  group $Id lookup failed, treating as a missing scope and suppressing further lookups this run: $(Get-WizardErrorSummary -ErrorRecord $_)"
            $State.GroupScopeOk = $false
        }
        $State.GroupNames[$Id] = $null
        return $null
    }
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

# Whether the current Graph session was actually granted $script:GroupReadScope.
# Meant to be checked once up front (e.g. to seed a template run's
# GroupScopeOk) so a declined optional scope produces one clear explanation
# instead of a 403 per group, per script.
function Test-WizardGroupScopeGranted {
    $context = Get-MgContext
    if (-not $context) { return $false }
    return ($script:GroupReadScope -in @($context.Scopes))
}
