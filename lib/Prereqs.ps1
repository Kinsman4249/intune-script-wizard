# Prereqs.ps1
# Checks the PowerShell host version and makes sure only the two small Graph
# modules this tool actually needs are installed - NOT the full "Microsoft.Graph"
# meta-module, which pulls in every service module (multiple GB).

$script:RequiredModules = @(
    'Microsoft.Graph.Authentication'
    'Microsoft.Graph.Beta.DeviceManagement'
)

function Test-WizardPSVersion {
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
        $answer = Read-Host "Install them now for the current user? (y/N)"
        if ($answer -notmatch '^(y|yes)$') {
            throw "Required modules are missing and installation was declined. Re-run with -AcceptModuleInstall to skip this prompt."
        }
    }

    foreach ($name in $missing) {
        Write-Host "Installing $name ..."
        Install-Module -Name $name -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
    }
}

function Import-WizardModules {
    foreach ($name in $script:RequiredModules) {
        Import-Module -Name $name -ErrorAction Stop
    }
}
