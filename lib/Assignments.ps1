# Assignments.ps1
# Everything about a deviceManagementScript's assignments: reading the current
# set, building the desired set from a script's meta comments, and pushing it
# back as a single full-replacement 'assign' action. Split out of GraphOps.ps1.
#
# Assignments are deliberately NOT done with per-item cmdlets - see the comment
# above Set-WizardWholeAssignment for why.

# Relative Graph URIs. Invoke-MgGraphRequest prefixes the endpoint of whichever
# cloud the session connected to, so this keeps working in GCC High / DoD /
# 21Vianet without any per-cloud base URL of our own.
$script:ScriptsUri = '/beta/deviceManagement/deviceManagementScripts'

# Maps our simple 'user'/'device' choice to the Graph @odata.type name used
# when no specific group is targeted (i.e. "assign to everyone").
function Get-WizardAssignmentTargetType {
    # ValidateSet restricts the parameter to only these two values; PowerShell
    # rejects anything else before the function body even runs.
    param([Parameter(Mandatory)][ValidateSet('user', 'device')][string]$Type)
    if ($Type -eq 'user') { 'allLicensedUsersAssignmentTarget' } else { 'allDevicesAssignmentTarget' }
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
            $response = Invoke-WizardGraphRetry -What "Reading the assignments of script $Id" -Call {
                Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType Hashtable
            }
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
        Invoke-WizardGraphRetry -What "Assigning script $Id" -Call {
            Invoke-MgGraphRequest -Method POST -Uri $uri -Body $json -ContentType 'application/json' | Out-Null
        }
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
