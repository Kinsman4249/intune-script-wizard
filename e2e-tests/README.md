# E2E test kit

Offline regression coverage lives in [tests/](../tests) and runs against
stub Graph modules - no tenant needed. This folder is different: it
generates real `.ps1` files meant to be deployed by `Deploy-IntuneScripts.ps1`
against an actual **dev** tenant, covering what stubs cannot - real assignment
targets, real group resolution, real Intune display names, and content that has
genuinely round-tripped through Graph.

Two of the scripts here check themselves and exit non-zero on failure -
`Test-E2EDeployedSet.ps1` and `Test-E2EBackupRestore.ps1` - so most of what used
to be a manual comparison is now automated. `generated/CHECKLIST.md` is left
holding only the judgement calls a tenant cannot be asked about.

`New-E2ETestSet.ps1` only writes files. It never calls Graph and never
deploys anything itself.

## When to run what

Nothing here replaces [tests/](../tests). That suite is offline, takes seconds,
and needs no tenant - run it on every change, always. This folder costs a real
tenant and real minutes, so reach for it when the thing you changed is something
stubs cannot honestly stand in for.

| If you changed... | Run |
| --- | --- |
| Anything at all | The offline suite: `pwsh tests/Invoke-WizardTests.ps1` |
| Script content, encoding, or upload (`New-`/`Update-MgBetaDeviceManagementScript`, `-ScriptContentInputFile`, hashing) | `Test-E2EDeployedSet.ps1` - only a real tenant round-trip proves the bytes survived |
| Backup or restore (`lib/Backup.ps1`, the backup schema, `-Restore`/`-RestoreAll`) | `Test-E2EBackupRestore.ps1` |
| Template export, repo push, or `-SourceRepo` - regression coverage, throwaway scripts | `Test-E2ERepoBackupRestore.ps1` |
| Template export, repo push, or `-SourceRepo` - a real rehearsal against the tenant's actual scripts, e.g. before telling anyone this is production-ready | `Test-E2ETenantWideRepoBackupRestore.ps1` |
| Assignments, group resolution, `#group:`/`#excludegroup:`/`#noassignments` | Deploy `generated/main` + `Test-E2EDeployedSet.ps1` (real group ids, real targets) |
| Meta-comment parsing, `#type:`/`#typeoverride:`, folder precedence | The full generate/deploy/verify cycle below |
| Graph scopes, sign-in, consent | The full cycle - scope failures only surface against a real tenant |
| Retry/throttling behaviour (`Invoke-WizardGraphRetry`) | Offline suite covers the logic; a real tenant only proves it against real `429`s, which cannot be provoked on demand |
| Nothing tenant-facing (docs, logging, telemetry, error text) | Offline suite only |

**Before every release**, run the full cycle once. The two self-checking scripts
exit non-zero on failure, so they can also be wired into a pipeline pointed at a
dev tenant.

## The full cycle

```
# 0. Offline first - never spend a tenant run on something this would have caught
pwsh tests/Invoke-WizardTests.ps1

# 1. Generate (first run creates e2e-metadata.json and stops - fill it in)
pwsh e2e-tests/New-E2ETestSet.ps1

# 2. Deploy each root
pwsh Deploy-IntuneScripts.ps1 -Path e2e-tests/generated/main
pwsh Deploy-IntuneScripts.ps1 -Path e2e-tests/generated/allow-override -AllowTypeOverride
pwsh Deploy-IntuneScripts.ps1 -Path e2e-tests/generated/expect-failure -DryRun   # must abort

# 3. Verify what landed, per deployed root
pwsh e2e-tests/Test-E2EDeployedSet.ps1 -Path e2e-tests/generated/main
pwsh e2e-tests/Test-E2EDeployedSet.ps1 -Path e2e-tests/generated/allow-override -AllowTypeOverride

# 4. Verify backups can actually be restored (independent of the generated set)
pwsh e2e-tests/Test-E2EBackupRestore.ps1

# 5. Work through generated/CHECKLIST.md for what only a human can judge

# 6. Clean up
pwsh e2e-tests/Remove-E2ETestSet.ps1 -Confirm
```

Step 3 has nothing to check for `expect-failure` - those runs deploy nothing by
design, and "the wizard threw before creating anything" is the result.

Step 4 stands alone: it builds and tears down its own throwaway script, so you
can run it by itself in about a minute without generating or deploying the set.
That makes it the one to reach for while iterating on backup/restore code. It
does still read `e2e-metadata.json` for the `confirmDevTenant` gate and the run
prefix, so on a fresh clone run step 1 once first to create that file.

## Generating the set (steps 1-2)

```
pwsh e2e-tests/New-E2ETestSet.ps1
```

First run: creates `e2e-tests/e2e-metadata.json` from the template and
stops. Edit that file:

- `answers.confirmDevTenant` - set to `true` once you've confirmed the
  `-Path` you'll point `Deploy-IntuneScripts.ps1` at is your dev tenant's
  script folder. The generator refuses to run until this is `true`.
- `answers.runPrefix` - stamped on every generated script's Intune display
  name, and what `Remove-E2ETestSet.ps1` matches on to clean up afterwards.
  Defaults to `ZZZ-E2E-TEST-DELETE-ME` deliberately - loud, and the `ZZZ-`
  sorts it to the bottom of an alphabetical list - so any script left behind
  by a skipped or failed cleanup is obvious at a glance. Bump it to start a
  fresh, non-colliding batch (clean up the old prefix's batch first).
- `groups.*` - display name and/or GUID for up to four test groups
  (`include`, `includeSecondary`, `exclude`, `sameGroupBothForms`). Tests
  that need a group you haven't filled in are skipped and listed in
  `CHECKLIST.md` instead of being generated with bad data. For `include` and
  `exclude`, the display name and the GUID are separate tests rather than
  two ways of saying the same thing - a group referenced by GUID skips the
  directory lookup entirely - so filling in both fields runs both sets,
  whether the two fields name one group or two unrelated ones.
  `sameGroupBothForms` is the exception: its two fields must be a single
  group written both ways, because the one test that reads them checks that
  a name and a GUID landing on the same group is caught after resolution.

Re-run the generator once the metadata file is filled in. It writes three
folders under `e2e-tests/generated/` (each its own `-Path` root) plus a
`CHECKLIST.md`:

```
generated/main/            pwsh Deploy-IntuneScripts.ps1 -Path generated/main
generated/allow-override/  pwsh Deploy-IntuneScripts.ps1 -Path generated/allow-override -AllowTypeOverride
generated/expect-failure/  pwsh Deploy-IntuneScripts.ps1 -Path generated/expect-failure -DryRun
```

`expect-failure` should always abort with an exception before creating
anything - that's the point of those scripts.

Every generated script's Intune display name describes the test it is, and
its body just `Write-Host`s the same description - that's what you'll see
in the script's run output on a real device/user once assigned.

Work through `generated/CHECKLIST.md` against the Intune portal (and, if
you assign a script to a test device/user, its actual console output) to
confirm each row's "Expect" column.

Re-running the generator wipes and rebuilds `generated/` from scratch
(pass `-NoClean` to add/update files in place instead).

## Verifying a deployed set (step 3)

**When:** straight after deploying a root, and any time you touch script
content, encoding, upload, settings or assignments. Everything the tenant can
simply be *asked* is checked here; `generated/CHECKLIST.md` is left holding only
what a human has to judge.

```
pwsh e2e-tests/Test-E2EDeployedSet.ps1 -Path e2e-tests/generated/main
```

Point `-Path` at a root you have already deployed - it verifies what is in the
tenant against what is on disk, and does not deploy anything itself. It
re-parses the same local scripts
the wizard did, reads each one back out of Intune, and checks:

- the script exists under its expected display name
- the uploaded content is **byte identical** to the local file - SHA256 of the
  local bytes against SHA256 of the bytes Graph returns. This catches
  encoding-level damage no eyeball will: a BOM added or stripped, CRLF flipped
  to LF, a lost trailing newline, or content mangled by wrong base64 handling
- `runAsAccount` matches the `user/`/`device/` folder (or `#type:`)
- `enforceSignatureCheck` matches `#scriptcheck:`
- `runAs32Bit` matches `#host:`
- `fileName` and the description match what was parsed locally
- the assignment set matches `#group:`/`#excludegroup:`/`#noassignments`
  exactly, target for target, with nothing left over from an earlier run

It's read-only, so it's safe to re-run at any point. Add `-AllowTypeOverride` if
the deploy being verified used that flag. Exit code is `0` when everything
matched, `1` otherwise.

## Backup/restore check (step 4)

**When:** any change to `lib/Backup.ps1`, the backup schema, `-Restore`/
`-RestoreAll`, or how script content is read back out of Graph - and once before
every release. It needs no generated set and takes about a minute, so it is
cheap enough to re-run on each iteration while working on that code.

`New-E2ETestSet.ps1` only ever creates new scripts, so nothing in the generated
set exercises the update -> backup -> restore path. That path is the one where a
broken backup stays invisible: the wizard reports a successful update, writes a
file to `backups/`, and only a restore attempt - usually mid-incident - reveals
whether that file was ever usable.

```
pwsh e2e-tests/Test-E2EBackupRestore.ps1
```

This one *does* talk to Graph, and it checks itself rather than handing you a
checklist. Against the tenant it deploys a throwaway `#noassignments` script,
updates it (forcing a backup), inspects the backup file on disk, restores it,
and confirms the tenant really holds the original content again:

- the backup stores `ScriptContent` as base64 **text**, not a JSON array of
  numbers - the specific failure mode when the SDK's `byte[]` is written
  through unconverted, which still looks like a successful backup but cannot
  be restored
- that content decodes back to the original script byte for byte
- the restore reinstates it in the tenant, and the used backup is filed under
  `backups/backup-restored/`

It creates one script named `<runPrefix> Backup-Restore` and deletes it again on
the way out, even if an assertion failed. Pass `-KeepArtifacts` to leave the
script and scratch folder behind for inspection. You're asked to confirm the
tenant once, up front; the wizard runs it drives are non-interactive.

Exit code is `0` when every check passed, `1` otherwise, so it can be wired into
a pipeline against a dev tenant.

## Repo backup/restore check

**When:** any change to `lib/Template.ps1`'s .ps1 export, `lib/RepoBackup.ps1`'s
push, or `lib/RepoSource.ps1`'s `-SourceRepo` pull - and once before every
release if you use the repo-push feature at all. Needs a real remote repo
(GitHub or Azure DevOps) in addition to a dev tenant, and takes a couple of
minutes.

```
pwsh e2e-tests/Test-E2ERepoBackupRestore.ps1
```

This is the repo-facing sibling of the backup/restore check above, and
covers what that one does not: the .ps1 template export (not the JSON
backup), pushing it to a remote git repo, and pulling it back with
`-SourceRepo` instead of `-Restore`. Against the tenant and the remote it:

- deploys two throwaway `#noassignments` scripts (one `user/`, one
  `device/`), each with its own directives and hand-written comments
- makes sure a Templates repo push is configured, walking through the real
  first-run prompt itself if it isn't yet (answer `y`, paste the repo URL,
  complete whichever auth prompt follows - this only happens once; later
  runs reuse the saved config)
- backs up each script by name, which exports a regenerated template and
  pushes `templates/` to the remote
- clones that remote independently and checks the pushed files are
  byte-identical to what's on disk, **before** touching the tenant - a
  broken push aborts here with both scripts still in place
- deletes both scripts from the tenant
- restores them with `-SourceRepo` pointed at the same remote, into an
  otherwise-empty `-Path` so nothing local can paper over a broken pull
- checks the restored tenant content carries the wizard's regenerated
  template header, that `EnforceSignatureCheck`/`RunAs32Bit` match what the
  original directives asked for, and that the script logic matches before
  and after once comments and blank lines are stripped from both sides

Restored tenant content is also written to
`generated-repo-backup-restore/restored-tenant-content/` so the header
insertion can be read by eye, not just asserted. Pass `-KeepArtifacts` to
leave the tenant scripts and scratch folder behind for inspection - the
remote repo itself is never cleaned up by this script either way; each run
adds one more commit to it.

Exit code is `0` when every check passed, `1` otherwise.

## Tenant-wide repo backup/restore check

**When:** you want to prove the repo backup/restore path works against real,
arbitrary tenant content, not scripts this kit made up for the occasion - e.g.
before telling someone this is safe to rely on. Unlike everything else in this
folder, it does not create its own throwaway scripts: it operates on every
script already in the tenant.

```
pwsh e2e-tests/Test-E2ETenantWideRepoBackupRestore.ps1
```

It backs up every script in the tenant (JSON + .ps1 template), pushes the
templates to the configured remote and independently verifies the push landed
- all before touching anything. Then it prints the full list of scripts about
to be deleted and requires typing an exact confirmation phrase (not `y`/`N`)
before deleting every one of them and restoring all of them back with
`-SourceRepo`. Each restored script is compared against its pre-delete JSON
backup: content logic (comments and blank lines stripped from both sides),
`EnforceSignatureCheck`/`RunAs32Bit`/`RunAsAccount`, and assignments. A script
whose only assignment was "all devices" or "all licensed users" is reported as
a known limitation rather than a failure - `#group:`/`#excludegroup:` cannot
express either one, so a repo-based restore cannot bring it back; that gap
exists in the tool, not in this check.

Pass `-StopBeforeDelete` to run only the backup/push/verify steps and stop -
useful for rehearsing safely before committing to the real delete.

Unlike the rest of this kit, this script does **not** clean anything up
afterward: the restored scripts are meant to be the real end state, not
artifacts to tear down, and the workspace (`tenant-wide-repo-backup-restore/`
next to this script by default) is left in place because it holds the only
local copy of the pre-delete JSON backups. It writes `report.md` in that same
folder - a markdown table of every script and its result, meant to be handed
to someone who wasn't in the room.

Exit code is `0` when every check passed (or when `-StopBeforeDelete` stopped
cleanly, or the delete confirmation was declined), `1` otherwise.

## Cleaning up (step 6)

**When:** at the end of every cycle, and before starting a new one - a leftover
batch from a previous run is what turns a fresh deploy into a pile of fuzzy-match
prompts. Always dry-run first.

```
pwsh e2e-tests/Remove-E2ETestSet.ps1              # dry run - lists matches, deletes nothing
pwsh e2e-tests/Remove-E2ETestSet.ps1 -Confirm      # actually deletes them
```

Every script the E2E kit deploys is a brand-new object in Intune, so there's
nothing to "restore" - undoing the create is the exact revert, and that
means delete. `Remove-E2ETestSet.ps1` finds every script whose display name
starts with `answers.runPrefix` and, with `-Confirm`, deletes it.

One case is deliberately NOT auto-deleted: if a test's display name happened
to collide with a script that already existed before you ran the E2E kit,
`Deploy-IntuneScripts.ps1` would have *updated* it instead of creating it -
and backed up its prior state to that root's `backups/` folder first. Since
deleting that script now would destroy the pre-existing original with no way
back except that backup, `Remove-E2ETestSet.ps1` finds any display name with
a matching backup and skips it, printing a `[SKIP - has a backup ...]` line
instead. Restore it with `Deploy-IntuneScripts.ps1 -Restore <backup file>`
first, or pass `-IncludeFlagged` if you're sure it's safe to delete anyway.

This is also the fastest way to reset the tenant between runs while you're
iterating on something else - e.g. testing the wizard's own `-Restore`
behavior - without waiting on a full generate/deploy/verify cycle.
