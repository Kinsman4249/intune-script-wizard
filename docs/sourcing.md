# Sourcing scripts from a git repo

[<- Back to README](../README.md)

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
under `-Path` (see [Duplicate handling](backups-and-restore.md)), so a script
sourced from a repo and one on local disk sharing a display name still aborts
the run before touching the tenant.

A repo built by pushing `-Path/templates` (see [Exporting
templates](backups-and-restore.md#exporting-templates)) is already laid out
as `user/`/`device/` at its root, so it's directly consumable here with no
`::subpath` needed - `-SourceRepo
https://github.com/contoso/intune-templates.git` is enough.

---
[<- Back to README](../README.md) | [<- Backups, restore and templates](backups-and-restore.md) | Next: [Dry runs and plans](dry-run-and-plans.md) ->
