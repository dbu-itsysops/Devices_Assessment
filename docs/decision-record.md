# Device Estate Assessment — Goals & Decision Record

**Owner:** Bruno Jorge, Director of Infrastructure & Cloud Services
**Status:** Extraction in progress
**Last updated:** 2026-07-31

This is the *why*. For the *how*, see [setup.md](setup.md), [runbook.md](runbook.md),
[data-dictionary.md](data-dictionary.md) and [join-model.md](join-model.md).

---

## 1. Objective

Establish an accurate, verifiable picture of every computer record across five systems, so we can identify which records are stale, duplicated, orphaned, or malformed — and then decide what "garbage" actually means based on evidence rather than assumption.

Systems in scope:

| System | Holds |
|---|---|
| Active Directory | Domain-joined computer objects |
| Microsoft Entra ID | Device identities (hybrid joined, Entra joined, registered) |
| Microsoft Intune | Managed devices, Autopilot registrations, BitLocker key escrow |
| Apple School Manager | Apple hardware owned by the institution (ADE) |
| Freshservice | Asset/CMDB records with business and financial attributes |

---

## 2. Scope

**In scope**
- Extract: read-only pull from all five systems
- Join: reconcile records across systems on documented keys
- Classify: bucket every record and quantify the findings

**Explicitly out of scope for now**
- Remediation of any kind — no disables, no deletes, no releases
- Defining staleness thresholds or a cleanup policy
- Process/automation changes to prevent recurrence

Remediation and policy come after we know what we have. That ordering was a deliberate change from the original plan (see Decision 1).

---

## 3. Decisions

### Decision 1 — Data first, policy second

*Original proposal:* write a cleanup policy defining "garbage" before extracting anything.

*Decision:* reversed. Extract and reconcile first, define thresholds afterward.

*Rationale:* thresholds written without knowing the actual distribution of last-seen dates would be guesses, and would likely need rewriting once the data arrived. A university estate has seasonal idle patterns (summer, sabbaticals, lab carts) that only become visible in the data.

### Decision 2 — Autopilot, BitLocker, loaners, and cluster objects are columns, not filters

*Original proposal:* listed these as "exclusions" to be defined up front.

*Decision:* corrected. They are attributes on the master sheet, not records to be withheld from the extract.

*Rationale:* they were remediation gates — reasons not to *delete* something — mistakenly placed in the assessment phase. Several are findings in their own right. A Windows device reporting `isEncrypted = true` with no escrowed BitLocker key is an encryption recovery gap, and filtering it out would hide it.

### Decision 3 — Extract with PowerShell, join in Excel Power Query

*Decision:* PowerShell for extraction, Power Query for the merge.

*Rationale:*
- Extraction requires LDAP and API access; there is no non-scripted path.
- The join belongs in Excel for visibility. Power Query specifically, not XLOOKUP, because:
  - it performs **anti-joins** (records present in one system and nowhere else), which is where the findings live
  - it reports the match count after each merge, so failures are visible instead of silent
  - it's refreshable — next cycle is drop in new CSVs and Refresh All

### Decision 4 — Intune is the join hub

*Decision:* build the master table outward from Intune, then append orphan blocks from the other four systems.

*Rationale:* no single key spans all five systems. AD and Entra carry no serial number; ASM and Freshservice carry no device ID. **Intune is the only system holding both** — `azureADDeviceId` linking up to the identity layer, `serialNumber` linking across to the hardware layer.

```
AD computer
   │ objectGUID ──────────► deviceId
   ▼
Entra device
   │ deviceId ────────────► azureADDeviceId
   ▼
Intune managed device  ◄── HUB
   │ serialNumber
   ├──────────► ASM orgDevice.serialNumber
   └──────────► Freshservice type_fields.serial_number
```

`objectGUID → deviceId` and `objectSid → onPremisesSecurityIdentifier` are documented mappings in both Entra Connect Sync and Cloud Sync, so this join survives the planned Cloud Sync migration unchanged.

A single outward pass from AD would hide every Mac, iPad, and cloud-only device. Reverse passes from each system are mandatory.

### Decision 5 — Certificate auth over client secret

*Decision:* use the existing app registration with a certificate, not a client secret.

*Rationale:* Power Query can call Graph directly, but the client secret ends up stored in the workbook. A credential with `Device.Read.All` across the tenant sitting in a shareable .xlsx is not acceptable. Certificate auth via PowerShell removes the problem entirely.

**Graph permissions (Application):**

| Permission | Covers |
|---|---|
| `Device.Read.All` | Entra device objects |
| `DeviceManagementManagedDevices.Read.All` | Intune managed devices |
| `DeviceManagementServiceConfig.Read.All` | Autopilot device identities |
| `BitlockerKey.ReadBasic.All` | Key metadata only — does not permit reading recovery keys |

All are least-privileged for their endpoints. `Directory.Read.All` was rejected as over-scoped.

### Decision 6 — Autopilot and BitLocker extracted separately

*Decision:* three separate pulls in the Intune phase, not one.

*Rationale:* they are distinct objects at distinct endpoints with their own IDs and lifecycles. Graph does not surface them on the managedDevice. A single laptop can hold five separate records (AD, Entra, Intune, Autopilot, BitLocker keys), and **the mismatch between them is the finding** — e.g. an Autopilot registration with no Intune device (bought, never deployed), or an Autopilot record pointing at a stale `managedDeviceId` after a reset.

### Decision 7 — Freshservice: pull everything, filter in Excel

*Decision:* no server-side asset type filter.

*Rationale:* the UI's "Choose from Hierarchy" includes child asset types; the API's `asset_type_id` filter is exact match only. Filtering server-side on Computer would silently drop Laptop, Desktop, Server and any other sub-type. Comparing the full API count against the UI count is also our first sanity check.

### Decision 8 — Remediation order (agreed, deferred)

When we do reach remediation, the order is fixed:

**Freshservice → Intune → Entra → AD → ASM**

*Rationale:* these systems are not peers.
- Deleting a hybrid-joined device in Entra doesn't work — Connect re-syncs it from AD as a new "Pending" object requiring client re-registration. AD is authoritative.
- Intune's Delete triggers a **Retire** command on Windows, macOS, and Apple mobile.
- ASM release is effectively one-way; re-adding requires Apple Configurator or an Authorized Reseller.
- Freshservice is the only system with a genuinely reversible delete (Trash → `/restore`).

### Decision 9 — Columns carry the source attribute name, not an alias

*Original implementation:* extracted columns used invented short names — `Entra_LastSignIn`, `Intune_AadDeviceId`, `AD_PasswordLastSet`, `FS_SerialRaw`.

*Decision:* every column is named `<Prefix>_<exactSourceAttributeName>`. Anything this tooling derives rather than reads carries a `_calc` suffix.

*Rationale:* the alias was a second vocabulary to maintain. With ~60 merged columns, `Entra_LastSignIn` cannot be looked up anywhere — it has to be translated back to `approximateLastSignInDateTime` before the Graph documentation, the 14-day update caveat, or a Microsoft support case makes sense. Two of the aliases were also actively misleading: `AD_PasswordLastSet` is `pwdLastSet`, and `AD_LastLogonDate` is `lastLogonTimestamp`, which is *not* `lastLogon` and carries entirely different replication behaviour. The `_calc` suffix answers the follow-on question — whether a column can be looked up in vendor documentation at all, or whether it came from a judgement made here.

Freshservice is the awkward case, because its `type_fields` keys carry a numeric suffix that is the *parent* asset type ID, so the key varies by asset type and cannot be a stable column name. Resolved three ways at once:

- curated columns keep the attribute name with the suffix stripped — `FS_type_fields.serial_number`
- the exact key as returned is kept beside it in `FS_serial_number_sourceKey_calc`
- `06c-fs-type-fields-long.csv` carries *every* custom field under its exact key, known to the script or not

The third file is the one that matters. The previous implementation read seven named fields and silently discarded every other custom attribute on every asset.

### Decision 10 — Raw sidecars alongside every curated extract

*Decision:* each phase writes the complete untransformed source response to `raw\<file>.jsonl` next to its curated CSV.

*Rationale:* the curated CSVs are a deliberate subset, and subsets chosen before the data is understood are usually wrong. The sidecar means adding a column later is a re-read of a snapshot rather than another authenticated pull against production — and it makes "the extract never showed us that field" impossible.

---

## 4. Conventions

These are load-bearing. Breaking any of them causes joins to fail silently.

| Convention | Why |
|---|---|
| Prefix every column with its source (`AD_`, `Entra_`, `Intune_`, `AP_`, `BL_`, `FS_`) | With 60 merged columns, you always know the provenance of a value |
| After the prefix, use the **exact source attribute name**; suffix anything derived with `_calc` | A column is either something a vendor documents or something we decided. The name says which — see Decision 9 |
| Lowercase all GUIDs at extraction | AD and Graph return different casing; Power Query merges are case-sensitive. Skipping this returns zero matches and looks like a data catastrophe |
| Normalize serials: uppercase, strip separators, null out OEM placeholders | `To Be Filled By O.E.M.`, `Default string`, `System Serial Number` are common. Each one is a device that cannot be matched — a finding, not noise |
| Set serial and GUID columns to **Text** in Power Query before merging | Otherwise `0012345` becomes the number `12345` and never matches again |
| Match Freshservice `type_fields` by **prefix**, never by hardcoded suffix | The numeric suffix is the *parent* asset type ID, not the asset's own type |
| One dated snapshot folder; raw CSVs immutable | All transformation happens in Power Query, so we can always prove whether a problem is the data or the logic |

---

## 5. Extraction status

| Phase | System | Method | Script | Status |
|---|---|---|---|---|
| 1 | Active Directory | `Get-ADComputer`, RSAT module | `src/01-Export-ADComputers.ps1` | Script delivered |
| 2 | Entra ID | Graph, cert auth | `src/02-Export-EntraDevices.ps1` | Script delivered |
| 3 | Intune (+ Autopilot, BitLocker) | Graph, cert auth | `src/03-Export-IntuneDevices.ps1` | Script delivered |
| 4 | Freshservice | REST API v2, Basic auth | `src/04-Export-Freshservice.ps1` | Script delivered |
| 5 | Apple School Manager | TBD — API or UI export | — | **Not started** |

Each phase produces one or more CSVs into `C:\estate-audit\<yyyy-MM-dd>\`, with the
untransformed source response alongside in `raw\`. `src/Invoke-Assessment.ps1` runs
phases 1–4 into a single snapshot.

### Key fields by system

Column names below are as emitted. Full listing in [data-dictionary.md](data-dictionary.md).

**AD** — `AD_objectGUID` (join key), `AD_objectSid`, `AD_pwdLastSet` (best liveness signal — 30-day auto-rotation), `AD_lastLogonTimestamp`, `AD_enabled`, `AD_operatingSystem`, `AD_ou_calc`, `AD_hasUserCertificate_calc` (hybrid-join candidate indicator)

**Entra** — `Entra_deviceId` (join key), `Entra_trustType` (`ServerAd` / `AzureAd` / `Workplace` — determines cleanup path), `Entra_approximateLastSignInDateTime`, `Entra_accountEnabled`, `Entra_isManaged`, `Entra_onPremisesSyncEnabled`, `Entra_onPremisesSecurityIdentifier`

**Intune** — `Intune_azureADDeviceId` + `Intune_serialNumber` (the two join keys), `Intune_lastSyncDateTime` (most reliable liveness signal in the estate), `Intune_managementState`, `Intune_managementAgent`, `Intune_deviceEnrollmentType`, `Intune_complianceState`, `Intune_isEncrypted`

**Freshservice** — `FS_display_id`, `FS_type_fields.serial_number` (join key), `FS_type_fields.asset_state`, `FS_asset_type_id`, `FS_user_id`, `FS_updated_at`

---

## 6. Known data-quality traps

Documented so they aren't rediscovered as surprises:

- **AD `lastLogonTimeStamp`** replicates only when the stored value is already 9–14 days old. A three-week gap means nothing. It can also be **future-dated** by DC clock drift — that's an AD time problem, not device activity.
- **Entra `approximateLastSignInDateTime`** updates only when the delta exceeds 14 days (±5 days variance). Nothing under ~21 days is a valid staleness signal. Some genuinely active devices return **null** — bucket as "unknown," never as "stale."
- **Intune `azureADDeviceId` of all zeros** — enrolled but never properly registered in Entra. Looks like a valid GUID, joins to nothing.
- **Intune `managementAgent = eas`** — Exchange ActiveSync only, typically personal phones. Decide whether these belong in the device count before comparing totals.
- **Freshservice deleted assets** live in Trash, not gone. They won't appear in the extract.

Where a device exists in Intune, `lastSyncDateTime` is the authoritative last-seen value. AD and Entra timestamps are fallbacks only.

---

## 7. Classification model

Every record lands in exactly one bucket:

| Bucket | Definition |
|---|---|
| A | Reconciled and healthy |
| B | Stale (aged past threshold in every system tracking it) |
| C | Duplicate (same serial or hostname, multiple records) |
| D | Orphan (present in some systems, absent from others) |
| E | Dirty data (junk serial, missing owner, contradictory state) |

**Primary analysis tool: `PresencePattern`** — a five-digit signature per device reading AD-Entra-Intune-ASM-FS (`11101`, `01110`, `00011`). Pivoting on this collapses thousands of rows into ~20 patterns ranked by frequency.

Two patterns to surface separately for leadership:

- **Domain-joined but not in Intune** → not covered by compliance policy or device-based Conditional Access. Security finding.
- **Managed but not in Freshservice** → not covered by lifecycle, warranty, or funding tracking. Asset control finding.

Both carry more weight than "our device lists are messy."

---

## 8. Open items

| Item | Owner | Notes |
|---|---|---|
| ASM extraction method | Bruno | API requires an API account + ES256 JWT signing. UI export gives serial, model, MDM assignment — sufficient for a first pass. Drop the export into the snapshot folder as `07-asm-devices.csv` |
| Baseline row counts per system | Bruno | Needed before joining; large discrepancies indicate extraction problems, not estate problems. Now emitted automatically to `_manifest.csv` — still needs comparing against each system's own UI |
| Whether EAS-only devices count as "computers" | Bruno | Affects every cross-system total. Flagged per-row as `Intune_isEasOnly_calc` |
| Freshservice asset type hierarchy | Bruno | Determines the Excel filter for "computers". Now extracted with the full parent chain in `FST_path_calc` (`Hardware > Computer > Laptop`) |
| Staleness thresholds | Deferred | Post-assessment, by design |
| Field authority model (which system owns which field) | Deferred | Prerequisite for preventing recurrence |