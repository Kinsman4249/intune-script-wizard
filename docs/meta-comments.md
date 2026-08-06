# Meta comments

[<- Back to README](../README.md)

Add these as plain `#` comments anywhere in a script. They're left in the
uploaded script content - they're valid PowerShell comments and have no
effect on the endpoint.

| Comment | Effect |
| --- | --- |
| `#scriptname:"Override Name"` | Display name in Intune (default: filename minus `.ps1`) |
| `#startdesc` ... `#enddesc` | Lines between these become the description (default: blank) |
| `#type:user` or `#type:device` | Required only for scripts not under a `user/`/`device/` folder |
| `#typeoverride:yes` | Let this script's `#type:` win over the `user/`/`device/` folder it sits in |
| `#noassignments` (or `#noassigments`) | Do not assign this script to anyone |
| `#group:"Name"` or `#group:<guid>` | Assign to this group instead of all users/devices. Repeatable |
| `#assignall` | With `#group:`, also assign to all users/devices (on top of the named group(s)) instead of replacing the default |
| `#assigndevices` | Also assign to all devices, independent of this script's own `#type:` (a script can target both defaults at once) |
| `#assignusers` | Also assign to all licensed users, independent of this script's own `#type:` |
| `#excludegroup:"Name"` or `#excludegroup:<guid>` | Exclude this group from the assignment. Repeatable |
| `#scriptcheck:yes` | Enforce script signature check (default: off) |
| `#host:64` | Run under 64-bit PowerShell host (default: 32-bit) |
| `#notemplate` | Exclude this script from `-Backup`/`-BackupAll`'s `.ps1` template export only - it still gets backed up and deployed normally. Lives in the script body, so it travels into the tenant with the script and is honoured on every future export |

See [examples/user/Example-UserScript.ps1](../examples/user/Example-UserScript.ps1)
and [examples/device/Example-DeviceScript.ps1](../examples/device/Example-DeviceScript.ps1).

If a script sits under `user/` or `device/` and *also* carries a conflicting
`#type:`, the folder wins - a script's location is the more visible of the two,
so it's the one that decides. Add `#typeoverride:yes` to that script to let its
`#type:` win instead, or pass `-AllowTypeOverride` to grant that for every
script in the run.

## Targeting specific groups

By default a script goes to **all users** (`user/`) or **all devices**
(`device/`). `#group:` overrides that; `#excludegroup:` carves groups back out.

```powershell
# Just this group:
#group:"Helpdesk Laptops"

# Several groups, mixing display names and object GUIDs:
#group:"Helpdesk Laptops"
#group:6f9a1c22-6b7e-4a11-9f3d-2c8e5b7a1d40

# Everyone except the pilot ring - no #group:, so the default include stays:
#excludegroup:"Pilot Ring"

# A group, minus a subset of it:
#group:"All Laptops"
#excludegroup:"Pilot Ring"

# A specific group AND the default all-devices/all-users target, both:
#group:"Pilot Ring"
#assignall

# A device script (#type:device) ALSO assigned to all licensed users - the
# two defaults are independent of #type:, so either can be added regardless
# of which host the script runs under:
#assignusers
```

Notes:

- A value that parses as a GUID is used as-is. Anything else is treated as a
  display name and resolved against Entra ID, which needs the
  `GroupMember.Read.All` scope. That scope is **only** requested when at least
  one script actually names a group, so a GUID-only setup never asks for a
  directory read at all.
- Resolution happens as a pre-flight over every script, before anything is
  created or updated. A name that matches no group, or more than one, aborts
  the whole run rather than leaving it half applied. Duplicate group names are
  legal in Entra ID, so the tool refuses to guess - use the GUID instead.
- Assignments are a full replacement, so adding `#group:` to a script that was
  previously assigned to all devices moves it; it doesn't stack.
- `#noassignments` combined with `#group:`/`#excludegroup:`/`#assignall`/
  `#assigndevices`/`#assignusers`, or the same group listed as both include
  and exclude, is rejected at parse time.
- `-DryRun` prints the resolved target for each script, so you can confirm the
  intent before anything changes. See [Dry runs and plans](dry-run-and-plans.md).

---
[<- Back to README](../README.md) | Next: [Backups, restore and templates](backups-and-restore.md) ->
