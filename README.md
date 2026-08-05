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
| `#typeoverride:yes` | Let this script's `#type:` win over the `user/`/`device/` folder it sits in |
| `#noassignments` (or `#noassigments`) | Do not assign this script to anyone |
| `#group:"Name"` or `#group:<guid>` | Assign to this group instead of all users/devices. Repeatable |
| `#excludegroup:"Name"` or `#excludegroup:<guid>` | Exclude this group from the assignment. Repeatable |
| `#scriptcheck:yes` | Enforce script signature check (default: off) |
| `#host:64` | Run under 64-bit PowerShell host (default: 32-bit) |
| `#notemplate` | Exclude this script from `-Backup`/`-BackupAll`'s `.ps1` template export only - it still gets backed up and deployed normally. Lives in the script body, so it travels into the tenant with the script and is honoured on every future export |

See [examples/user/Example-UserScript.ps1](examples/user/Example-UserScript.ps1)
and [examples/device/Example-DeviceScript.ps1](examples/device/Example-DeviceScript.ps1).

If a script sits under `user/` or `device/` and *also* carries a conflicting
`#type:`, the folder wins - a script's location is the more visible of the two,
so it's the one that decides. Add `#typeoverride:yes` to that script to let its
`#type:` win instead, or pass `-AllowTypeOverride` to grant that for every
script in the run.

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
  one script actually names a group, so a GUID-only setup never asks for a
  directory read at all.
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
  first), or **[C]reate** it side-by-side. Pass `-OnFuzzyMatch Skip|Replace|SideBySide`
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

Backups live in `backups/` under `-Path`. Any run that updated something prints
that folder at the end, so you don't have to remember where it is. List them
with `./Deploy-IntuneScripts.ps1 -ListBackups`.

A restored backup is moved into `backups/backup-restored/` afterwards, so what's
left in `backups/` is only what you haven't used yet.

To roll back a whole run rather than one script, point `-Restore` at the folder
and add `-RestoreAll`:

```powershell
./Deploy-IntuneScripts.ps1 -Restore ./backups -RestoreAll
```

That restores every `*.json` directly inside the folder (not recursive, and
already-restored ones under `backup-restored/` are skipped). Each is restored
independently, so one failure doesn't stop the rest - the summary at the end
lists what did and didn't make it, and the run exits `2` if any failed.

Where the folder holds **more than one backup of the same script** - normal
after a few runs - only the **oldest** is restored, because that is the one
that undoes everything the folder recorded. The others are named in a warning
and left on disk, still restorable one at a time with `-Restore` if a later
revision is the state you actually want. Files that aren't wizard backups are
skipped with a warning rather than counted as failures.

If the assign step can't succeed at all - groups named in the backup have been
deleted since, or you're restoring into a different tenant - add
`-SkipAssignments` to restore the script itself and leave its current
assignments alone:

```powershell
./Deploy-IntuneScripts.ps1 -Restore ./backups/Some-Script_20260728-193000.json -SkipAssignments
```

Role scope tags are handled without needing a switch: if the tenant rejects the
restore over a scope tag that no longer exists, it is retried once with the
built-in Default tag and warns, rather than failing the whole restore over
metadata nobody was trying to recover.

`-Restore` can't be combined with `-DryRun`: a restore has nothing to preview,
and running it anyway would change the tenant for someone who asked for no
changes.

### Backing up on demand

A backup is normally an automatic side effect of an update. `-Backup` and
`-BackupAll` take the same snapshot on demand, without scanning `-Path` or
deploying anything - useful before a change you're about to make by hand in
the portal, or just to get a point-in-time copy of everything:

```powershell
# One script, by display name or Id:
./Deploy-IntuneScripts.ps1 -Backup "Payroll Script"
./Deploy-IntuneScripts.ps1 -Backup 8f4c1a2b-....

# Every script currently in the tenant:
./Deploy-IntuneScripts.ps1 -BackupAll
```

Each writes into `-Path/backups`, same as an update-triggered backup, and
restores the same way with `-Restore`. `-Backup` matches a script Id directly,
or an exact display name - if more than one script shares that name, name the
Id instead of guessing which one you meant. Add `-DryRun` to list what would
be backed up without writing anything. `-Backup` and `-BackupAll` can't be
combined with each other or with `-Restore`.

Unless `-NoTemplates` is passed, each one also exports a `.ps1` template of
the script - see "Exporting templates" below.

### Exporting templates

`-Backup`/`-BackupAll` don't just snapshot JSON - they also regenerate a
deployable `.ps1` template of each script's *current tenant state*, written
to `-Path/templates/user/` or `-Path/templates/device/`. Where a JSON backup
in `backups/` is a restore point for *this* tenant, a template is meant to go
the other way: edit it, commit it to a git repo, and deploy that repo into
*another* tenant with `-SourceRepo` or `-Path`. That's the promote-between-
tenants workflow this feature exists for - see `-SourceRepo` above.

A template file is the script's current body with a header stamped on top,
regenerating every meta comment this tool understands from the tenant's live
settings: `#scriptname:`, `#type:`, a `#startdesc`/`#enddesc` block if there's
a description, `#scriptcheck:yes`/`#host:64` if either is non-default,
`#group:`/`#excludegroup:` for each assignment target (group ids are
reverse-resolved back to their display names - see below), and
`#noassignments` if the script currently has none. Re-exporting a script
whose template already exists updates the header in place and leaves
everything below it - the actual script body - untouched.

Group ids can't be resolved back to a name without the optional
`GroupMember.Read.All` scope (see "Signing in"); if it's declined, or a group
has since been deleted, the directive is still written using the bare GUID,
with a `# WARNING:` comment above it explaining why and a matching console
warning. The export is never blocked by this - worst case, a template just
carries a GUID that only makes sense in the tenant it came from.

Every export also stamps a doubled, deliberately inert
`##typeoverride:yes` (note the two `#`s) with a one-line comment above it
explaining what deleting the second `#` does. Regular exports never turn a
live `#typeoverride:yes` back on by themselves - if you move a template from
`device/` to `user/` on purpose to reclassify it, deleting that one `#` is
how you tell the wizard the folder is wrong on purpose, not the tool doing it
for you.

`role scope tag`s are **not** carried over as a directive - they're recorded
only in an informational comment, because a scope tag id doesn't denote the
same tag in another tenant, and Graph rejects a request naming one that
doesn't exist there.

A script carrying `#notemplate` is skipped by the export (it still gets a
normal JSON backup) - see the meta-comment table above. `-BackupAll` exports
a template for every other script in the tenant, whether or not you actually
intend to promote it anywhere; curating that down to what belongs in a repo
is a plain `git add` of the files you want, not something the wizard tries to
guess at.

A template deployed back into the *same* tenant it was exported from will
look like a real content change on the next run - the header text wasn't
there before - so expect one update, and the backup that comes with it,
the first time that happens.

### Pushing backups (and templates) to a remote repo

`-Path/backups` and `-Path/templates` are local-only by default (and both
gitignored in this repo) - lose the machine and you lose that history with
it. The first time a run actually writes a backup, the wizard offers, once,
to also push `backups/` to a remote git repo:

```
Also back up these backup files to a remote git repo? (y/N)
```

The first time a run exports a template, it separately offers the same for
`templates/`:

```
Also push exported templates to a remote git repo? (y/N)
```

Say no to either and it's remembered - you won't be asked again for that one
unless you delete its config file (see below). Backups and templates are two
independent prompts, config files, and git repos: declining one never
silences the other, and pushing the exported templates elsewhere doesn't
require pushing backups anywhere at all (or vice versa). Say yes and give it
a repo URL, and it picks an auth method based on what's installed:

- **GitHub, GitLab, or any plain git host**: uses `gh` (GitHub CLI) for a
  one-command interactive sign-in if it's installed, or falls back to asking
  for a personal access token. Either way, the token is handed straight to
  `git credential approve` and stored by whatever OS-native credential helper
  is already configured (Git Credential Manager if installed, else
  Keychain/Windows Credential Manager/libsecret) - the wizard never writes a
  token to a file of its own.
- **Azure DevOps** (a `dev.azure.com` or `*.visualstudio.com` URL): offers
  Microsoft's own [recommended
  alternative](https://learn.microsoft.com/azure/devops/integrate/get-started/authentication/entra)
  to a PAT - signing in with `az login` and fetching a short-lived Microsoft
  Entra token fresh on every push - when the Azure CLI (`az`) is installed,
  or a PAT the same way as plain git otherwise.

Once configured, every run that writes a new backup (or exports a template)
pushes automatically - no further prompting. A push failure is only ever a
warning: the local copy already happened and is what `-Restore` (or the next
promote) actually depends on, so nothing about the run itself is affected.

`backups/` and `templates/` become two unrelated git repos with disjoint
histories the moment each is first pushed, so pointing both at the same
remote branch means each push rejects the other's history. Setting up the
templates push warns and asks you to confirm if you give it the same URL
already configured for backups; say no there unless you really mean it.

The choice (provider + remote URL, never a secret) for backups lives in
`repo-backup-config.json`; the templates one lives in a second, independent
file, `repo-template-config.json` - both next to the wizard's other local
state: `%APPDATA%\IntuneScriptWizard\` on Windows, `~/.intune-script-wizard/`
elsewhere. Delete either file to be asked again for that one, or to switch it
to a different repo/provider.

A template's exported group display names (unlike a JSON backup, which is
never pushed anywhere by default either) are what's leaving the machine if
you configure this for `templates/` - a new class of data beyond the backup
history alone, worth knowing about before pointing it at a repo you don't
control.

## Sourcing scripts from a git repo

`-Path` isn't the only place scripts can come from. `-SourceRepo` pulls
`user/`/`device/` scripts straight from one or more git repos too, on top of
whatever `-Path` itself contains:

```powershell
./Deploy-IntuneScripts.ps1 -SourceRepo https://github.com/contoso/intune-scripts.git
```

Each entry is `<git-url>[#<ref>][::<subpath>]`:

```powershell
# A specific branch or tag instead of the repo's default:
-SourceRepo https://github.com/contoso/intune-scripts.git#release

# Only a subfolder within the repo, rather than its root:
-SourceRepo https://github.com/contoso/intune-scripts.git::platform/win11

# Both, and more than one repo (repeat the flag):
./Deploy-IntuneScripts.ps1 `
  -SourceRepo "https://github.com/contoso/intune-scripts.git#release::platform/win11" `
  -SourceRepo "https://github.com/contoso/intune-scripts-2.git"
```

Every repo is cloned fresh (a shallow `git clone --depth 1`) into
`-Path/.repo-sources` on every run - never an incremental fetch, so there's
never local clone state to reconcile - and needs `git` installed and on
PATH. Scripts found this way go through exactly the same parsing, duplicate
detection, and the same run-wide duplicate-display-name check as everything
under `-Path`, so a script sourced from a repo and one on local disk sharing
a display name still aborts the run before touching the tenant.

A repo built by pushing `-Path/templates` (see "Exporting templates" above)
is already laid out as `user/`/`device/` at its root, so it's directly
consumable here with no `::subpath` needed - `-SourceRepo
https://github.com/contoso/intune-templates.git` is enough.

## Reviewing and replaying a dry run

A `-DryRun` shows what would happen, but running it "for real" afterwards
recomputes everything from scratch - if the tenant changed in between, what
actually gets applied can quietly drift from what was reviewed.

`-SavePlan` fixes that by writing the dry run's exact decisions (including
which choice was made for every near-duplicate) to a file:

```powershell
./Deploy-IntuneScripts.ps1 -DryRun -SavePlan ./deploy-plan.json
```

`-ApplyPlan` then replays that file as the real deploy, with no re-prompting
and no fresh duplicate detection - every action was already decided when the
plan was saved:

```powershell
./Deploy-IntuneScripts.ps1 -ApplyPlan ./deploy-plan.json
```

Before applying anything, it recomputes a signature over the current local
scripts (content and every meta-comment setting) and the current tenant
(every existing script's id, content hash and name) and compares it against
the one captured when the plan was saved. If either side has changed at all
- a script edited locally, one deleted or renamed in the tenant, anything -
`-ApplyPlan` refuses outright rather than guessing:

```
-ApplyPlan refused: the local scripts and/or the tenant have changed since
this plan was saved, so replaying it would not be the plan that was
reviewed. Run -DryRun -SavePlan again to make a fresh one.
```

`-ApplyPlan` cannot be combined with `-DryRun`, `-SavePlan`, `-ReportCsv`,
`-Restore`/`-RestoreAll`, `-Backup`/`-BackupAll`, or `-OnFuzzyMatch` (every
duplicate-handling decision is already in the plan).

### A management-approval report

`-ReportCsv` (also only valid with `-DryRun`) writes the same decided
actions to a CSV - display name, type, action, assignment target, and the
existing script's id where relevant - for sign-off outside the console. It
opens straight into Excel, and can be used with or without `-SavePlan`:

```powershell
./Deploy-IntuneScripts.ps1 -DryRun -SavePlan ./deploy-plan.json -ReportCsv ./deploy-report.csv
```

## Prerequisites

- PowerShell 7+ (`pwsh`).
- An account with the `DeviceManagementConfiguration.ReadWrite.All` and
  `DeviceManagementScripts.ReadWrite.All` Graph scopes (e.g. Intune
  Administrator).

The script installs only the two modules it actually needs -
`Microsoft.Graph.Authentication` and `Microsoft.Graph.Beta.DeviceManagement` -
never the full `Microsoft.Graph` meta-module, which pulls in every Graph
service and is several GB. You'll be prompted before anything is installed
unless you pass `-AcceptModuleInstall`.

### Signing in

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
"Exporting templates"). Unlike the required scopes above, a tenant declining
it doesn't fail sign-in or the run at all; the export just falls back to bare
GUIDs for any group reference, with a warning per group affected.

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
| `-SourceRepo <url[#ref][::subpath]>` | Also pull scripts from a git repo (repeatable) |
| `-SavePlan <file>` | With `-DryRun`: save the exact plan to replay later |
| `-ApplyPlan <file>` | Replay a plan saved by `-SavePlan` as the real deploy |
| `-ReportCsv <file>` | With `-DryRun`: write the planned changes to a CSV |
| `-DebugLog None\|Console\|File\|Both` | Trace Graph URLs, bodies and match scores |

### When something fails

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

### Debug logging

`-DebugLog` takes `None` (default), `Console`, `File`, or `Both`. `File` and
`Both` write `logs/wizard-<timestamp>.log` under `-Path`. Enabling it prints
the build stamp (version plus git short hash, marked `-dirty` for uncommitted
changes) so a pasted log can be tied to an exact build. `logs/` is gitignored.

Any error that stops the run is written to the log in full - exception type,
the line that threw, and the call stack - while the console keeps the one-line
version. Logging is best-effort: if the log file cannot be created or later
becomes unwritable, the wizard warns once and carries on rather than taking the
deployment down with it.

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

## Throttling and transient failures

Every Graph call the wizard makes is retried when the tenant is throttling
(`429`) or reports itself unavailable (`503`) - five attempts, backing off 2s,
4s, 8s, 16s, and honouring the service's own `Retry-After` when it sends one
(capped at 120s so an unattended run can't sit blocked indefinitely). Each wait
is announced on the console, so a run that pauses says why.

Only those two statuses are retried, because both mean the request was turned
away **without being processed** - replaying it cannot create a second copy of
anything. A `504` is deliberately not retried: a gateway timeout means the
answer was lost, not the request, and re-sending a create after one is how a
tenant ends up with two scripts. Everything else (a `400`, a `403`) fails
immediately, since it would fail the same way however many times it was sent.

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
and `-Path` validation. It also covers the failure paths: a single failing
script not stopping the rest, `-StopOnError`, each exit code, a tenant that
withholds a requested scope, corrupt backup files being rejected before any
Graph call, and fatal errors reaching stderr.

It also covers `-SourceRepo` (cloning a real local git repo, subpath scanning,
and combining repo scripts with `-Path`'s own), and `-SavePlan`/`-ApplyPlan`
(a saved plan replaying cleanly against unchanged state, and `-ApplyPlan`
refusing outright once a local file or the tenant has drifted since the plan
was saved) and `-ReportCsv`.

It also covers the restore edge cases specifically: a throttled tenant being
waited out and then giving up, a transient failure not being mistaken for a
deleted script, backups predating the current schema, colliding backup file
names, `runAs32Bit` surviving a round trip, `-RestoreAll` picking the oldest
backup per script, and a dead role scope tag falling back to the default
instead of failing the restore.

The stub for `Get-MgBetaDeviceManagementScript` returns `scriptContent` as a
`byte[]`, the way the real SDK does rather than as the base64 text the service
sends - handing back a string instead let two separate `byte[]`-handling bugs
pass a green suite. The stubs can also be told to throttle a given number of
calls, reject a named role scope tag, or fail a read outright, which is how the
retry and restore paths are driven without a tenant. Retries are real waits, so
the suite sets `WIZARD_RETRY_BASE_SECONDS` to shrink the backoff base; nothing
in normal use sets it.

Against a real dev tenant, [e2e-tests/](e2e-tests) generates a set of scripts to
deploy, plus two self-checking runs that Graph stubs can't stand in for:

```powershell
# After deploying a generated root: is everything really in the tenant, intact?
pwsh e2e-tests/Test-E2EDeployedSet.ps1 -Path e2e-tests/generated/main

# Can a backup actually be restored?
pwsh e2e-tests/Test-E2EBackupRestore.ps1
```

The first re-reads every deployed script out of Intune and checks the uploaded
content is **byte identical** to the local file (SHA256 both sides, so a BOM,
a CRLF/LF flip or a lost trailing newline fails it), that run-as, signature
check, 32/64-bit, filename and description match the meta comments, and that the
assignment set matches target for target. It's read-only.

The second covers the update -> backup -> restore path nothing else exercises:
it deploys a throwaway script, updates it to force a backup, verifies the backup
file is well-formed base64 rather than a JSON array of numbers, restores it, and
confirms the tenant holds the original bytes again. It cleans up after itself.

Both exit non-zero if any check failed.

After any change, still confirm against a non-production tenant with `-DryRun`
first, then for real, checking in the Intune portal (Devices > Scripts) that
the display name, "run as", signature check, 32/64-bit setting, and assignment
match what you expected.

## Telemetry

Every fatal error is saved to a local file on your own machine (never sent
by itself). When a run hits one, it's usually asked about right there: send
this anonymous crash report (and any others already saved locally)? There's
no saved "always yes/no" answer - it asks fresh each time, though it backs
off from asking about the *same* recurring error too often. Unattended/
scheduled runs are never prompted and never send anything.

If you say yes, the tool's version, PowerShell/OS version, and a scrubbed
error summary/detail are sent to a Cloudflare Worker the maintainer runs.
Local usernames, hostnames, IPs, file paths, tenant/object GUIDs, and
anything token- or password-shaped are stripped out before the report is
even saved locally - see [PRIVACY.md](PRIVACY.md) for the exact list and how
to opt out.

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
2030-08-05, after which the work becomes available under Apache 2.0.
