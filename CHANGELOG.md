# Change history

### Initial implementation (round one)

1. Built the core wizard: `Deploy-IntuneScripts.ps1` scans `user/` and
   `device/` subfolders (or loose scripts carrying a `#type:user|device`
   comment) for `.ps1` files and deploys each as an Intune
   `deviceManagementScript` via the Microsoft Graph beta
   `Microsoft.Graph.Beta.DeviceManagement` module. Scripts under `user/` get
   "Run this script using the logged on credentials" set to Yes; scripts
   under `device/` get No. This does not replace manual upload through the
   Intune portal, but automates the repetitive part of it for teams managing
   many platform scripts.
2. Added meta-comment parsing (`lib/Parsing.ps1`) for
   `#scriptname:"..."`, `#startdesc`/`#enddesc`, `#type:`, `#noassignments`
   (and the `#noassigments` typo, since that's an easy one to make and the
   cost of accepting it is near zero), `#scriptcheck:yes`, and `#host:64`.
   Comments are left in the uploaded script content unmodified, since they
   are valid PowerShell comments and have no effect on the endpoint. If a
   script sits outside both folders and has no `#type` comment, it's skipped
   with a warning rather than guessed at.
3. Added content-hash based duplicate detection (`lib/Matching.ps1`,
   `lib/GraphOps.ps1`): every local script's SHA256 is compared against a
   locally cached hash of every script already in the tenant, so re-running
   the tool doesn't re-upload unchanged scripts. Cache entries are keyed by
   the existing script's `lastModifiedDateTime`, so Graph's content download
   is skipped for scripts that haven't changed server-side since the last
   run.
4. Added Levenshtein-based fuzzy name/description matching for the case
   where a local script doesn't exactly match an existing one by name or
   content, but looks similar. In that case, and in the case where identical
   content already exists under a different name, the user is prompted
   per-script to skip, replace the existing script, or deploy side-by-side.
   `-OnFuzzyMatch` accepts the same three choices for non-interactive runs.
5. Added backup-before-mutate: any time an existing script is updated or
   replaced, its full current state (content, display name, description,
   run-as/signature/bitness settings, and assignments) is written to
   `backups/` as JSON before the change is made, since updating in place is
   destructive to the previous version. `-Restore <backup file>` pushes a
   backup back onto the original script (or recreates it, with a new Id, if
   the original was deleted since the backup was taken) in one command.
   `-ListBackups` lists what's available.
6. Assignment defaults to "All users" or "All devices" (matching the
   script's type) unless `#noassignments` is present, in which case any
   existing assignments are removed and none are added. This was chosen over
   requiring an explicit assignment comment on every script, since the
   common case for an MSP deploying platform scripts is "assign broadly by
   default, opt out per script when needed."
7. Defaulted `EnforceSignatureCheck` to off and `RunAs32Bit` to on (32-bit
   host), overridable per script with `#scriptcheck:yes` and `#host:64`
   respectively. This was a deliberate choice, not an oversight: enforcing
   script signatures requires a trusted code-signing setup this project does
   not assume its users have, so requiring it by default would break the
   common case rather than protect it.
8. Limited the Graph module dependency to `Microsoft.Graph.Authentication`
   and `Microsoft.Graph.Beta.DeviceManagement` only, installed to
   `-Scope CurrentUser` on request (`lib/Prereqs.ps1`), instead of the full
   `Microsoft.Graph` meta-module, which pulls in every Graph service and can
   be several GB. The user is prompted before any install happens unless
   `-AcceptModuleInstall` is passed.
9. Added `examples/user/Example-UserScript.ps1` and
   `examples/device/Example-DeviceScript.ps1` demonstrating every supported
   meta comment, since the syntax is project-specific and not something a
   reader would otherwise guess correctly from the README alone.
10. Filled in the repository document templates that shipped with the
    initial commit: project name and testing-instructions pointer in
    `CONTRIBUTING.md`, the repository URL in `CODE_OF_CONDUCT.md` and
    `SECURITY.md`, and a real `README.md` describing usage, meta comments,
    and duplicate/backup/restore behavior in place of the one-line
    placeholder.
11. Added a Business Source License 1.1 `LICENSE` file, since this project is
    BSL rather than a permissive or copyleft open-source license. The
    Change Date, Change License, and Additional Use Grant fields were filled
    in with reasonable defaults (four years out, converting to Apache 2.0,
    with an additional grant permitting MSP/client use but not resale as a
    competing product) and should be reviewed, since those are business
    decisions rather than technical ones.
12. Configured `.github/workflows/release.yml` for a script-only project:
    trimmed the build matrix to `ubuntu-latest` only, since the release
    artifact (a `tar.gz`/`zip` of the repository) is identical regardless of
    which OS produces it, and enabled the existing "no build, just bundle
    the repo" shell block rather than adding a new language section.
### v1.1.0 (2026-07-29)

1. Added `#group:"Name"` and `#group:<guid>` meta comments to assign scripts to specific Entra ID groups instead of all users/devices. Group display names are resolved against Entra ID (adding `GroupMember.Read.All` scope), and values parsing as GUIDs are used directly. Resolution runs as a pre-flight check before any script is created or updated.

2. Added `#excludegroup:"Name"` and `#excludegroup:<guid>` meta comments to exclude specific groups from script assignments. Can be used alone to mean "everyone except" or combined with `#group:` for targeted assignments.

3. Added `-DebugLog` parameter with values `None`, `Console`, `File`, or `Both` to trace Graph URLs, request bodies, and match scores. Console writes to the host, file writes to `-Path/logs/wizard-<timestamp>.log`.

4. Added duplicate detection for scripts sharing a display name. The wizard now fails fast with a clear error message rather than half-deploying and silently producing duplicates.

5. Added `lib/Backup.ps1` and `lib/Logging.ps1` modules to support backup-before-mutate and debug logging functionality.

### v1.2.0 (2026-07-29)

1. Added `#typeoverride:yes` meta comment to resolve conflicts between a script's `#type:user|device` comment and its folder placement. By default, folder placement wins (a script under `device/` is trusted to belong there). With `#typeoverride:yes`, the comment takes precedence.

2. Added `-AllowTypeOverride` parameter to `Deploy-IntuneScripts.ps1` to apply the override behavior to all scripts in a single run, without adding `#typeoverride:yes` to each one.

3. Added four new tests covering folder-vs-comment conflict resolution, `#typeoverride:yes` behavior, and `-AllowTypeOverride` flag handling.
