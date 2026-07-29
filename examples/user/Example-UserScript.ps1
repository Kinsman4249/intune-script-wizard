# This script lives under user/, so it deploys with
# "Run this script using the logged on credentials" = Yes.
# (Placing it under device/ instead would set that to No - no #type comment needed either way.)

#scriptname:"Set Desktop Wallpaper"
#startdesc
#Sets the corporate wallpaper for the signed-in user.
#Safe to re-run; it just overwrites the current wallpaper path.
#enddesc

# #scriptcheck:yes        -- uncomment to require a trusted-publisher signature (off by default)
# #host:64                -- uncomment to run under 64-bit PowerShell (32-bit by default)
# #noassignments           -- uncomment to deploy without assigning to All Users

$wallpaperPath = "$env:ProgramData\Corp\wallpaper.jpg"
if (Test-Path $wallpaperPath) {
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name Wallpaper -Value $wallpaperPath
    RUNDLL32.EXE user32.dll, UpdatePerUserSystemParameters
}
