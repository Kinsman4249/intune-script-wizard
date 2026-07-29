# Prereqs.ps1
# Checks the PowerShell host version and makes sure only the two small Graph
# modules this tool actually needs are installed - NOT the full "Microsoft.Graph"
# meta-module, which pulls in every service module (multiple GB).

$script:RequiredModules = @(
    'Microsoft.Graph.Authentication'
    'Microsoft.Graph.Beta.DeviceManagement'
)

# Checks whether this session has a real person at the keyboard who could
# answer a Y/N prompt, as opposed to running unattended.
function Test-WizardInteractive {
    # False when there is no human to answer a prompt: a pipeline, a scheduled
    # task, a CI job. Read-Host against a redirected stdin does not fail - it
    # returns an empty string - so without this check an unattended run would
    # silently take the default answer to every question it should have refused
    # to ask.
    # [Console]::IsInputRedirected and [Environment]::UserInteractive are .NET
    # checks (PowerShell can call straight into .NET classes with [ClassName]::Method).
    if ([Console]::IsInputRedirected) { return $false }
    if (-not [Environment]::UserInteractive) { return $false }
    return $true
}

# Stops the script early with a clear error if it's running on too old a
# version of PowerShell, instead of failing later with a confusing error.
function Test-WizardPSVersion {
    # #Requires -Version 7.0 already covers running the file directly; this
    # catches the dot-sourced and module-imported cases, where #Requires on the
    # entry script is not evaluated.
    # $PSVersionTable is a built-in variable holding info about the running
    # PowerShell engine, including its version number.
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "This tool requires PowerShell 7 or later (found $($PSVersionTable.PSVersion)). Install PS7 (pwsh) and re-run."
    }
}

function Test-WizardModules {
    # Returns the list of required modules that are not yet installed.
    $missing = @()
    foreach ($name in $script:RequiredModules) {
        # Get-Module -ListAvailable looks at modules installed on disk (not
        # just ones already loaded into this session). If it finds nothing,
        # the module isn't installed yet.
        if (-not (Get-Module -ListAvailable -Name $name)) {
            $missing += $name
        }
    }
    return $missing
}

# Installs any of the required Graph modules that are missing, asking for
# confirmation first unless the caller already agreed via -AcceptInstall.
function Install-WizardModules {
    param(
        # [switch] makes this an on/off flag rather than a value you type in -
        # callers just add -AcceptInstall with no argument to turn it on.
        [switch]$AcceptInstall
    )

    $missing = Test-WizardModules
    if ($missing.Count -eq 0) {
        return
    }

    Write-Host "The following required modules are missing:" -ForegroundColor Yellow
    $missing | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    Write-Host "(Only these two small modules are installed - not the full Microsoft.Graph meta-module.)"

    if (-not $AcceptInstall) {
        if (-not (Test-WizardInteractive)) {
            throw "Required modules are missing ($($missing -join ', ')) and this session cannot prompt. Re-run with -AcceptModuleInstall, or install them first with: Install-Module $($missing -join ', ') -Scope CurrentUser"
        }
        # Read-Host pauses and waits for the user to type an answer and press Enter.
        $answer = Read-Host "Install them now for the current user? (y/N)"
        if ($answer -notmatch '^(y|yes)$') {
            throw "Required modules are missing and installation was declined. Re-run with -AcceptModuleInstall to skip this prompt."
        }
    }

    foreach ($name in $missing) {
        Write-Host "Installing $name ..."
        try {
            # Install-Module downloads and installs a module from a repository
            # (PSGallery is the public PowerShell Gallery). -Scope CurrentUser
            # avoids needing admin rights. -ErrorAction Stop makes any failure
            # throw a catchable error instead of just printing a warning.
            Install-Module -Name $name -Scope CurrentUser -Repository PSGallery -Force -AllowClobber -ErrorAction Stop
        } catch {
            # The usual causes are all environmental and all fixable, so name
            # them rather than leaving a bare PackageManagement error on screen.
            throw "Could not install '$name': $($_.Exception.Message). Check network access to the PowerShell Gallery (proxy, TLS 1.2), that the PSGallery repository is registered (Get-PSRepository), and that the current user can write to its module path."
        }
    }
}

# Loads the required Graph modules into the current session so their
# cmdlets (like Connect-MgGraph) become available to use.
function Import-WizardModules {
    foreach ($name in $script:RequiredModules) {
        try {
            # Import-Module loads an already-installed module into memory for
            # this session. This is a separate step from installing it.
            Import-Module -Name $name -ErrorAction Stop
        } catch {
            throw "Could not load module '$name': $($_.Exception.Message). It may be a partial or corrupt install - try: Uninstall-Module $name -AllVersions; Install-Module $name -Scope CurrentUser"
        }
    }
}
