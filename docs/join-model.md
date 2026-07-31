# Join model

How six CSVs become one master table, and why it is built this way.

---

## Why Intune is the hub

No single key spans all five systems. AD and Entra carry no serial number; Apple
School Manager and Freshservice carry no device ID. **Intune is the only system
holding both** — `azureADDeviceId` reaching up to the identity layer,
`serialNumber` reaching across to the hardware layer.

```
AD computer
   │ AD_objectGUID ─────────────► Entra_deviceId
   ▼
Entra device
   │ Entra_deviceId ────────────► Intune_azureADDeviceId
   ▼
Intune managed device  ◄── HUB
   │ Intune_serialNumber_normalized_calc
   ├────────────────────────────► ASM_serialNumber
   └────────────────────────────► FS_serial_number_normalized_calc
```

`objectGUID → deviceId` and `objectSid → onPremisesSecurityIdentifier` are
documented mappings in both Entra Connect Sync and Cloud Sync, so this join
survives the planned Cloud Sync migration unchanged.

**A single outward pass from AD would hide every Mac, iPad and cloud-only
device.** Reverse passes from each system are mandatory — build outward from
Intune, then append an orphan block from each other system.

---

## Join keys

| From | Key | To | Key |
|---|---|---|---|
| AD | `AD_objectGUID` | Entra | `Entra_deviceId` |
| AD | `AD_objectSid` | Entra | `Entra_onPremisesSecurityIdentifier` |
| Entra | `Entra_deviceId` | Intune | `Intune_azureADDeviceId` |
| Entra | `Entra_deviceId` | BitLocker | `BL_deviceId` |
| Intune | `Intune_id` | Autopilot | `AP_managedDeviceId` |
| Intune | `Intune_serialNumber_normalized_calc` | Autopilot | `AP_serialNumber_normalized_calc` |
| Intune | `Intune_serialNumber_normalized_calc` | Freshservice | `FS_serial_number_normalized_calc` |
| Intune | `Intune_serialNumber_normalized_calc` | ASM | `ASM_serialNumber` (normalize on import) |

Always merge on the `_normalized_calc` serial columns, never the raw ones.

`AD_objectSid → Entra_onPremisesSecurityIdentifier` is a second, independent path
for hybrid devices. Use it to validate the GUID join: rows that match on one key
and not the other are worth looking at directly.

---

## Power Query, not XLOOKUP

Three reasons, all load-bearing:

- it performs **anti-joins** — records present in one system and nowhere else,
  which is where the findings live
- it reports the match count after each merge, so a failed join is visible
  instead of silent
- it is refreshable — the next cycle is "drop in new CSVs, Refresh All"

---

## Building the workbook

### 1. Load

**Data → Get Data → From File → From Folder**, pointed at the snapshot folder.
Load each CSV as its own query. Do not load anything to the sheet yet.

### 2. Set key columns to Text — before anything else

Select every serial and GUID column and set the type to **Text** explicitly.

If you skip this, Power Query type-detection reads `0012345` as the number
`12345`, drops the leading zero, and that device never matches again. This is the
single most common cause of a join that "worked last month".

### 3. Merge outward from Intune

Start with `03-intune-devices`. For each merge use **Left Outer**, and read the
match count in the status bar every time:

| Step | Left | Right | Keys |
|---|---|---|---|
| 1 | Intune | Entra | `Intune_azureADDeviceId` = `Entra_deviceId` |
| 2 | result | AD | `Entra_deviceId` = `AD_objectGUID` |
| 3 | result | Autopilot | `Intune_serialNumber_normalized_calc` = `AP_serialNumber_normalized_calc` |
| 4 | result | BitLocker | `Intune_azureADDeviceId` = `BL_deviceId` |
| 5 | result | Freshservice | `Intune_serialNumber_normalized_calc` = `FS_serial_number_normalized_calc` |
| 6 | result | ASM | `Intune_serialNumber_normalized_calc` = `ASM_serialNumber` |

A match count far below the row count is a real finding. A match count of
**zero** is a bug — check for case, type, or a null-heavy key column before
concluding anything about the estate.

### 4. Append the orphan blocks

Duplicate each source query and merge it against the master with
**Left Anti** to isolate records that exist nowhere else, then append those
blocks to the master table. Without this pass, every Mac, iPad and cloud-only
device is invisible.

Recommended anti-joins:

- AD records with no Entra match — never hybrid joined, or long dead
- Entra records with no Intune match — registered but unmanaged
- Autopilot records with no Intune match — bought, never deployed
- Freshservice assets with no Intune match — tracked financially, unmanaged
- Intune devices with no Freshservice match — managed, untracked

---

## PresencePattern

The primary analysis tool. A five-digit signature per device reading
**AD-Entra-Intune-ASM-FS**:

```
PresencePattern =
      (if [AD_objectGUID]    <> null then "1" else "0")
    & (if [Entra_deviceId]   <> null then "1" else "0")
    & (if [Intune_id]        <> null then "1" else "0")
    & (if [ASM_serialNumber] <> null then "1" else "0")
    & (if [FS_display_id]    <> null then "1" else "0")
```

Pivoting on this collapses thousands of rows into roughly twenty patterns ranked
by frequency, which is the difference between a spreadsheet and a finding.

| Pattern | Reading |
|---|---|
| `11111` | Fully reconciled |
| `11100` | Domain-joined and managed, but not an asset record |
| `11000` | Domain-joined, not managed — **security finding** |
| `00111` | Apple estate, no AD presence. Normal, not a problem |
| `00001` | Freshservice only — never deployed, or long retired |
| `10000` | AD only — the classic stale computer object |

Two patterns to surface separately for leadership:

- **Domain-joined but not in Intune** (`11000`, `10000`) — not covered by
  compliance policy or device-based Conditional Access. **Security finding.**
- **Managed but not in Freshservice** (`xxxx0` where Intune = 1) — not covered by
  lifecycle, warranty or funding tracking. **Asset control finding.**

Both carry considerably more weight with a leadership audience than "our device
lists are messy".

---

## Classification buckets

Every record lands in exactly one:

| Bucket | Definition |
|---|---|
| A | Reconciled and healthy |
| B | Stale — aged past threshold in every system tracking it |
| C | Duplicate — same serial or hostname, multiple records |
| D | Orphan — present in some systems, absent from others |
| E | Dirty data — junk serial, missing owner, contradictory state |

Thresholds for bucket B are deliberately undefined until the distribution of
last-seen dates is visible — [decision-record.md](decision-record.md), Decision 1.

Useful sanity check for bucket E before thresholds exist: rows where
`Intune_isEncrypted = TRUE` and `BL_hasEscrowedKey_calc` is null. That is an
encryption recovery gap, and it is worth reporting on its own.
