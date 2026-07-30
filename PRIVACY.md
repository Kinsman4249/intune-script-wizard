# Privacy: crash-report telemetry

This tool can send an anonymous crash report if it hits a fatal error - but
only if you say yes, and it asks fresh each time it wants to send one (there
is no saved "always yes/no" file). Nothing is sent unless you answer `y` at
that prompt.

This document covers what this tool itself does before anything is sent:
when it asks, what it collects, and how it scrubs the report locally. For
what happens to a report after it leaves your machine - retention, storage,
and deletion - see the endpoint's own policy, always up to date, at
[telemetry.ethanantonio.com/privacy](https://telemetry.ethanantonio.com/privacy).

## What always happens, regardless of consent

Every fatal error is saved to a local file on your own machine:

- `%APPDATA%\IntuneScriptWizard\telemetry-state.json` on Windows
- `~/.intune-script-wizard/telemetry-state.json` on other platforms

This never leaves your machine by itself. It exists so a crash isn't lost if
you decline (or aren't asked) to send it that time, and so a real bug
doesn't have to slip through the cracks just because it happened during an
unattended run.

## When you're asked

The first time the wizard hits a new, distinct kind of fatal error, it asks
right there: send this report (and any other reports already saved locally)
anonymously? If you keep hitting the *same* error repeatedly, you won't be
asked every single time - the wizard waits for it to recur a few times
first (5, then 10, then 15, and so on) before asking again, so a machine
stuck in a crash loop doesn't nag you on every run. A genuinely different
error is always asked about right away.

Unattended runs (scheduled tasks, CI) are never prompted and never send
anything - the crash is still saved locally, waiting for the next
interactive run to ask about it.

## What's sent, if you say yes

Everything currently saved locally and not yet sent, as one batch, each
report containing:

- The tool's version and build stamp (e.g. `1.4.1+5571aff`)
- Your PowerShell version and OS platform
- A one-line error summary
- A multi-line error detail block (exception type, category, stack trace)

## What's stripped before anything leaves your machine

The error summary and detail are run through a scrubber
(`lib/Telemetry.ps1`, `Protect-WizardTelemetryPayload`) before they're saved
locally at all - so even the on-disk file never holds the unscrubbed
version. It removes:

- Your Windows username, computer name, domain, and home folder path
- IPv4 and IPv6 addresses
- Windows user paths and UNC network shares
- Email addresses
- GUIDs (these show up constantly in Microsoft Graph error bodies as tenant
  and object IDs, which are effectively customer-identifying)
- Bearer tokens and JWTs
- Anything shaped like `password=...`, `client_secret=...`, `apikey=...`, or
  similar key/value secrets (the key is kept, the value is redacted)
- Long fields are cut to a length budget

This scrubbing happens locally, before the report is written to disk or
sent. The receiving endpoint does not do its own PII detection - it trusts
the scrubbing above, so nothing sensitive is expected to reach it in the
first place.

## Where it goes

A shared Cloudflare Worker at `telemetry.ethanantonio.com`, used by several
of the maintainer's tools. The request carries a fixed app-identifying
token, which is not a secret - it's a filter to keep bot traffic out, not an
access control on your data. See the
[endpoint's privacy policy](https://telemetry.ethanantonio.com/privacy) for
where reports are stored, how long they're kept, and who can see them.

## How to opt out

- Answer `n` at the prompt, every time it's asked - nothing is sent.
- Delete the local state file (path above) to clear anything saved and start
  fresh.

Declining, or never being asked (e.g. unattended/scheduled runs), means
nothing is ever sent. For removing a report already sent, see
[Data Deletion Requests](https://telemetry.ethanantonio.com/deletion-requests).
