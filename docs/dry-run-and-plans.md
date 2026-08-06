# Reviewing and replaying a dry run

[<- Back to README](../README.md)

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

## A management-approval report

`-ReportCsv` (also only valid with `-DryRun`) writes the same decided
actions to a CSV - display name, type, action, assignment target, and the
existing script's id where relevant - for sign-off outside the console. It
opens straight into Excel, and can be used with or without `-SavePlan`:

```powershell
./Deploy-IntuneScripts.ps1 -DryRun -SavePlan ./deploy-plan.json -ReportCsv ./deploy-report.csv
```

---
[<- Back to README](../README.md) | [<- Sourcing scripts from a git repo](sourcing.md) | Next: [Setup](setup.md) ->
