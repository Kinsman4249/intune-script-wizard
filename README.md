# intune-script-wizard

Deploys PowerShell platform scripts to Microsoft Intune from local `user/` and
`device/` folders (or loose scripts carrying a `#type:` comment), using the
Microsoft Graph beta `deviceManagementScript` API. Can also pull scripts
straight from a git repo, template a tenant's current scripts back out for
promotion into another one, and keep backups/templates in sync with a remote
repo automatically.

## What it does

- Walks `user/` and `device/` subfolders (recursively) for `.ps1` files.
  - Scripts under `user/` deploy with **"Run this script using the logged on
    credentials" = Yes** (`RunAsAccount = user`).
  - Scripts under `device/` deploy with that setting **= No**
    (`RunAsAccount = system`).
  - Loose scripts outside those folders need a `#type:user` or `#type:device`
    comment instead.
- Creates a new Intune script for anything it hasn't seen before, and updates
  existing ones in place when the local file changes - see [Duplicate
  handling](docs/backups-and-restore.md).
- Assigns each script to "All users" or "All devices" (matching its type)
  unless the script opts out - see [Meta comments](docs/meta-comments.md).
- Defaults are chosen for an MSP without code-signing infrastructure:
  signature enforcement off, 32-bit PowerShell host. Both can be overridden
  per script.

## Quick start

```powershell
# From a folder containing user/ and/or device/ subfolders:
./Deploy-IntuneScripts.ps1

# Preview what would happen without changing anything in Intune:
./Deploy-IntuneScripts.ps1 -DryRun
```

See [Usage and flags](docs/usage.md) for the full command reference and exit
codes.

## Documentation

| Doc | Covers |
| --- | --- |
| [Meta comments](docs/meta-comments.md) | The `#` directives that control name, description, type, and assignment target; targeting specific groups |
| [Backups, restore and templates](docs/backups-and-restore.md) | Duplicate handling, `-Restore`/`-RestoreAll`, `-Backup`/`-BackupAll`, exporting `.ps1` templates, pushing backups/templates to a remote repo |
| [Sourcing scripts from a git repo](docs/sourcing.md) | `-SourceRepo`: pulling scripts from one or more git repos alongside `-Path` |
| [Dry runs and plans](docs/dry-run-and-plans.md) | `-SavePlan`/`-ApplyPlan` for reviewing a dry run and replaying it later; `-ReportCsv` for a sign-off report |
| [Setup](docs/setup.md) | Prerequisites, optional `gh`/`az` CLIs, the `az login` WAM/MSAL cache fix, and signing in |
| [Usage and flags](docs/usage.md) | Full command examples, the flags table, exit codes, and debug logging |
| [Technical notes](docs/technical.md) | How assignments are applied via the Graph `assign` action; throttling and retry behaviour |
| [Testing](docs/testing.md) | Running the offline test suite and the [e2e-tests/](e2e-tests) |
| [Telemetry](docs/telemetry.md) | What crash reporting sends and how to opt out (see also [PRIVACY.md](PRIVACY.md)) |

## Prerequisites (short version)

- PowerShell 7+ (`pwsh`).
- An account with the `DeviceManagementConfiguration.ReadWrite.All` and
  `DeviceManagementScripts.ReadWrite.All` Graph scopes (e.g. Intune
  Administrator).

Full detail, optional CLIs, and the `az login` troubleshooting note are in
[Setup](docs/setup.md).

## License

Business Source License 1.1 - see [LICENSE](LICENSE). **Not** an open source
license.

**Internal use only.** Production use is granted solely for administering
Intune tenants your own organization owns and operates. Using this tool - or a
derivative of it - against a client, customer, or any other third party's
tenant, including as part of a managed-services, consulting, or reseller
engagement, requires a separate written license agreement with the Licensor,
agreed in advance. Contact the Licensor to arrange one.

Evaluation, development, and testing are unrestricted. The Change Date is
2030-08-06, after which the work becomes available under GPLv3.
