# Technical notes

[<- Back to README](../README.md)

## How assignments are set

Assignments are applied through the
[`assign` action](https://learn.microsoft.com/en-us/graph/api/intune-shared-devicemanagementscript-assign?view=graph-rest-beta)
(`POST /beta/deviceManagement/deviceManagementScripts/{id}/assign`), not with
per-assignment cmdlets. The beta module ships only
`Get-MgBetaDeviceManagementScriptAssignment`; there is no documented `New-` or
`Remove-` counterpart, because assignments on a `deviceManagementScript` are
not a writable collection. Being a single full replacement, the action also
avoids the window in which a script sits unassigned between a delete and a
re-add. The call goes through `Invoke-MgGraphRequest` with a relative URI, so
it follows the connected cloud (GCC High, DoD, 21Vianet) automatically.

## Throttling and transient failures

Every Graph call the wizard makes is retried when the tenant is throttling
(`429`) or reports itself unavailable (`503`) - five attempts, backing off 2s,
4s, 8s, 16s, and honouring the service's own `Retry-After` when it sends one
(capped at 120s so an unattended run can't sit blocked indefinitely). Each wait
is announced on the console, so a run that pauses says why.

Only those two statuses are retried, because both mean the request was turned
away **without being processed** - replaying it cannot create a second copy of
anything. A `504` is deliberately not retried: a gateway timeout means the
answer was lost, not the request, and re-sending a create after one is how a
tenant ends up with two scripts. Everything else (a `400`, a `403`) fails
immediately, since it would fail the same way however many times it was sent.

---
[<- Back to README](../README.md) | [<- Usage and flags](usage.md) | Next: [Testing](testing.md) ->
