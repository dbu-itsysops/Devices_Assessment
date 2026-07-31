# Runbook

Running an assessment cycle. One-time preparation is in [setup.md](setup.md).

---

## Run a full cycle

```powershell
cd <repo>
. .\config\config.local.ps1
.\src\Invoke-Assessment.ps1
```

Roughly 10–40 minutes, dominated by Freshservice. Output lands in
`C:\estate-audit\<yyyy-MM-dd>\`.

Phases continue after a failure by default — a missing RSAT module should not
cost you the Freshservice pull. Add `-StopOnError` to change that.

### Individual phases

```powershell
.\src\Invoke-Assessment.ps1 -Phase Freshservice
.\src\Invoke-Assessment.ps1 -Phase AD,Entra
```

Re-running a phase into an existing snapshot overwrites that phase's CSVs and
appends a second row to `_manifest.csv`. Both rows are kept on purpose — the
manifest is a log of what happened, not a summary of what is current.

```powershell
.\src\01-Export-ADComputers.ps1 -SnapshotDate 2026-07-31
.\src\03-Export-IntuneDevices.ps1 -SkipAutopilot -SkipBitLocker
```

### Apple School Manager

Not automated. Export from the ASM UI, save into the snapshot folder as
`07-asm-devices.csv`, and prefix its columns `ASM_` before merging.

---

## Validate before you join

**This is the step that gets skipped, and it is the step that makes the numbers
defensible.** Every downstream conclusion assumes the extract is complete.

### 1. Row counts against each system's own UI

```powershell
Import-Csv C:\estate-audit\2026-07-31\_manifest.csv | Format-Table
```

| Extract | Compare against |
|---|---|
| `01-ad-computers.csv` | `(Get-ADComputer -Filter *).Count` |
| `02-entra-devices.csv` | Entra admin center → Devices → All devices |
| `03-intune-devices.csv` | Intune admin center → Devices → All devices |
| `04-autopilot.csv` | Intune → Enrollment → Windows Autopilot devices |
| `06-freshservice-assets.csv` | Freshservice → Assets, filter cleared |

A large discrepancy is an **extraction problem, not an estate problem**. Resolve
it before trusting anything downstream. Common causes: admin consent not granted,
a pagination limit hit, an API key scoped to fewer records than your UI session.

### 2. No zero-row files

`Export-EstateCsv` warns loudly on an empty result. A zero-row CSV breaks the
merge in a way that looks like a join problem, so check `_run.log` for `NO ROWS`.

### 3. No permission warnings

`_run.log` records any Graph permission the app was missing at connect time.

### 4. Spot-check a device you know

Pick a laptop you can physically see. Confirm its serial appears in Intune and
Freshservice, its hostname in AD, and that `Intune_lastSyncDateTime` is recent.
One verified device catches whole classes of extraction error.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Environment variable 'X' is not set` | Config not dot-sourced | `. .\config\config.local.ps1` — note the leading dot and space |
| `The ActiveDirectory module is not available` | RSAT missing | See [setup.md](setup.md) §1 |
| Graph connects, extract is empty | Admin consent not granted | Entra → App registrations → API permissions → Grant admin consent |
| `Graph permission '…' is not granted` | Permission missing | Add it and re-consent |
| Certificate error on connect | Wrong thumbprint, or cert not in `CurrentUser\My` | `Get-ChildItem Cert:\CurrentUser\My \| Select Thumbprint, Subject` |
| Freshservice HTTP 401 | Bad API key | Regenerate in Profile Settings |
| Freshservice HTTP 403 | Key's role cannot read assets | Use an agent account with asset read access |
| Freshservice run is very slow | Rate limiting, handled by backoff | Lower `-ThrottleMs` cautiously, or run off-hours |
| `Stopped at the -MaxPage limit` | More records than expected | **Extract is incomplete.** Raise `-MaxPage` and re-run |
| A Power Query merge returns 0 matches | Case or type mismatch | Set key columns to Text; confirm you merged `_normalized_calc` serials |

### Freshservice rate limits

Handled automatically: HTTP 429 and 5xx are retried with the API's own
`Retry-After` delay, five attempts, then a hard failure. `-ThrottleMs` (default
400) paces requests between pages.

---

## Reading the output

`_run.log` is the transcript. `_manifest.csv` is the baseline. Everything else is
raw material for [join-model.md](join-model.md).

The scripts print three reminders that are easy to skim past and shouldn't be:

- **Intune** — a Windows device with `Intune_isEncrypted = TRUE` and no matching
  BitLocker record is an encryption recovery gap, not a data error.
- **Freshservice** — assets deleted in Freshservice sit in Trash and are absent
  from the extract entirely.
- **Freshservice** — the unusable-serial and duplicate-serial counts printed at
  the end are findings, not noise. Each unusable serial is a device that cannot
  be matched on hardware identity.

---

## Cadence and retention

Snapshots are immutable and cheap. Keep every one — the interesting question in
cycle two is not "what is stale?" but "what changed?", and that needs history.

Snapshots contain hostnames, serials, usernames and OU structure for the entire
estate. They are git-ignored and belong on managed storage with the same handling
as any other estate inventory.

---

## What this tooling will not do

It does not disable, delete, retire or release anything, in any system, ever.
Remediation is out of scope by design until the data is understood, and the
agreed remediation order — **Freshservice → Intune → Entra → AD → ASM** — is
recorded in [decision-record.md](decision-record.md), Decision 8. That ordering
matters: deleting a hybrid-joined device in Entra does not work, Intune's delete
triggers a Retire, and an ASM release is effectively one-way.
