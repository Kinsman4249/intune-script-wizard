# Telemetry

[<- Back to README](../README.md)

Every fatal error is saved to a local file on your own machine (never sent
by itself). When a run hits one, it's usually asked about right there: send
this anonymous crash report (and any others already saved locally)? There's
no saved "always yes/no" answer - it asks fresh each time, though it backs
off from asking about the *same* recurring error too often. Unattended/
scheduled runs are never prompted and never send anything.

If you say yes, the tool's version, PowerShell/OS version, and a scrubbed
error summary/detail are sent to a Cloudflare Worker the maintainer runs.
Local usernames, hostnames, IPs, file paths, tenant/object GUIDs, and
anything token- or password-shaped are stripped out before the report is
even saved locally - see [PRIVACY.md](../PRIVACY.md) for the exact list and how
to opt out.

---
[<- Back to README](../README.md) | [<- Testing](testing.md)
