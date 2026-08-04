# Change history

### v1.13.4 (2026-08-03)

Added the template export generator, `lib/Template.ps1` - the piece that turns a live Intune script back into a `.ps1` template carrying the wizard's own meta-comment directives (`#scriptname:`, `#type:`, `#group:`, etc), regenerated from the tenant's current state. `New-WizardTemplateHeader` builds the header text and guards both of the format's data-loss traps: a `"` in a display name (stripped, with a warning, since `#scriptname:"..."` can't round-trip it) and a description line reading exactly `enddesc`/`startdesc` (exported as plain comments instead of a `#startdesc`/`#enddesc` block, which would otherwise silently truncate). `Remove-WizardTemplateHeader` strips a header a previous export already wrote, byte-exact and bounded to the first ~200 lines, so re-exporting a deployed template never stacks a second header on top of the first. `Export-WizardScriptTemplate` reverse-resolves each assignment's group id to a display name (falling back to the bare GUID, with a warning, for a deleted group or one that itself has a GUID-shaped or quote-containing name), writes atomically via a temp-file-then-move, and never deletes a stale template for a script that has since gained `#notemplate` - that stays a warning naming the path. `Resolve-WizardTemplateConflict` prompts per file on a diff against what's already on disk (`[O]verwrite/[S]kip/[D]iff/[A]ll/[L]="skip the rest"`, `D` shelling out to `git diff --no-index` when available), skipping silently when the bytes already match so a repeated `-BackupAll` doesn't re-prompt on everything it already wrote. None of this is reachable yet - `Deploy-IntuneScripts.ps1` loads the file but nothing calls it - wiring it into `-Backup`/`-BackupAll` is a later release.

### v1.13.3 (2026-08-02)

Added foundation for template export: a reverse group lookup (`Resolve-WizardGroupDisplayName`) to turn a group's object id back into a display name during export, and optional scope handling so a tenant's consent policy can decline the template-export read permission (`GroupMember.Read.All`) without failing the whole sign-in - the wizard degrades to bare GUIDs instead. New `Connect-WizardGraph -OptionalScopes` parameter, requested but not required; `Test-WizardGroupScopeGranted` checks whether an optional scope was actually granted. Also extracted filename sanitization into a reusable `Get-WizardSafeFileName` helper in `lib/Storage.ps1` (used by the backup code, and will be used by template export). The template feature itself has not landed at the CLI yet; these are the internal pieces that stage 4 and beyond will wire together.

### v1.13.0 (2026-08-02)

Added `#notemplate` directive, the foundation for template mode. A script carrying `#notemplate` is still backed up to JSON in full; it is skipped only by the template exporter that will land in a later release. The tag lives in the script body, which is the only thing Intune stores, so it travels into the tenant with the script - once deployed, it needs no local state to stay in sync. Parsing is unified: `Get-ScriptMetadata` reads the directive locally before a deploy, and a future `Test-WizardTemplateExcluded` will read it from the body during export, both matching the same regex pattern so they cannot drift.

### v1.12.0 (2026-08-02)

Added `-SourceRepo <url>[#ref][::subpath]` (repeatable), so scripts can be pulled from one or more git repos instead of only local disk - the three items that were sitting in the README's Roadmap section. Each entry clones fresh (a shallow `git clone --depth 1`, never an incremental fetch, so there is no local clone state to reconcile) into `-Path/.repo-sources` on every run, optionally at a given branch/tag (`#ref`) and scanning only a subfolder of the clone (`::subpath`) rather than its root. Repo-sourced scripts go through exactly the same parsing and duplicate detection as `-Path`'s own, combined into one local script set before the run-wide duplicate-display-name check runs across all of them together - a script sourced from a repo and one on local disk sharing a display name still aborts the run before touching the tenant. New `lib/RepoSource.ps1`; entirely separate from `lib/RepoBackup.ps1`, which pushes backups *out* to a remote rather than pulling scripts *in* from one.

Added `-DryRun -SavePlan <file>`, which records every decided action from a dry run (create/update/skip, plus which choice was made for every near-duplicate) to a JSON file, and `-ApplyPlan <file>`, which replays it later as the real deploy with no re-prompting and no fresh duplicate detection. Before applying anything, `-ApplyPlan` recomputes a signature - a hash over every local script's content and meta-comment settings, plus every existing tenant script's id/content-hash/name - and compares it against the one captured when the plan was saved; any drift on either side and it refuses outright rather than silently recomputing (`-ApplyPlan refused: the local scripts and/or the tenant have changed since this plan was saved...`). This is what makes "run the dry run for real" a guarantee instead of a hope that nothing moved in between. New `lib/Plan.ps1`. `-ApplyPlan` cannot be combined with `-DryRun`, `-SavePlan`, `-ReportCsv`, `-Restore`/`-RestoreAll`, `-Backup`/`-BackupAll`, or `-OnFuzzyMatch`, since every duplicate-handling decision it would otherwise prompt for is already recorded in the plan.

Added `-ReportCsv <file>` (also only valid with `-DryRun`), which writes the same decided actions to a CSV - display name, type, action, assignment target, existing script id where relevant - for a management-approval report that opens straight into Excel, alongside the usual console summary. Usable with or without `-SavePlan` in the same run.

Fixed a bug caught by the new plan tests before it ever shipped: `$x = if (cond) { [List[object]]::new() } else { $null }` handed back `$null` even on the `List`-returning branch, because an *empty* collection produced as an if-expression's value gets enumerated onto the output pipeline - zero items in, so the assignment captures nothing rather than the (still-empty) list. Rewritten as a plain conditional assignment, which does not route through pipeline enumeration.

### v1.11.0 (2026-08-02)

Added optional repo backup: after any run that writes new files into `-Path/backups` (an update-triggered backup, or the standalone `-Backup`/`-BackupAll`), the wizard can now also push them to a remote git repo, so backup history survives a lost or wiped machine instead of living only on whatever disk happened to write it. The first time this ever fires it offers the choice once - say no and it's remembered for good (`Declined: true` in a new local `repo-backup-config.json`, next to the wizard's other local state); say yes and it picks up which auth to use based on what's installed: `gh` for a one-command interactive sign-in on GitHub, a personal access token for any other plain git host (GitLab included), or for Azure DevOps either a PAT or - Microsoft's own now-recommended alternative - a short-lived Microsoft Entra token minted fresh on every push via `az login`/`az account get-access-token`. No token this wizard ever sees is written to a file of its own: a PAT goes straight into `git credential approve`, landing in whatever OS-native credential helper is already configured (Git Credential Manager, Keychain, Windows Credential Manager, or libsecret), and an Entra token is never persisted at all. A push failure is only ever a warning - the local backup already happened and is what `-Restore` actually depends on - and retries on the next backup rather than failing the run.

Also added a URL-scrubbing pattern to the telemetry pipeline (`Protect-WizardTelemetryPayload` in `lib/Telemetry.ps1`), since an unhandled error surfacing a repo remote URL would otherwise leak an org/repo name the same way an unscrubbed email address would. Both `https://...` and `git@host:...` forms are redacted before anything is saved locally, ahead of the narrower patterns already in place, so a URL never ends up only partially redacted.

### v1.10.0 (2026-08-02)

Added standalone `-Backup <name|id>` and `-BackupAll`, so a backup no longer has to wait for an update to trigger one. Both connect to the tenant and snapshot into `-Path/backups` exactly as `Update-WizardScript` would - full content, settings, scope tags and assignments - without scanning `-Path` or pushing anything to Intune. `-Backup` takes a script's display name or its Id (Id if the name is ambiguous, which now fails loudly with the matching Ids named rather than guessing); `-BackupAll` backs up everything currently in the tenant in one run. `-DryRun` lists what would be backed up without writing anything, and both are refused alongside `-Restore` since backup and restore are separate operations, not modifiers of one another. Restoring one back is unchanged: same `-Restore <file>` as always.

This was the last piece of a backup/restore mode that had been sitting at "works automatically, but only as a side effect" - most of the underlying plumbing (`Backup-WizardScript`, the on-disk schema, `Restore-WizardBackup`) already existed and needed no changes; this just gives it a front door.

### v1.9.2 (2026-07-31)

Closed a coverage hole around exclusions given as a bare group GUID. `#group:<guid>` was tested; `#excludegroup:<guid>` was not, in either suite. The offline suite now covers a guid-only exclusion (passed to Graph verbatim, with the all-devices include still in place), a named include combined with a guid exclusion in one script, and the fact that a guid exclusion on its own does not pull in the `GroupMember.Read.All` scope - the guid the tests use is deliberately absent from the stub directory, so any attempt to look it up by name fails the run rather than passing quietly.

Also covered the clash check that only fires after group resolution: `#group:"Pilot Ring"` plus `#excludegroup:<that group's guid>` are two different strings, so the parse-time overlap check cannot see them, and until now nothing exercised the guard that catches them once Graph has resolved both. No behaviour changed - both paths already worked - but neither was defended against a future edit.

In the E2E kit, `groups.exclude.guid` no longer sits unused whenever `groups.exclude.displayName` is filled in. The display name previously won and the guid was ignored, so the generated set exercised the bare-guid exclusion only if the name was left blank. The two forms are separate tests now, not two ways of writing one, mirroring how the include role has always worked - `device/23-excludegroup-only.ps1` and `device/24-group-and-excludegroup.ps1` for the name, `device/23b-excludegroup-by-guid.ps1` and `device/24b-group-and-excludegroup-by-guid.ps1` for the guid. Filling in both fields runs all four, whether the two fields happen to name one group or two unrelated ones. `device/25-kitchen-sink.ps1` is about directives stacking up rather than reference forms, so it still takes whichever reference is available and is generated once.

A new `groups.sameGroupBothForms` metadata role covers the post-resolution clash against a real tenant, through `expect-failure/device/group-ref-name-guid-clash.ps1`. It is the one role whose two fields must be a single group written both ways, because that test includes the group by name and excludes it by guid - two different strings that only turn out to be one group after Graph has resolved them. It needed its own role precisely because the include and exclude roles carry no such promise. An existing `e2e-metadata.json` without the new role generates everything else and lists that one test as skipped.

### v1.9.1 (2026-07-31)

Added retry with backoff for a throttled or unavailable tenant. Every Graph call now goes through `Invoke-WizardGraphRetry`: five attempts, backing off 2s/4s/8s/16s, honouring the service's own `Retry-After` when it sends one and capping any single wait at 120s so an unattended run cannot sit blocked indefinitely. Each wait is announced on the console, so a run that pauses says why it paused. Previously a single `429` - likely on a large tenant, or during a `-RestoreAll` over a folder of backups - failed that call outright and, for a deploy, that script with it.

Only `429` (throttled) and `503` (service unavailable) are retried, because both mean the request was turned away **without** being processed, so replaying it cannot create a second copy of anything. `504` is deliberately excluded: a gateway timeout means the answer was lost rather than the request, and re-sending a create after one is how a tenant ends up with two scripts. Anything else fails immediately, as it would fail the same way however many times it was sent.

The offline stubs can now be told to throttle a given number of calls, so the retry path (waiting, succeeding, and giving up) is covered without a tenant. Retries are real waits, so the suite shrinks the backoff base through `WIZARD_RETRY_BASE_SECONDS`; nothing in normal use sets it.

### v1.9.0 (2026-07-31)

Fixed a set of edge cases where a backup could not be restored, or restored something other than what it recorded.

- **A transient Graph failure during a restore forked a duplicate script.** The "does this script still exist?" check swallowed every error, not just a 404, so a throttle (likely during `-RestoreAll`), an outage or an expired token read as "it was deleted": the restore recreated a script that was still live, moved the assignments onto the copy, and filed the backup away as used. Only a genuine not-found is treated as a deletion now; anything else stops the restore with the backup left untouched for a retry.
- **Backups taken before scope tags were captured (schema 1) could not be restored.** Those files have no `RoleScopeTagIds` key, and `@($null)` is a one-element array, so the "no scope tags, use the default" fallback never fired and Graph was sent an empty scope tag id, which it rejects. The oldest backups were exactly the ones that failed.
- **One backup could silently overwrite another.** Backup file names are the display name with every awkward character replaced by `_`, plus a timestamp good to the second, so `Payroll Script (v1)` and `Payroll Script [v1]` produced the same name in the same run and the second write replaced the first - leaving that script updated with nothing to roll it back to. Colliding names now get a numeric suffix.
- **Restoring silently changed `runAs32Bit`.** The backup read a `RunAs32BitOnWindows64` property the SDK does not have; PowerShell returns `$null` for a property that isn't there and `[bool]$null` is `$false`, so every backup recorded "64-bit host" regardless of the truth and restoring a 32-bit script moved it. The offline stubs exposed the same wrong name, which is why a green suite never showed it. Reading the property is now its own function that fails loudly if it is missing, rather than defaulting to `$false`.
- **`-RestoreAll` replayed a script's history in an arbitrary order.** A `backups/` folder normally holds several backups of the same script, and every one was restored in file-name order - so a script renamed between two backups ended on whichever *name* sorted later. Only the oldest backup per script is restored now (the one that undoes the whole folder); the rest are named in a warning and left on disk for `-Restore` to take one at a time.
- **A stray `.json` in `backups/` failed the run.** Files carrying none of a backup's identifying fields are skipped with a warning instead of counted as failures. A file that *is* a backup but is broken still fails loudly.
- **Restoring into a tenant that has lost the referenced groups or scope tags.** A rejected scope tag is retried once with the built-in Default tag and warned about, instead of failing the restore over metadata nobody was recovering. New `-SkipAssignments` restores the script and leaves its current assignments alone, for backups whose group targets no longer exist or that came from another tenant; the assignment-failure message points at it.
- Restoring a backup named as a bare file name in the current directory no longer warns about being unable to file it away afterwards.

Fixed the duplicate-script prompt reading "create" as "skip". The prompt ended `create [side-by-side]?` but only accepted an answer starting `si`, so typing the word it asked for fell through to the default and silently skipped the script. It now reads `[S]kip / [R]eplace existing / [C]reate side-by-side?` and accepts `c`/`create` as well as `si`/`side-by-side`. The mapping moved into `ConvertTo-WizardFuzzyChoice` so it is covered by tests, which the interactive prompt itself cannot be.

`e2e-tests/Test-E2EDeployedSet.ps1` checked `runAs32Bit` through the same wrong property name, so its bitness check was comparing against `$null` on every script; it now reads the real one.

### v1.8.5 (2026-07-31)

Fixed backups being written unrestorable. `Backup-WizardScript` wrote the SDK's `ScriptContent` straight into the backup file, but the SDK returns that as a `byte[]` rather than the base64 text the backup format expects, so the file stored a JSON array of numbers that failed to decode on the way back in - a backup that looked successful and only revealed itself at restore time. The same `byte[]` mishandling also silently disabled the orphaned-duplicate check during a recreate-restore. All three read sites (content hashing, backup, orphan check) now share one `Get-WizardScriptContentBytes` helper, which also recovers backups already written in the broken array form, so existing backup files restore without hand-repair.

The offline test stubs now model `scriptContent` as the `byte[]` the real SDK returns instead of a base64 string - the gap that let both of these bugs pass a green suite - plus a new assertion that a backup stores base64 text that decodes to the original script.

Added two self-checking E2E runs against a dev tenant, replacing checks that were previously eyeball-only:

- `e2e-tests/Test-E2EDeployedSet.ps1` verifies a deployed `-Path` root against the tenant: every script's uploaded content is compared **byte for byte** (SHA256 of the local bytes against the bytes Graph returns, so a BOM, a CRLF/LF flip or a lost trailing newline fails it), along with `runAsAccount`, `enforceSignatureCheck`, `runAs32Bit`, filename, description, and the full assignment set target for target. Read-only and re-runnable.
- `e2e-tests/Test-E2EBackupRestore.ps1` covers the update -> backup -> restore path the generated set never exercised: it deploys a throwaway script, updates it to force a backup, verifies the backup file's shape and contents, restores it, and confirms the tenant holds the original bytes again, cleaning up after itself.

Any run that updated something now prints the `backups/` folder and the restore command at the end, so the backups are findable without remembering where they land.

README: dropped a stale `TODO` line, documented `-RestoreAll`, `-AllowTypeOverride` and `#typeoverride:yes` (all previously undocumented), added a flag reference table and a "Signing in" section covering the fresh-sign-in and tenant-confirmation behaviour from v1.8.0.

### v1.8.4 (2026-07-31)

Fixed `Remove-E2ETestSet.ps1` failing to parse `e2e-metadata.json` with "Bad JSON escape sequence" when a hand-edited value (e.g. a `CONTOSO\GroupName` displayName) contained a literal backslash - the backslash auto-repair added in v1.7.2 only covered `New-E2ETestSet.ps1`, which reads the same file. The repair (`Repair-WizardJsonBackslashes`) is now shared from `lib/Storage.ps1` and applied by both scripts.

### v1.8.3 (2026-07-31)

Fixed `Get-WizardExistingScripts` warning "Could not hash existing script ... input is not a valid Base-64 string" for every script in a tenant. `Get-MgBetaDeviceManagementScript`'s `ScriptContent` property deserialises `scriptContent` straight to a `byte[]`, not the base64 string the wire format uses; passing that array to `[Convert]::FromBase64String` silently coerced it into a bogus space-separated string of numbers first. The existing-script hash now uses the bytes directly when the SDK already returned a `byte[]`, and only base64-decodes when it returned a string.

### v1.8.2 (2026-07-31)

Fixed sign-in requesting only `DeviceManagementConfiguration.ReadWrite.All`, which is not sufficient to read or write Intune device management scripts. `Connect-WizardGraph` now also requests `DeviceManagementScripts.ReadWrite.All`, so reading existing scripts no longer fails with a 403 asking for `DeviceManagementScripts.Read.All`/`ReadWrite.All`.

### v1.8.1 (2026-07-31)

Changed the missing-modules install prompt's default answer from no to yes: pressing Enter with no input now installs the two required Graph modules instead of declining. Typing `n`/`no` still declines.

### v1.8.0 (2026-07-31)

Hardened Graph sign-in against a wrong-tenant mistake. `Connect-WizardGraph` now disconnects any Microsoft Graph session already active in the process (e.g. one left over from an earlier `Connect-MgGraph` run by hand, or from a previous wizard run in the same shell) before signing in, so a session for one tenant can never be silently reused for another. Interactive runs are also asked to type back the connected account's domain before anything is created, updated, or restored - a mistaken tenant now has to be confirmed explicitly rather than clicked through. Unattended runs (scheduled tasks, CI) skip that prompt, since nobody is there to answer it, but still log the connected account/tenant. The wizard also now disconnects from Graph when it finishes, successfully or not, so no session is left open for an unrelated later run to inherit.

### v1.7.2 (2026-07-31)

Fixed `New-E2ETestSet.ps1` failing to parse `e2e-metadata.json` when a hand-edited value (e.g. a `CONTOSO\GroupName` displayName) contained a literal backslash, which is invalid JSON unless escaped. The script now repairs the raw file text before parsing, doubling any backslash that isn't already part of a valid JSON escape sequence, so these values no longer need to be escaped by hand. If the file is still not valid JSON after the repair pass, the resulting error now names the file and the parser's message instead of surfacing a bare `ConvertFrom-Json` exception.

### v1.7.1 (2026-07-29)

Clarified telemetry documentation in `CONTRIBUTING.md`, `PRIVACY.md`, and `lib/Telemetry.ps1`. Updated contributor guidelines to reflect opt-in crash reporting policy. Improved comments in `lib/Telemetry.ps1` to better explain the app token's role in bot-traffic filtering (not data protection) and how the telemetry endpoint validates requests. No functional changes.

### v1.7.0 (2026-07-29)

Bumped backup schema to v3: backup JSON files now include `ReplacedByDisplayName` and `ReplacedByContentHash` fields that record the display name and content hash of whatever script is about to replace the backed-up one. These fields are consumed during restore-recreate (when the original script ID no longer exists); `Remove-WizardOrphanReplacement` uses the fingerprint to spot a since-orphaned duplicate and prompts interactively before deletion (never auto-deletes unattended). Added `-RestoreAll` flag to `Deploy-IntuneScripts.ps1`: treats `-Restore` as a folder and restores every `*.json` backup directly under it in sequence; one failure does not stop processing the rest. All successful restores (single or batch) now move their backup file into a `backup-restored/` subfolder, so a restored backup cannot be confused for one still pending or restored a second time by accident. Updated and added test cases (schema v3, ReplacedBy fields, -RestoreAll happy path and usage errors, backup-restored/ move); all 90 tests passing.

### v1.6.0 (2026-07-29)

Redesigned telemetry consent flow for better user experience. Instead of asking once at the start of the first run and saving the answer, the wizard now asks at the moment of a crash (if interactive), so unattended runs never nag. To avoid pestering machines that keep hitting the same bug, crashes are grouped by signature (exception type + error ID + scrubbed summary), and a signature that was just asked about backs off: it waits 5 more occurrences before asking again, then 10, then 15, growing by 5 each time. A genuinely new error bypasses the backoff and is asked about immediately. Saying yes flushes all pending unsent reports (this crash and any others) as one batch, since a request costs the same whether it carries one event or fifty. The old persisted consent file (`telemetry-consent.json`) is no longer used; crash reports are now saved to `telemetry-state.json` (Windows: `%APPDATA%\IntuneScriptWizard\telemetry-state.json`; other platforms: `~/.intune-script-wizard/telemetry-state.json`), which tracks both pending reports and per-signature backoff counters. Updated `PRIVACY.md` and `README.md` to document the new flow and to point to the telemetry endpoint's own policy (served at `telemetry.ethanantonio.com/privacy`) for retention, storage, and deletion details.

### v1.5.0 (2026-07-29)

Added opt-in crash-report telemetry in `lib/Telemetry.ps1`. The first time you run the wizard interactively, it prompts a one-time y/n question: send an anonymous crash report if a fatal error occurs. The answer is saved to `%APPDATA%\IntuneScriptWizard\telemetry-consent.json` on Windows or `~/.intune-script-wizard/telemetry-consent.json` on other platforms, so you are not asked again. Unattended runs (scheduled tasks, CI) are never prompted and never send anything. If you opt in, a fatal error sends the tool version, PowerShell/OS version, and a scrubbed error summary/detail to a Cloudflare Worker operated by the maintainer. Local usernames, hostnames, IPs, file paths, tenant/object GUIDs, bearer tokens, JWTs, and anything shaped like a password or API key are stripped out before the report leaves your machine - see `PRIVACY.md` for the exact scrubbing rules. Network failures, timeouts, and endpoint unavailability do not affect the deployment outcome; telemetry is never allowed to fail a run. Consent preference saves are best-effort too, so if your profile is read-only, you remain opted-in for that run but are asked again next time. This feature does not change the wizard's functionality or exit codes; deployments behave identically whether telemetry is opted-in or declined.

### v1.4.1 (2026-07-28)

Added comprehensive code comments and documentation throughout `Deploy-IntuneScripts.ps1` and all library modules (`lib/*.ps1`). Comments explain algorithm choices (e.g., Levenshtein distance, atomic file writes), PowerShell idioms, error handling invariants, and the overall control flow. This improves code maintainability and onboarding for future contributors without changing any functional behavior.

### v1.0.0 (initial implementation)

1. Built the core wizard: `Deploy-IntuneScripts.ps1` scans `user/` and `device/` subfolders for `.ps1` files and deploys each via Microsoft Graph beta `Microsoft.Graph.Beta.DeviceManagement`. Scripts under `user/` run with logged-on credentials; scripts under `device/` run as system.

2. Added meta-comment parsing for `#scriptname:`, `#startdesc`/`#enddesc`, `#type:`, `#noassignments`, `#scriptcheck:yes`, and `#host:64`. Also supports the `#noassigments` typo since it's common and harmless.

3. Added SHA256-based duplicate detection: local scripts are compared against cached hashes of existing tenant scripts to avoid re-uploading unchanged files.

4. Added Levenshtein fuzzy matching for similar scripts. When a match is ambiguous, the user is prompted to skip, replace, or deploy side-by-side. Non-interactive runs accept `-OnFuzzyMatch`.

5. Added backup-before-mutate: updated or replaced scripts are backed up to `backups/` as JSON before changes are made. `-Restore <backup file>` restores or recreates the script. `-ListBackups` lists available backups.

6. Assignment defaults to "All users" or "All devices" (matching the script's type) unless `#noassignments` is present, which removes all assignments instead.

7. Defaulted `EnforceSignatureCheck` to off and `RunAs32Bit` to on (32-bit host). Overridable per script with `#scriptcheck:yes` and `#host:64`.

8. Minimized Graph module dependency to `Microsoft.Graph.Authentication` and `Microsoft.Graph.Beta.DeviceManagement`, installed to `-Scope CurrentUser` on request via `lib/Prereqs.ps1`.

9. Added example scripts in `examples/user/` and `examples/device/` demonstrating all supported meta comments.

10. Filled in repository templates: project name and testing instructions in `CONTRIBUTING.md`, repository URL in `CODE_OF_CONDUCT.md` and `SECURITY.md`, and real content in `README.md`.

11. Added Business Source License 1.1 `LICENSE` file with reasonable defaults for Change Date, Change License, and Additional Use Grant.

12. Configured `.github/workflows/release.yml` for script-only project with `ubuntu-latest` build matrix.
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

### v1.3.0 (2026-07-29)

Added offline e2e test kit in `e2e-tests/` for regression testing against a real dev tenant. The kit generates `.ps1` files that exercise real Intune assignment behavior (group resolution, display names, assignment targets). Run `New-E2ETestSet.ps1` to generate test scripts, then deploy them with `Deploy-IntuneScripts.ps1` against a dev tenant to validate changes visually.

### v1.4.0 (2026-07-28)

1. Added `lib/Errors.ps1` module to define standardized exit codes (0 for success, 1 for fatal failures, 2 for partial failures where some scripts failed) and to extract actionable error messages from Microsoft Graph API responses. Fatal errors now write full diagnostic detail (exception type, stack trace, inner exceptions) to the debug log for faster problem diagnosis.

2. Added `lib/Storage.ps1` module providing atomic JSON file writes: all data is written to a sibling temp file and moved into place as a single filesystem operation, ensuring that backups and the hash cache remain consistent even if the wizard is interrupted mid-write or the system runs out of disk space.

3. Added `-StopOnError` parameter to halt immediately on the first script failure instead of continuing through the remaining scripts. By default the wizard reports failures per-script and exits with code 2; with `-StopOnError` it exits code 1 on the first failure. Both modes now have explicit exit codes so scheduled tasks and CI pipelines can distinguish fatal problems from expected partial failures.

4. Enhanced backup validation in `lib/Backup.ps1`: backups are now checked for required fields before any restore attempt, scripts are validated to have non-empty content before being changed, backup filenames are sanitized to prevent filesystem issues, and all backup writes now use atomic storage to prevent corruption.

5. Improved library loading in `Deploy-IntuneScripts.ps1` with validation that all required library files exist before any execution begins, providing clear guidance if the wizard folder is incomplete or corrupted.

6. Updated help text to document exit codes and clarify behavior in non-interactive runs (pipelines, scheduled tasks) when fuzzy matching encounters ambiguity.
