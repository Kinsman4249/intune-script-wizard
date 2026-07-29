# intune-script-wizard

Deploys PowerShell platform scripts to Microsoft Intune from local `user/` and
`device/` folders (or loose scripts carrying a `#type:` comment), using the
Microsoft Graph beta `deviceManagementScript` API.

## What it does

- Walks `user/` and `device/` subfolders (recursively) for `.ps1` files.
  - Scripts under `user/` deploy with **"Run this script using the logged on
    credentials" = Yes** (`RunAsAccount = user`).
  - Scripts under `device/` deploy with that setting **= No**
    (`RunAsAccount = system`).
  - Loose scripts outside those folders need a `#type:user` or `#type:device`
    comment instead.
- Creates a new Intune script for anything it hasn't seen before, and updates
  existing ones in place when the local file changes - see "Duplicate
  handling" below.
- Assigns each script to "All users" or "All devices" (matching its type)
  unless the script opts out.
- Defaults are chosen for an MSP without code-signing infrastructure:
  signature enforcement off, 32-bit PowerShell host. Both can be overridden
  per script.

## Meta comments

Add these as plain `#` comments anywhere in a script. They're left in the
uploaded script content - they're valid PowerShell comments and have no
effect on the endpoint.

| Comment | Effect |
| --- | --- |
| `#scriptname:"Override Name"` | Display name in Intune (default: filename minus `.ps1`) |
| `#startdesc` ... `#enddesc` | Lines between these become the description (default: blank) |
| `#type:user` or `#type:device` | Required only for scripts not under a `user/`/`device/` folder |
| `#noassignments` (or `#noassigments`) | Do not assign this script to anyone |
| `#group:"Name"` or `#group:<guid>` | Assign to this group instead of all users/devices. Repeatable |
| `#excludegroup:"Name"` or `#excludegroup:<guid>` | Exclude this group from the assignment. Repeatable |
| `#scriptcheck:yes` | Enforce script signature check (default: off) |
| `#host:64` | Run under 64-bit PowerShell host (default: 32-bit) |

See [examples/user/Example-UserScript.ps1](examples/user/Example-UserScript.ps1)
and [examples/device/Example-DeviceScript.ps1](examples/device/Example-DeviceScript.ps1).

### Targeting specific groups

By default a script goes to **all users** (`user/`) or **all devices**
(`device/`). `#group:` overrides that; `#excludegroup:` carves groups back out.

```powershell
# Just this group:
#group:"Helpdesk Laptops"

# Several groups, mixing display names and object GUIDs:
#group:"Helpdesk Laptops"
#group:6f9a1c22-6b7e-4a11-9f3d-2c8e5b7a1d40

# Everyone except the pilot ring - no #group:, so the default include stays:
#excludegroup:"Pilot Ring"

# A group, minus a subset of it:
#group:"All Laptops"
#excludegroup:"Pilot Ring"
```

Notes:

- A value that parses as a GUID is used as-is. Anything else is treated as a
  display name and resolved against Entra ID, which needs the
  `GroupMember.Read.All` scope. That scope is **only** requested when at least
  one script actually names a group, so GUID-only setups keep the consent
  footprint they have today.
- Resolution happens as a pre-flight over every script, before anything is
  created or updated. A name that matches no group, or more than one, aborts
  the whole run rather than leaving it half applied. Duplicate group names are
  legal in Entra ID, so the tool refuses to guess - use the GUID instead.
- Assignments are a full replacement, so adding `#group:` to a script that was
  previously assigned to all devices moves it; it doesn't stack.
- `#noassignments` combined with `#group:`/`#excludegroup:`, or the same group
  listed as both include and exclude, is rejected at parse time.
- `-DryRun` prints the resolved target for each script, so you can confirm the
  intent before anything changes.

## Duplicate handling

Before creating anything, the tool hashes each local script's content
(SHA256) and compares it against every script already in Intune (cached
locally in `.intune-script-cache.json` so repeat runs don't re-download
unchanged content).

- **Exact content + exact name match** - already in sync, skipped.
- **Exact name match, different content** - updated in place. The existing
  script is backed up to `backups/` first (full JSON snapshot: content,
  settings, assignments) so it can be restored with one command if the
  update was wrong.
- **Identical content already deployed under a different name**, or a
  **fuzzy name/description match** (similar but not identical) - you're
  prompted per script: **[S]kip**, **[R]eplace** the existing one (backed up
  first), or create it **side-by-side**. Pass `-OnFuzzyMatch Skip|Replace|SideBySide`
  to resolve these non-interactively for unattended runs.

The fuzzy score is Levenshtein similarity on the display name, weighted 70/30
against the description when both sides have one. Two scripts with near-identical
names but genuinely different descriptions are more likely to be different
scripts than a rename of the same one, and the weighting reflects that.
Descriptions are compared on their first 200 characters only, to keep the
O(n*m) comparison bounded across a large tenant.

Two local scripts resolving to the same display name is rejected up front,
before anything is sent to the tenant - otherwise each would miss the other's
freshly created Intune object and you'd get silent duplicates. Rename the
files or disambiguate with `#scriptname:"..."`.

### Restoring a backup

```powershell
./Deploy-IntuneScripts.ps1 -Restore ./backups/Some-Script_20260728-193000.json
```

This pushes the backed-up content, settings, scope tags, and assignments back
onto the original script (or recreates it, with a new Id, if it was deleted
since the backup was taken). Assignment targets are snapshotted as the raw
Graph payload, so group targets keep their `groupId` and any assignment filter
id through a round trip.

List available backups with `./Deploy-IntuneScripts.ps1 -ListBackups`.

## Prerequisites

- PowerShell 7+ (`pwsh`).
- An account with the `DeviceManagementConfiguration.ReadWrite.All` Graph
  scope (e.g. Intune Administrator).

The script installs only the two modules it actually needs -
`Microsoft.Graph.Authentication` and `Microsoft.Graph.Beta.DeviceManagement` -
never the full `Microsoft.Graph` meta-module, which pulls in every Graph
service and is several GB. You'll be prompted before anything is installed
unless you pass `-AcceptModuleInstall`.

## Usage

```powershell
# From a folder containing user/ and/or device/ subfolders:
./Deploy-IntuneScripts.ps1

# Preview what would happen without changing anything in Intune:
./Deploy-IntuneScripts.ps1 -DryRun

# Point at a different folder, and don't get prompted for module installs:
./Deploy-IntuneScripts.ps1 -Path C:\scripts -AcceptModuleInstall

# Trace every Graph URL, request body and match score while diagnosing a failure:
./Deploy-IntuneScripts.ps1 -DryRun -DebugLog Console
```

### Debug logging

`-DebugLog` takes `None` (default), `Console`, `File`, or `Both`. `File` and
`Both` write `logs/wizard-<timestamp>.log` under `-Path`. Enabling it prints
the build stamp (version plus git short hash, marked `-dirty` for uncommitted
changes) so a pasted log can be tied to an exact build. `logs/` is gitignored.

## How assignments are set

Assignments are applied through the
[`assign` action](https://learn.microsoft.com/en-us/graph/api/intune-shared-devicemanagementscript-assign?view=graph-rest-beta)
(`POST /beta/deviceManagement/deviceManagementScripts/{id}/assign`), not with
per-assignment cmdlets. The beta module ships only
`Get-MgBetaDeviceManagementScriptAssignment`; there is no documented `New-` or
`Remove-` counterpart, because assignments on a `deviceManagementScript` are
not a writable collection. Being a single full replacement, the action also
avoids the window in which a script sits unassigned between a delete and a
re-add. The call goes through `Invoke-MgGraphRequest` with a relative URI, so
it follows the connected cloud (GCC High, DoD, 21Vianet) automatically.

## Testing

```powershell
pwsh -NoProfile -File tests/Invoke-WizardTests.ps1
```

Graph is stubbed with fake `Microsoft.Graph.Authentication` and
`Microsoft.Graph.Beta.DeviceManagement` modules injected via `PSModulePath`, so
the real entry point runs end to end offline against an in-memory tenant. The
suite covers duplicate resolution (including that a **Skip** decision does not
fall through into a create), assign-action payload shape, backup/restore
fidelity for group targets and scope tags, `-DryRun` making no mutating calls,
and `-Path` validation.

After any change, still confirm against a non-production tenant with `-DryRun`
first, then for real, checking in the Intune portal (Devices > Scripts) that
the display name, "run as", signature check, 32/64-bit setting, and assignment
match what you expected.

## License

Business Source License 1.1 - see [LICENSE](LICENSE).
