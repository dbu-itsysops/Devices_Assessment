# Devices Assessment

Read-only extraction and reconciliation of every computer record across five
systems, so that "which of our device records are garbage?" can be answered from
evidence instead of assumption.

| System | Holds |
|---|---|
| Active Directory | Domain-joined computer objects |
| Microsoft Entra ID | Device identities (hybrid joined, Entra joined, registered) |
| Microsoft Intune | Managed devices, Autopilot registrations, BitLocker key escrow |
| Apple School Manager | Apple hardware owned by the institution (ADE) |
| Freshservice | Asset/CMDB records with business and financial attributes |

**Nothing here writes, disables, deletes, retires or releases anything.**
Remediation is deliberately out of scope until the data is understood — see
[decision-record.md](docs/decision-record.md), Decision 1.

---

## Quick start

```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
Copy-Item .\config\config.example.ps1 .\config\config.local.ps1
```

Fill in `config.local.ps1` (it is git-ignored), then:

```powershell
. .\config\config.local.ps1
.\src\Invoke-Assessment.ps1
```

That writes a dated snapshot to `C:\estate-audit\<yyyy-MM-dd>\`. Full
prerequisites, app registration and permissions are in [setup.md](docs/setup.md).

Run a single phase:

```powershell
.\src\Invoke-Assessment.ps1 -Phase Freshservice
```

Verify the shared normalization helpers — no credentials or network required:

```powershell
.\tests\Test-EstateAudit.ps1
```

---

## Repository layout

```
src/
  EstateAudit.psm1              shared helpers: snapshots, normalization, CSV + manifest
  EstateGraph.psm1              Graph certificate authentication
  01-Export-ADComputers.ps1     phase 1
  02-Export-EntraDevices.ps1    phase 2
  03-Export-IntuneDevices.ps1   phase 3 - managed devices, Autopilot, BitLocker
  04-Export-Freshservice.ps1    phase 4 - assets, asset types, all custom fields
  Invoke-Assessment.ps1         runs every phase into one snapshot
config/
  config.example.ps1            template; copy to config.local.ps1
tests/
  Test-EstateAudit.ps1          helper tests; no credentials or network needed
docs/
  decision-record.md            why the assessment is shaped this way
  setup.md                      prerequisites, permissions, credentials
  runbook.md                    running a cycle, validating it, troubleshooting
  data-dictionary.md            every emitted column and its source attribute
  join-model.md                 join keys and the Power Query merge
```

## Snapshot layout

```
C:\estate-audit\2026-07-31\
  01-ad-computers.csv           02-entra-devices.csv
  03-intune-devices.csv         04-autopilot.csv
  05-bitlocker-escrow.csv       06-freshservice-assets.csv
  06b-fs-asset-types.csv        06c-fs-type-fields-long.csv
  07-asm-devices.csv            (manual — Apple School Manager UI export)
  raw\                          complete untransformed source responses (.jsonl)
  _manifest.csv                 row and column counts per file
  _run.log                      timestamped transcript
```

Snapshots are immutable by convention: all transformation happens downstream in
Power Query, so a suspect number can always be traced to either the data or the
logic. They are also git-ignored — they contain hostnames, serials, usernames and
OU structure for the entire estate.

---

## Column naming

```
<Prefix>_<exactSourceAttributeName>     value as the source system returns it
<Prefix>_<name>_calc                    derived here, not a source field
```

`Entra_approximateLastSignInDateTime`, not `Entra_LastSignIn`. The alias saved
typing and cost traceability: with roughly 60 merged columns, a name that appears
in no vendor documentation has to be mentally translated before the Graph
reference, its caveats, or a support case makes sense. See
[decision-record.md](docs/decision-record.md), Decision 9, and
[data-dictionary.md](docs/data-dictionary.md) for the full listing.

Prefixes: `AD_`, `Entra_`, `Intune_`, `AP_` (Autopilot), `BL_` (BitLocker),
`FS_` (Freshservice assets), `FST_` (Freshservice asset types).

---

## Status

| Phase | System | Status |
|---|---|---|
| 1 | Active Directory | Script delivered |
| 2 | Entra ID | Script delivered |
| 3 | Intune, Autopilot, BitLocker | Script delivered |
| 4 | Freshservice | Script delivered |
| 5 | Apple School Manager | **Not automated** — UI export, see [decision-record.md](docs/decision-record.md) §8 |
| — | Power Query join | Documented in [join-model.md](docs/join-model.md), workbook not yet committed |

---

## Security notes

- Certificate authentication only for Graph. No client secret is stored anywhere,
  least of all in a shareable workbook — [decision-record.md](docs/decision-record.md), Decision 5.
- Graph permissions are least-privileged per endpoint. `BitlockerKey.ReadBasic.All`
  returns key *metadata*; recovery keys are never requested and could not be read
  with this permission if they were.
- Credentials come from environment variables. `config.local.ps1`, `*.pfx`, `*.key`
  and all extracted data are git-ignored.
