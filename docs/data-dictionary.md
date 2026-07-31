# Data dictionary

Every column emitted by the extractors, and the source attribute behind it.

## How to read a column name

```
<Prefix>_<exactSourceAttributeName>     value as the source system returns it
<Prefix>_<name>_calc                    derived by this tooling, not a source field
```

A column without `_calc` can be looked up in the vendor's documentation under
that exact name. A column with `_calc` cannot — it came from a decision made
here, and this file is where that decision is written down.

| Prefix | Source | Reference |
|---|---|---|
| `AD_` | Active Directory computer object | LDAP schema attribute names |
| `Entra_` | Entra ID device | [microsoft.graph.device](https://learn.microsoft.com/graph/api/resources/device) |
| `Intune_` | Intune managed device | [microsoft.graph.managedDevice](https://learn.microsoft.com/graph/api/resources/intune-devices-manageddevice) |
| `AP_` | Autopilot device identity | [windowsAutopilotDeviceIdentity](https://learn.microsoft.com/graph/api/resources/intune-enrollment-windowsautopilotdeviceidentity) |
| `BL_` | BitLocker recovery key | [bitlockerRecoveryKey](https://learn.microsoft.com/graph/api/resources/bitlockerrecoverykey) |
| `FS_` | Freshservice asset | Freshservice API v2 — Assets |
| `FST_` | Freshservice asset type | Freshservice API v2 — Asset Types |

Every file also carries `<Prefix>_snapshotDate_calc`, the snapshot folder date.
It survives the merge, so a row can always be traced to the run that produced it.

---

## 01-ad-computers.csv

`Get-ADComputer` exposes friendly PowerShell property names that differ from the
LDAP attribute names. **The LDAP name wins here**, because that is what the
schema documentation, `ldp.exe`, and anyone debugging replication will use.

| Column | LDAP attribute | PowerShell property | Notes |
|---|---|---|---|
| `AD_name` | `name` | `Name` | |
| `AD_sAMAccountName` | `sAMAccountName` | `SamAccountName` | Trailing `$` on computer accounts |
| `AD_dNSHostName` | `dNSHostName` | `DNSHostName` | Often blank on stale objects |
| `AD_objectGUID` | `objectGUID` | `ObjectGUID` | **Join key** → `Entra_deviceId`. Lowercased |
| `AD_objectSid` | `objectSid` | `SID.Value` | **Join key** → `Entra_onPremisesSecurityIdentifier` |
| `AD_distinguishedName` | `distinguishedName` | `DistinguishedName` | |
| `AD_enabled` | — | `Enabled` | Derived by the AD module from `userAccountControl` bit 2 |
| `AD_userAccountControl` | `userAccountControl` | `userAccountControl` | Raw flags, kept for auditability |
| `AD_operatingSystem` | `operatingSystem` | `OperatingSystem` | Written by the client; stale objects report stale OS |
| `AD_operatingSystemVersion` | `operatingSystemVersion` | `OperatingSystemVersion` | |
| `AD_description` | `description` | `Description` | |
| `AD_managedBy` | `managedBy` | `ManagedBy` | DN, not a name |
| `AD_lastLogonTimestamp` | `lastLogonTimestamp` | `LastLogonTimeStamp` | FILETIME integer, converted to `yyyy-MM-dd`. **Not** `lastLogon` — see caveat below |
| `AD_pwdLastSet` | `pwdLastSet` | `PasswordLastSet` | **Best liveness signal.** 30-day auto-rotation |
| `AD_whenCreated` | `whenCreated` | `whenCreated` | |
| `AD_whenChanged` | `whenChanged` | `whenChanged` | Replicated attribute changes, not device activity |

### Derived

| Column | Definition |
|---|---|
| `AD_lastLogonTimestamp_days_calc` | Whole days since `lastLogonTimestamp`. Negative when future-dated |
| `AD_lastLogonTimestamp_isFuture_calc` | True when the timestamp is ahead of now. **DC clock drift, not device activity** |
| `AD_pwdLastSet_days_calc` | Whole days since `pwdLastSet`. Values well past 30 suggest the machine has not contacted a DC |
| `AD_ou_calc` | `distinguishedName` with the leading RDN removed |
| `AD_userCertificate_count_calc` | Number of values in `userCertificate` |
| `AD_hasUserCertificate_calc` | True when count > 0. Strongest on-prem indicator of completed hybrid Entra join |

> **`lastLogonTimestamp` caveat.** It replicates only once the stored value is
> already 9–14 days old. A three-week gap means nothing. It is a different
> attribute from `lastLogon`, which is accurate but non-replicated and would have
> to be read from every DC and maximised. Prefer `AD_pwdLastSet`.

---

## 02-entra-devices.csv

All columns map 1:1 to `microsoft.graph.device` properties.

| Column | Notes |
|---|---|
| `Entra_id` | Directory object ID. Not the device ID |
| `Entra_deviceId` | **Join key.** ← `AD_objectGUID`, → `Intune_azureADDeviceId`. Lowercased |
| `Entra_displayName` | |
| `Entra_domainName` | |
| `Entra_trustType` | `ServerAd` \| `AzureAd` \| `Workplace`. **Determines the cleanup path entirely** |
| `Entra_profileType` | `RegisteredDevice`, `SecureVM`, `Printer`, `Shared` |
| `Entra_accountEnabled` | |
| `Entra_isManaged` | |
| `Entra_isCompliant` | Null is common and is not the same as non-compliant |
| `Entra_isRooted` | |
| `Entra_managementType` | |
| `Entra_mdmAppId` | |
| `Entra_deviceOwnership` | `Company` \| `Personal` \| `Unknown` |
| `Entra_deviceCategory` | |
| `Entra_enrollmentType` | |
| `Entra_enrollmentProfileName` | Autopilot / ADE profile that enrolled the device |
| `Entra_manufacturer` | |
| `Entra_model` | |
| `Entra_operatingSystem` | |
| `Entra_operatingSystemVersion` | |
| `Entra_onPremisesSyncEnabled` | True → the object is sourced from AD and is **not** deletable here |
| `Entra_onPremisesSecurityIdentifier` | **Join key.** ← `AD_objectSid` |
| `Entra_onPremisesLastSyncDateTime` | Connect/Cloud Sync activity, not device activity |
| `Entra_approximateLastSignInDateTime` | See caveat below |
| `Entra_registrationDateTime` | |

### Derived

| Column | Definition |
|---|---|
| `Entra_approximateLastSignInDateTime_isNull_calc` | True when the property is absent. **Bucket as "unknown", never as "stale"** |
| `Entra_approximateLastSignInDateTime_days_calc` | Whole days since last sign-in |
| `Entra_trustType_meaning_calc` | Plain-English `trustType` for non-specialist readers |
| `Entra_deviceId_isEmpty_calc` | True when `deviceId` is missing or all zeros |

> **`approximateLastSignInDateTime` caveat.** Updates only when the delta exceeds
> 14 days, with roughly ±5 days of variance. Nothing under about 21 days is a
> valid staleness signal, and some genuinely active devices return null.

---

## 03-intune-devices.csv

The join hub. Intune is the only system holding both an identity-layer key and a
hardware-layer key.

| Column | Notes |
|---|---|
| `Intune_id` | Intune's own device ID. ← `AP_managedDeviceId` |
| `Intune_deviceName` | |
| `Intune_managedDeviceName` | Intune-generated, differs from `deviceName` |
| `Intune_serialNumber` | **Join key** (via the normalized form). Raw, exactly as returned |
| `Intune_azureADDeviceId` | **Join key.** ← `Entra_deviceId`. Lowercased; all-zero nulled |
| `Intune_azureADRegistered` | |
| `Intune_managementState` | Documented on the beta `managedDevice`; may be null on v1.0 in some tenants. Verify before relying on it |
| `Intune_complianceState` | |
| `Intune_deviceRegistrationState` | `notRegistered`, `registered`, `revoked`, `keyConflict`, … |
| `Intune_managementAgent` | `eas` means Exchange ActiveSync only — typically a personal phone |
| `Intune_deviceEnrollmentType` | |
| `Intune_managedDeviceOwnerType` | `company` \| `personal` |
| `Intune_deviceCategoryDisplayName` | |
| `Intune_isEncrypted` | True with no matching `BL_deviceId` is an **encryption recovery gap** |
| `Intune_isSupervised` | Apple only |
| `Intune_jailBroken` | |
| `Intune_operatingSystem`, `Intune_osVersion` | |
| `Intune_manufacturer`, `Intune_model` | |
| `Intune_imei`, `Intune_wiFiMacAddress` | Secondary identifiers when serials are unusable |
| `Intune_totalStorageSpaceInBytes`, `Intune_freeStorageSpaceInBytes` | |
| `Intune_userId`, `Intune_userPrincipalName`, `Intune_userDisplayName`, `Intune_emailAddress` | Primary user. Blank on shared and kiosk devices |
| `Intune_enrolledDateTime` | |
| `Intune_lastSyncDateTime` | **Most reliable liveness signal in the estate.** Includes time |

### Derived

| Column | Definition |
|---|---|
| `Intune_serialNumber_normalized_calc` | Uppercased, separators stripped, OEM placeholders nulled. **Merge on this, not the raw column** |
| `Intune_serialNumber_isJunk_calc` | True when normalization returned nothing — an unmatchable device, which is a finding |
| `Intune_azureADDeviceId_isEmpty_calc` | True when all zeros: enrolled but never properly registered in Entra. Looks like a valid GUID, joins to nothing |
| `Intune_lastSyncDateTime_days_calc` | Whole days since last sync |
| `Intune_totalStorageSpaceGB_calc` | Bytes → GB, 1 decimal |
| `Intune_isEasOnly_calc` | True when `managementAgent = eas`. Decide whether these count as computers **before** comparing totals |

Where a device exists in Intune, `Intune_lastSyncDateTime` is the authoritative
last-seen value. AD and Entra timestamps are fallbacks only.

---

## 04-autopilot.csv

| Column | Notes |
|---|---|
| `AP_id` | Autopilot identity ID |
| `AP_serialNumber` | Raw |
| `AP_azureActiveDirectoryDeviceId` | → `Entra_deviceId`. Lowercased |
| `AP_managedDeviceId` | → `Intune_id`. **Pointing at a device that no longer exists is the residue of a reset** |
| `AP_groupTag` | Usually the only place a purchasing cohort is recorded |
| `AP_purchaseOrderIdentifier` | |
| `AP_manufacturer`, `AP_model`, `AP_systemFamily`, `AP_skuNumber` | |
| `AP_enrollmentState` | |
| `AP_deploymentProfileAssignmentStatus` | |
| `AP_deploymentProfileAssignedDateTime` | |
| `AP_lastContactedDateTime` | |
| `AP_userPrincipalName` | Pre-assigned user, if any |

### Derived

| Column | Definition |
|---|---|
| `AP_serialNumber_normalized_calc` | As Intune. Merge on this |
| `AP_serialNumber_isJunk_calc` | |
| `AP_isPresentInAutopilot_calc` | Constant `TRUE`. Survives the merge so an anti-join can answer "registered for Autopilot at all?" |

An Autopilot record with no matching Intune device was bought and never deployed.

---

## 05-bitlocker-escrow.csv

One row per device, aggregated from the recovery key collection. Key material is
never requested — `BitlockerKey.ReadBasic.All` returns metadata only.

| Column | Definition |
|---|---|
| `BL_deviceId` | **Join key** → `Entra_deviceId` / `Intune_azureADDeviceId`. Lowercased |
| `BL_keyCount_calc` | Number of escrowed keys. A high count means repeated re-encryption |
| `BL_hasEscrowedKey_calc` | Constant `TRUE`. Present so the anti-join reads clearly |
| `BL_createdDateTime_first_calc` | Earliest key creation |
| `BL_createdDateTime_last_calc` | Most recent key creation |
| `BL_volumeType_calc` | Distinct volume types, `;`-joined |

---

## 06-freshservice-assets.csv

Top-level asset attributes use the exact API field names. Custom fields arrive
nested under `type_fields` with a numeric suffix that is the **parent asset type
ID**, not the asset's own type — so the key varies by asset type and cannot be a
stable column name. Resolution: strip the suffix for the column name, keep the
exact key beside it, and carry everything in the long file.

| Column | API path | Notes |
|---|---|---|
| `FS_display_id` | `display_id` | The ID shown in the UI |
| `FS_id` | `id` | Internal ID used by the API |
| `FS_name` | `name` | |
| `FS_description` | `description` | |
| `FS_asset_tag` | `asset_tag` | |
| `FS_asset_type_id` | `asset_type_id` | → `FST_id` |
| `FS_impact`, `FS_usage_type` | | |
| `FS_user_id`, `FS_department_id`, `FS_location_id`, `FS_agent_id`, `FS_group_id` | | IDs, not names. Resolve separately if needed |
| `FS_assigned_on`, `FS_created_at`, `FS_updated_at` | | |
| `FS_type_fields.serial_number` | `type_fields.serial_number_<parentTypeId>` | **Join key** (via the normalized form) |
| `FS_type_fields.asset_state` | `type_fields.asset_state_<parentTypeId>` | In Use, In Stock, Retired… |
| `FS_type_fields.hostname` | | Secondary join candidate |
| `FS_type_fields.os`, `FS_type_fields.os_version` | | |
| `FS_type_fields.last_login_by` | | |
| `FS_type_fields.warranty`, `FS_type_fields.warranty_expiry_date` | | |
| `FS_type_fields.acquisition_date` | | |
| `FS_type_fields.product`, `FS_type_fields.vendor` | | |

### Derived

| Column | Definition |
|---|---|
| `FS_asset_type_name_calc` | Resolved from `06b-fs-asset-types.csv` |
| `FS_asset_type_parent_calc` | Immediate parent type name |
| `FS_asset_type_path_calc` | Full chain, e.g. `Hardware > Computer > Laptop` |
| `FS_serial_number_sourceKey_calc` | The exact `type_fields` key as returned, suffix included |
| `FS_serial_number_normalized_calc` | As Intune. **Merge on this** |
| `FS_serial_number_isJunk_calc` | |
| `FS_updated_at_days_calc` | Whole days since last update — CMDB hygiene, not device activity |

> Assets deleted in Freshservice sit in Trash and are **absent from this
> extract**. They are recoverable via `/restore` but invisible here.

---

## 06b-fs-asset-types.csv

| Column | API field | Notes |
|---|---|---|
| `FST_id` | `id` | ← `FS_asset_type_id` |
| `FST_name` | `name` | |
| `FST_description` | `description` | |
| `FST_parent_asset_type_id` | `parent_asset_type_id` | Null at the root |
| `FST_visible` | `visible` | |
| `FST_created_at`, `FST_updated_at` | | |
| `FST_parent_name_calc` | — | Immediate parent name |
| `FST_path_calc` | — | Full chain to the root. **This is what answers "which asset types count as computers?"** |

---

## 06c-fs-type-fields-long.csv

One row per asset per custom field. This file exists so that no Freshservice
attribute is ever lost: it carries every `type_fields` entry under its exact API
key, whether or not the extractor knows about it.

| Column | Definition |
|---|---|
| `FS_display_id`, `FS_id`, `FS_asset_type_id` | Asset this field belongs to |
| `FS_type_field_key` | **Exact key as returned**, e.g. `serial_number_1234` |
| `FS_type_field_name_calc` | Key with the numeric suffix stripped, e.g. `serial_number` |
| `FS_type_field_value` | Value as returned |
| `FS_type_field_isEmpty_calc` | True when null, blank or whitespace |

Pivot on `FS_type_field_name_calc` in Power Query to promote a field to its own
column without re-running extraction.

---

## 07-asm-devices.csv (manual)

Apple School Manager is not automated — [decision-record.md](decision-record.md) §8.
A UI export gives serial number, model and MDM assignment, which is enough for a
first pass. Save it into the snapshot folder as `07-asm-devices.csv` and prefix
its columns `ASM_` before merging.

---

## _manifest.csv

Written by every phase.

| Column | Definition |
|---|---|
| `File`, `System` | What was written, and from where |
| `Rows`, `Columns` | Baseline counts — **compare against each system's own UI before joining** |
| `GeneratedAt` | |

A large discrepancy between a manifest count and the corresponding UI count is an
extraction problem, not an estate problem. Resolve it before trusting any join.

---

## Normalization rules

Applied identically everywhere by `src/EstateAudit.psm1`, because Power Query
merges are unforgiving.

**GUIDs** — lowercased and trimmed. AD returns uppercase, Graph returns
lowercase, and the merge is case-sensitive; skipping this returns zero matches
and looks like a data catastrophe. The all-zero GUID is treated as absent.

**Serials** — uppercased, `[space] - _ .` stripped, then nulled if the result is
an OEM placeholder, shorter than four characters, or a single repeated character.
Nulling is deliberate: an unmatchable serial should fail to join loudly rather
than join to the wrong device. The raw value is always retained alongside.

Placeholders currently nulled: `TOBEFILLEDBYOEM`, `TOBEFILLEDBYO.E.M.`,
`SYSTEMSERIALNUMBER`, `DEFAULTSTRING`, `CHASSISSERIALNUMBER`,
`BASEBOARDSERIALNUMBER`, `SERIALNUMBER`, `SERIAL`, `NONE`, `NA`, `N/A`, `NULL`,
`UNKNOWN`, `INVALID`, `NOTSPECIFIED`, `NOTAPPLICABLE`, `NOTAVAILABLE`, `TBD`,
`ASSETTAG`, `0123456789`.

**Dates** — `yyyy-MM-dd`, or `yyyy-MM-dd HH:mm:ss` where time matters. Parsed
unambiguously by Excel and Power Query regardless of regional settings.

**Day counts** — whole days, and negative values are left intact. A negative
`AD_lastLogonTimestamp_days_calc` means DC clock drift, which is a finding, not
something to clamp away.
