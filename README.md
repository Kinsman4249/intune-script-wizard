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
| `#scriptcheck:yes` | Enforce script signature check (default: off) |
| `#host:64` | Run under 64-bit PowerShell host (default: 32-bit) |

See [examples/user/Example-UserScript.ps1](examples/user/Example-UserScript.ps1)
and [examples/device/Example-DeviceScript.ps1](examples/device/Example-DeviceScript.ps1).

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

### Restoring a backup

```powershell
./Deploy-IntuneScripts.ps1 -Restore ./backups/Some-Script_20260728-193000.json
```

This pushes the backed-up content, settings, and assignments back onto the
original script (or recreates it, with a new Id, if it was deleted since the
backup was taken).

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
```

## Testing

There's no test suite yet - this is a thin wrapper around Graph cmdlets.
Verify a change by running against a non-production tenant (or a disposable
test script) with `-DryRun` first, then for real, and confirming in the
Intune portal (Devices > Scripts) that the display name, "run as", signature
check, 32/64-bit setting, and assignment match what you expected.

## License

Business Source License 1.1 - see [LICENSE](LICENSE).
