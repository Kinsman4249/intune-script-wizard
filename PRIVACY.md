# Privacy: crash-report telemetry

This tool can send an anonymous crash report if it hits a fatal error - but
only if you say yes. Nothing is ever sent unless you answer `y` at the
consent prompt the first time you run it.

**This telemetry endpoint is still in development.** A finalized privacy
policy covering retention, access, and deletion will be published once it's
complete. Until then, this document describes best-effort behavior, not a
contractual guarantee. If you're not comfortable with that, opt out - the
tool works identically either way, opted in or out.

## What's sent, if you opt in

Only on a fatal error, and only these fields:

- The tool's version and build stamp (e.g. `1.4.1+5571aff`)
- Your PowerShell version and OS platform
- A one-line error summary
- A multi-line error detail block (exception type, category, stack trace)

## What's stripped before anything leaves your machine

The error summary and detail are run through a scrubber
(`lib/Telemetry.ps1`, `Protect-WizardTelemetryPayload`) before they're added
to the report. It removes:

- Your Windows username, computer name, domain, and home folder path
- IPv4 and IPv6 addresses
- Windows user paths and UNC network shares
- Email addresses
- GUIDs (these show up constantly in Microsoft Graph error bodies as tenant
  and object IDs, which are effectively customer-identifying)
- Bearer tokens and JWTs
- Anything shaped like `password=...`, `client_secret=...`, `apikey=...`, or
  similar key/value secrets (the key is kept, the value is redacted)
- Any field longer than 2000 characters is truncated

This scrubbing happens locally, before the network call is made. The
receiving endpoint does not do its own PII detection - it trusts the
scrubbing above, so nothing sensitive is expected to reach it in the first
place.

## Where it goes

A Cloudflare Worker at `telemetry.ethanantonio.com`, operated by the
maintainer of this tool.

## How to opt out

- Answer `n` at the prompt, or
- Delete your saved answer to be asked again:
  `%APPDATA%\IntuneScriptWizard\telemetry-consent.json`

Declining, or never answering (e.g. unattended/scheduled runs), means
nothing is ever sent.
