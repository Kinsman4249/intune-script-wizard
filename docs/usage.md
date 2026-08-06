# Usage

[<- Back to README](../README.md)

```powershell
# From a folder containing user/ and/or device/ subfolders:
./Deploy-IntuneScripts.ps1

# Preview what would happen without changing anything in Intune:
./Deploy-IntuneScripts.ps1 -DryRun

# Point at a different folder, and don't get prompted for module installs:
./Deploy-IntuneScripts.ps1 -Path C:\scripts -AcceptModuleInstall

# Trace every Graph URL, request body and match score while diagnosing a failure:
./Deploy-IntuneScripts.ps1 -DryRun -DebugLog Console

# Stop at the first script that fails instead of working through the rest:
./Deploy-IntuneScripts.ps1 -StopOnError

# Let every script's #type: comment win over the folder it sits in:
./Deploy-IntuneScripts.ps1 -AllowTypeOverride

# Resolve near-duplicates without prompting (for scheduled/unattended runs):
./Deploy-IntuneScripts.ps1 -OnFuzzyMatch Skip

# Back up one script, or the whole tenant, without deploying anything
# (also exports a .ps1 template for each - see "Exporting templates"):
./Deploy-IntuneScripts.ps1 -Backup "Payroll Script"
./Deploy-IntuneScripts.ps1 -BackupAll

# Same, but skip the template export:
./Deploy-IntuneScripts.ps1 -BackupAll -NoTemplates

# Pull scripts from a repo too, and save/replay a reviewed plan:
./Deploy-IntuneScripts.ps1 -SourceRepo https://github.com/contoso/intune-scripts.git
./Deploy-IntuneScripts.ps1 -DryRun -SavePlan ./deploy-plan.json -ReportCsv ./deploy-report.csv
./Deploy-IntuneScripts.ps1 -ApplyPlan ./deploy-plan.json
```

| Flag | Effect |
| --- | --- |
| `-Path <dir>` | Folder to scan (default: current directory) |
| `-DryRun` | Print what would happen; makes no changes |
| `-OnFuzzyMatch Skip\|Replace\|SideBySide` | Resolve near-duplicates without prompting |
| `-AllowTypeOverride` | Let `#type:` beat the `user/`/`device/` folder, run-wide |
| `-StopOnError` | Abandon the run at the first failure |
| `-AcceptModuleInstall` | Install missing Graph modules without prompting |
| `-Restore <file>` | Restore one backup (add `-RestoreAll` for a whole folder) |
| `-SkipAssignments` | With `-Restore`: restore content only, leave assignments as they are |
| `-Backup <name\|id>` | Back up one existing script on demand, no deploy |
| `-BackupAll` | Back up every script currently in the tenant |
| `-NoTemplates` | With `-Backup`/`-BackupAll`: skip the `.ps1` template export |
| `-ListBackups` | List available backups and exit |
| `-ResetRepoConfig Backups\|Templates\|All` | Delete the saved repo-push config so the setup prompt runs again; exits immediately |
| `-SourceRepo <url[#ref][::subpath]>` | Also pull scripts from a git repo (repeatable) |
| `-SavePlan <file>` | With `-DryRun`: save the exact plan to replay later |
| `-ApplyPlan <file>` | Replay a plan saved by `-SavePlan` as the real deploy |
| `-ReportCsv <file>` | With `-DryRun`: write the planned changes to a CSV |
| `-DebugLog None\|Console\|File\|Both` | Trace Graph URLs, bodies and match scores |

See [Backups, restore and templates](backups-and-restore.md) for `-Restore`/`-Backup`/`-BackupAll`,
[Sourcing](sourcing.md) for `-SourceRepo`, [Dry runs and plans](dry-run-and-plans.md) for
`-SavePlan`/`-ApplyPlan`/`-ReportCsv`, and [Meta comments](meta-comments.md) for `-AllowTypeOverride`.

## When something fails

A script that fails to deploy does not stop the ones after it. Each failure is
reported as it happens, listed again in a summary at the end, and the run exits
non-zero. Pass `-StopOnError` to abandon the run at the first failure instead.

| Exit code | Meaning |
| --- | --- |
| `0` | Everything the run set out to deploy succeeded |
| `1` | The run stopped early: bad arguments, sign-in, a failed pre-flight check, or `-StopOnError` tripping |
| `2` | The run finished, but one or more individual scripts failed |

Anything that stops the run is also written to stderr, so an unattended caller
watching only stderr still sees the reason. Some failures leave a script part-way
changed - created but unassigned, or updated against its old assignments. The
error message names the script's Intune id and, for updates, the backup file that
puts it back:

```powershell
./Deploy-IntuneScripts.ps1 -Restore backups/My-Script_20260728-221500.json
```

Checks that could half-apply a run are done as pre-flight instead: unresolvable
group names, duplicate local display names, and contradictory meta comments all
abort before anything reaches the tenant.

## Debug logging

`-DebugLog` takes `None` (default), `Console`, `File`, or `Both`. `File` and
`Both` write `logs/wizard-<timestamp>.log` under `-Path`. Enabling it prints
the build stamp (version plus git short hash, marked `-dirty` for uncommitted
changes) so a pasted log can be tied to an exact build. `logs/` is gitignored.

Any error that stops the run is written to the log in full - exception type,
the line that threw, and the call stack - while the console keeps the one-line
version. Logging is best-effort: if the log file cannot be created or later
becomes unwritable, the wizard warns once and carries on rather than taking the
deployment down with it.

---
[<- Back to README](../README.md) | [<- Setup](setup.md) | Next: [Technical notes](technical.md) ->
