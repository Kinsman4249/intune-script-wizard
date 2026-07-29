# Prereqs.ps1
# Checks the PowerShell host version and makes sure only the two small Graph
# modules this tool actually needs are installed - NOT the full "Microsoft.Graph"
# meta-module, which pulls in every service module (multiple GB).

$script:RequiredModules = @(
    'Microsoft.Graph.Authentication'
    'Microsoft.Graph.Beta.DeviceManagement'
)

function Test-WizardInteractive {
    # False when there is no human to answer a prompt: a pipeline, a scheduled
    # task, a CI job. Read-Host against a redirected stdin does not fail - it
    # returns an empty string - so without this check an unattended run would
    # silently take the default answer to every question it should have refused
    # to ask.
    if ([Console]::IsInputRedirected) { return $false }
    if (-not [Environment]::UserInteractive) { return $false }
    return $true
}

function Test-WizardPSVersion {
    # #Requires -Version 7.0 already covers running the file directly; this
    # catches the dot-sourced and module-imported cases, where #Requires on the
    # entry script is not evaluated.
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "This tool requires PowerShell 7 or later (found $($PSVersionTable.PSVersion)). Install PS7 (pwsh) and re-run."
    }
}

function Test-WizardModules {
    # Returns the list of required modules that are not yet installed.
    $missing = @()
    foreach ($name in $script:RequiredModules) {
        if (-not (Get-Module -ListAvailable -Name $name)) {
            $missing += $name
        }
    }
    return $missing
}

function Install-WizardModules {
    param(
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
        $answer = Read-Host "Install them now for the current user? (y/N)"
        if ($answer -notmatch '^(y|yes)$') {
            throw "Required modules are missing and installation was declined. Re-run with -AcceptModuleInstall to skip this prompt."
        }
    }

    foreach ($name in $missing) {
        Write-Host "Installing $name ..."
        try {
            Install-Module -Name $name -Scope CurrentUser -Repository PSGallery -Force -AllowClobber -ErrorAction Stop
        } catch {
            # The usual causes are all environmental and all fixable, so name
            # them rather than leaving a bare PackageManagement error on screen.
            throw "Could not install '$name': $($_.Exception.Message). Check network access to the PowerShell Gallery (proxy, TLS 1.2), that the PSGallery repository is registered (Get-PSRepository), and that the current user can write to its module path."
        }
    }
}

function Import-WizardModules {
    foreach ($name in $script:RequiredModules) {
        try {
            Import-Module -Name $name -ErrorAction Stop
        } catch {
            throw "Could not load module '$name': $($_.Exception.Message). It may be a partial or corrupt install - try: Uninstall-Module $name -AllVersions; Install-Module $name -Scope CurrentUser"
        }
    }
}
