# Duplicate handling, backups, restore and templates

[<- Back to README](../README.md)

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

## Restoring a backup

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

## Backing up on demand

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

## Exporting templates

`-Backup`/`-BackupAll` don't just snapshot JSON - they also regenerate a
deployable `.ps1` template of each script's *current tenant state*, written
to `-Path/templates/user/` or `-Path/templates/device/`. Where a JSON backup
in `backups/` is a restore point for *this* tenant, a template is meant to go
the other way: edit it, commit it to a git repo, and deploy that repo into
*another* tenant with `-SourceRepo` or `-Path`. That's the promote-between-
tenants workflow this feature exists for - see [Sourcing scripts from a git
repo](sourcing.md).

A template file is the script's current body with a header stamped on top,
regenerating every meta comment this tool understands from the tenant's live
settings: `#scriptname:`, `#type:`, a `#startdesc`/`#enddesc` block if there's
a description, `#scriptcheck:yes`/`#host:64` if either is non-default,
`#group:`/`#excludegroup:` for each assignment target (group ids are
reverse-resolved back to their display names - see below), `#assignall` if
the tenant's assignments also include the default target matching this
script's own `#type:` alongside specific groups, `#assigndevices`/
`#assignusers` if the assignments *also* include the other default target
(a script can be assigned to both all-devices and all-licensed-users at
once, independent of `#type:`), and `#noassignments` if the script
currently has none. Re-exporting a script
whose template already exists updates the header in place and leaves
everything below it - the actual script body - untouched.

Group ids can't be resolved back to a name without the optional
`GroupMember.Read.All` scope (see [Setup: signing in](setup.md#signing-in));
if it's declined, or a group has since been deleted, the directive is still
written using the bare GUID, with a `# WARNING:` comment above it explaining
why and a matching console warning. The export is never blocked by this -
worst case, a template just carries a GUID that only makes sense in the
tenant it came from.

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
normal JSON backup) - see the [meta-comment table](meta-comments.md).
`-BackupAll` exports a template for every other script in the tenant, whether
or not you actually intend to promote it anywhere; curating that down to what
belongs in a repo is a plain `git add` of the files you want, not something
the wizard tries to guess at.

A template deployed back into the *same* tenant it was exported from will
look like a real content change on the next run - the header text wasn't
there before - so expect one update, and the backup that comes with it,
the first time that happens.

## Pushing backups (and templates) to a remote repo

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
a repo URL, and it picks an auth method based on what's installed.

The URL takes the same `<git-url>[#<ref>][::<subpath>]` form as `-SourceRepo`
(see [Sourcing scripts from a git repo](sourcing.md)) - a bare URL pushes to
the repo's root on its default branch:

```
https://github.com/you/backups.git
```

Add `::<subpath>` to confine the push to one folder of an existing repo
instead - useful when backups or templates share a repo with unrelated
content - and `#<ref>` to target a specific branch (created on first push if
it doesn't exist yet):

```
https://org@dev.azure.com/org/project/_git/repo#dev::Scripts/Intune
```

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
  or a PAT the same way as plain git otherwise. If `az login` reports success
  but pushes still fail to authenticate, see the [WAM/MSAL cache
  troubleshooting note](setup.md#az-login-failing-with-cant-find-token-from-msal-cache)
  in Setup.

Once configured, every run that writes a new backup (or exports a template)
pushes automatically - no further prompting. A push failure is only ever a
warning: the local copy already happened and is what `-Restore` (or the next
promote) actually depends on, so nothing about the run itself is affected.

`backups/` and `templates/` become two unrelated git repos with disjoint
histories the moment each is first pushed, so pointing both at the same
remote branch means each push rejects the other's history - unless each is
confined to its own `::subpath`, in which case they coexist fine. Setting up
the templates push warns and asks you to confirm if you give it the same
URL+branch already configured for backups with no such split; say no there
unless you really mean it.

The choice (provider + remote URL, never a secret) for backups lives in
`repo-backup-config.json`; the templates one lives in a second, independent
file, `repo-template-config.json` - both next to the wizard's other local
state: `%APPDATA%\IntuneScriptWizard\` on Windows, `~/.intune-script-wizard/`
elsewhere. Run `-ResetRepoConfig Backups`, `-ResetRepoConfig Templates`, or
`-ResetRepoConfig All` (also the default with no value) to delete the
matching file(s) - a declined ("Declined: true") or misconfigured target is
just as stuck as a first run until its file is gone, so this is the normal
way back in rather than finding and deleting the file by hand:

```powershell
./Deploy-IntuneScripts.ps1 -ResetRepoConfig Backups
```

The next `-Backup`/`-BackupAll` for that target offers the setup prompt
again.

A template's exported group display names (unlike a JSON backup, which is
never pushed anywhere by default either) are what's leaving the machine if
you configure this for `templates/` - a new class of data beyond the backup
history alone, worth knowing about before pointing it at a repo you don't
control.

---
[<- Back to README](../README.md) | [<- Meta comments](meta-comments.md) | Next: [Sourcing scripts from a git repo](sourcing.md) ->
