# Change history

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
