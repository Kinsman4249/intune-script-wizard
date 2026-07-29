# This script lives under device/, so it deploys with
# "Run this script using the logged on credentials" = No (runs as SYSTEM).

# No #scriptname comment here on purpose - the display name in Intune will
# just be the filename: "Example-DeviceScript".

#startdesc
#Creates a marker file so we can confirm the device-context deployment worked.
#enddesc

$markerDir = 'C:\ProgramData\Corp'
if (-not (Test-Path $markerDir)) {
    New-Item -ItemType Directory -Path $markerDir -Force | Out-Null
}
Set-Content -Path (Join-Path $markerDir 'device-script-ran.txt') -Value (Get-Date).ToString('o')
