# Change history

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
