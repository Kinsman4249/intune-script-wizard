# Prerequisites and setup

[<- Back to README](../README.md)

- PowerShell 7+ (`pwsh`).
- An account with the `DeviceManagementConfiguration.ReadWrite.All` and
  `DeviceManagementScripts.ReadWrite.All` Graph scopes (e.g. Intune
  Administrator).

The script installs only the two modules it actually needs -
`Microsoft.Graph.Authentication` and `Microsoft.Graph.Beta.DeviceManagement` -
never the full `Microsoft.Graph` meta-module, which pulls in every Graph
service and is several GB. You'll be prompted before anything is installed
unless you pass `-AcceptModuleInstall`.

## Optional: CLIs for pushing to a remote repo

Neither CLI below is required to run the wizard itself - they're only used by
the optional backup/template push (see [Pushing backups and templates to a
git repo](backups-and-restore.md#pushing-backups-and-templates-to-a-remote-repo))
and by `-SourceRepo` (see [Sourcing](sourcing.md)), and only if you choose a
provider that benefits from them:

- **`gh` (GitHub CLI)**: lets GitHub/GitLab pushes use one-command interactive
  sign-in instead of a manually-created personal access token. Install with
  `winget install GitHub.cli`.
- **`az` (Azure CLI)**: lets Azure DevOps pushes authenticate with `az login`
  and a short-lived Microsoft Entra token instead of a PAT. Install with
  `winget install Microsoft.AzureCLI`.

Without either installed, the wizard falls back to asking for a personal
access token instead - both CLIs are conveniences, not hard requirements.

### `az login` failing with "Can't find token from MSAL cache"

On Windows, even right after signing in: `az` defaults to signing in through
Web Account Manager (WAM), Windows' own auth broker. In an embedded/integrated
terminal (VS Code and forks of it included), WAM's sign-in popup can open
behind other windows, so `az login` reports success without ever finishing
the token grant for Azure DevOps. Force the older browser-based flow
instead:

```powershell
az account clear
az config set core.enable_broker_on_windows=false
az login
```

Source: [Sign into Azure interactively using the Azure CLI - Sign in with
WAM on
Windows](https://learn.microsoft.com/cli/azure/authenticate-azure-cli-interactively?view=azure-cli-latest#sign-in-with-web-account-manager-wam-on-windows).

## Signing in

Every run signs in fresh. Any Graph session already open in the PowerShell
session - one left over from an earlier run, or a `Connect-MgGraph` you ran by
hand - is disconnected first, so a session opened against one tenant can never
be silently reused for another. The wizard also disconnects when it finishes,
whether the run succeeded or failed.

Interactive runs then have to type back the signed-in account's domain before
anything is created, updated, or restored:

```
Connected to Microsoft Graph:
  Account : admin@contoso.onmicrosoft.com
  Tenant  : 8f4c...

Type the tenant domain ('contoso.onmicrosoft.com') to confirm this is the right
tenant before anything is changed:
```

The browser account picker is easy to click through on autopilot, and this tool
changes live Intune config, so the tenant has to be confirmed rather than
assumed. Unattended runs (scheduled tasks, CI) skip the prompt since nobody is
there to answer it, but still log the account and tenant.

Scopes are requested per run: `DeviceManagementConfiguration.ReadWrite.All` and
`DeviceManagementScripts.ReadWrite.All` always, plus `GroupMember.Read.All` when
a script names a group by display name. If the tenant grants fewer scopes than
were asked for, the run stops right there with the missing ones named, rather
than failing later on a confusing `403`.

A `-Backup`/`-BackupAll` run (unless `-NoTemplates` is passed) also requests
`GroupMember.Read.All`, but as *optional* rather than required - it's what
turns a group id back into a display name for the exported template (see
[Exporting templates](backups-and-restore.md#exporting-templates)). Unlike the
required scopes above, a tenant declining it doesn't fail sign-in or the run
at all; the export just falls back to bare GUIDs for any group reference,
with a warning per group affected.

---
[<- Back to README](../README.md) | [<- Dry runs and plans](dry-run-and-plans.md) | Next: [Usage and flags](usage.md) ->
