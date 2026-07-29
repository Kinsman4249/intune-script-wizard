# E2E test kit

Offline regression coverage lives in [tests/](../tests) and runs against
stub Graph modules - no tenant needed. This folder is different: it
generates real `.ps1` files meant to be deployed by `Deploy-IntuneScripts.ps1`
against an actual **dev** tenant, so you can eyeball things the offline
tests can't check - real assignment targets, real group resolution, real
Intune display names.

`New-E2ETestSet.ps1` only writes files. It never calls Graph and never
deploys anything itself.

## Usage

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
- `groups.*` - display name and/or GUID for up to three test groups
  (`include`, `includeSecondary`, `exclude`). Tests that need a group you
  haven't filled in are skipped and listed in `CHECKLIST.md` instead of
  being generated with bad data.

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

## Cleaning up

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
