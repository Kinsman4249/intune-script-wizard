# Testing

[<- Back to README](../README.md)

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
was saved) and `-ReportCsv`. See [Sourcing](sourcing.md) and [Dry runs and
plans](dry-run-and-plans.md).

It also covers the restore edge cases specifically: a throttled tenant being
waited out and then giving up, a transient failure not being mistaken for a
deleted script, backups predating the current schema, colliding backup file
names, `runAs32Bit` surviving a round trip, `-RestoreAll` picking the oldest
backup per script, and a dead role scope tag falling back to the default
instead of failing the restore. See [Backups, restore and
templates](backups-and-restore.md).

The stub for `Get-MgBetaDeviceManagementScript` returns `scriptContent` as a
`byte[]`, the way the real SDK does rather than as the base64 text the service
sends - handing back a string instead let two separate `byte[]`-handling bugs
pass a green suite. The stubs can also be told to throttle a given number of
calls, reject a named role scope tag, or fail a read outright, which is how the
retry and restore paths are driven without a tenant. Retries are real waits, so
the suite sets `WIZARD_RETRY_BASE_SECONDS` to shrink the backoff base; nothing
in normal use sets it.

Against a real dev tenant, [e2e-tests/](../e2e-tests) generates a set of scripts
to deploy, plus several self-checking runs that Graph stubs can't stand in
for - covering real tenant round-trips, backup/restore, template export and
repo push/pull, up to a full disaster-recovery rehearsal against every script
in the tenant. See [e2e-tests/README.md](../e2e-tests/README.md) for what each
one does and when to run it.

---
[<- Back to README](../README.md) | [<- Technical notes](technical.md) | Next: [Telemetry](telemetry.md) ->
