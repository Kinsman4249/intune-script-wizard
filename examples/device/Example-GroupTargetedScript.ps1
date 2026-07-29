# This script lives under device/, so it runs as SYSTEM. Unlike the other
# device example, it is not assigned to all devices: the #group: comments below
# narrow it to a specific set.

#scriptname:"Example - Group Targeted"

#startdesc
#Demonstrates custom assignment. Targets one group by display name and one by
#object GUID, then excludes the pilot ring from both.
#enddesc

# Named group. Resolved against Entra ID at deploy time, so the wizard asks for
# the GroupMember.Read.All scope when it sees one of these. The name must match
# exactly one group, or the run aborts rather than guessing.
#group:"Helpdesk Laptops"

# Same tag, GUID form. No directory lookup needed - use this when a group name
# is ambiguous, or when you want the target pinned even if the group is renamed.
#group:6f9a1c22-6b7e-4a11-9f3d-2c8e5b7a1d40

# Carve a subset back out. Exclusions can also be used on their own, without any
# #group:, to mean "everyone except these".
#excludegroup:"Pilot Ring"

$markerDir = 'C:\ProgramData\Corp'
if (-not (Test-Path $markerDir)) {
    New-Item -ItemType Directory -Path $markerDir -Force | Out-Null
}
Set-Content -Path (Join-Path $markerDir 'group-targeted-ran.txt') -Value (Get-Date).ToString('o')
