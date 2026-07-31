# Changelog

## [0.2.0] — 2026-07-31

Restructured the four standalone scripts into a documented, versioned project.

### Changed — column naming

Columns now carry the **exact source attribute name** after the source prefix,
with derived values suffixed `_calc`. See
[decision-record.md](docs/decision-record.md), Decision 9.

| Before | After |
|---|---|
| `AD_PasswordLastSet` | `AD_pwdLastSet` |
| `AD_LastLogonDate` | `AD_lastLogonTimestamp` |
| `AD_DaysSinceLogon` | `AD_lastLogonTimestamp_days_calc` |
| `Entra_LastSignIn` | `Entra_approximateLastSignInDateTime` |
| `Entra_Enabled` | `Entra_accountEnabled` |
| `Intune_AadDeviceId` | `Intune_azureADDeviceId` |
| `Intune_SerialRaw` / `Intune_SerialNorm` | `Intune_serialNumber` / `Intune_serialNumber_normalized_calc` |
| `Intune_RegistrationState` | `Intune_deviceRegistrationState` |
| `FS_SerialRaw` | `FS_type_fields.serial_number` |

**This breaks any existing Power Query workbook.** Re-point the merge steps at
the new column names, or keep the old workbook against old snapshots.

### Fixed

- **Freshservice custom fields were being discarded.** The extractor read seven
  named `type_fields` and silently dropped every other custom attribute on every
  asset. All fields are now emitted under their exact API keys in
  `06c-fs-type-fields-long.csv`.
- **Freshservice `type_fields` matching was a prefix test.** `os` also matched
  `os_version` and `os_service_pack`, and which one won depended on property
  ordering — a silent wrong-value bug. Matching is now anchored to
  `<name>` or `<name>_<digits>`.
- **`Retry-After` parsing was broken on PowerShell 6+.** `$response.Headers['Retry-After']`
  returns a collection on the modern HTTP stack, so the `[int]` cast failed and
  every rate-limited request fell back to the default delay. Both stacks are now
  handled, and 5xx responses are retried as well as 429.
- **AD `DNSHostName` was requested but never emitted.** It was listed in
  `$props` and absent from the output object.
- **Extracts ignored the dated snapshot convention.** All four scripts wrote to a
  flat `C:\estate-audit\`, overwriting the previous cycle, despite the convention
  requiring one dated folder per run.
- Null-guarded date and GUID conversions that would throw on incomplete records
  (`whenCreated`, `DeviceId`).
- Replaced `$array += $item` accumulation in the Freshservice pull, which is
  O(n²) — it reallocates the whole array per asset.

### Added

- `src/EstateAudit.psm1` — shared snapshot, normalization, CSV and manifest
  helpers, so GUID and serial handling cannot drift between extractors.
- `src/EstateGraph.psm1` — Graph certificate auth, with a startup warning when a
  required application permission is not granted. Previously a missing consent
  surfaced as an empty extract that read like an estate finding.
- `src/Invoke-Assessment.ps1` — runs all phases into one snapshot, continues past
  a failed phase, prints per-phase results and baseline row counts.
- **Raw sidecars.** Every phase writes the complete untransformed source response
  to `raw\<file>.jsonl`. Adding a column later no longer means another
  authenticated pull against production — Decision 10.
- `_manifest.csv` — row and column counts per file, closing the "baseline row
  counts per system" open item.
- `_run.log` — timestamped transcript per snapshot.
- `FST_path_calc` — the full Freshservice asset type chain
  (`Hardware > Computer > Laptop`), which is what answers "which asset types
  count as computers".
- New attributes: AD `sAMAccountName`, `dNSHostName`, `whenChanged`,
  `userAccountControl`, `managedBy`; Entra `manufacturer`, `model`, `domainName`,
  `deviceCategory`, `enrollmentProfileName`, `isRooted`,
  `onPremisesLastSyncDateTime`; Intune `managedDeviceName`, `imei`,
  `wiFiMacAddress`, `freeStorageSpaceInBytes`, `jailBroken`, `userId`,
  `emailAddress`; Autopilot `systemFamily`, `skuNumber`,
  `purchaseOrderIdentifier`, `lastContactedDateTime`, `userPrincipalName`;
  BitLocker key creation dates and volume types.
- `Intune_isEasOnly_calc`, flagging Exchange ActiveSync-only records ahead of the
  open decision on whether they count as computers.
- `tests/Test-EstateAudit.ps1` — credential-free checks over the shared helpers.
  Every cross-system join depends on GUID and serial normalization; if either
  drifts, merges return zero rows and it reads as an estate catastrophe rather
  than a code change.
- Documentation: `README.md`, `docs/setup.md`, `docs/runbook.md`,
  `docs/data-dictionary.md`, `docs/join-model.md`.

### Security

- Credentials moved to environment variables. The Freshservice API key was
  previously a literal in the script.
- `$appId`, `$tenantId` and `$thumb` were undefined variables in the Entra and
  Intune scripts — they connected using whatever happened to be in the session,
  or failed obscurely. Now read explicitly and validated.
- `.gitignore` excludes `config.local.ps1`, certificates, and all extracted data.
  Snapshots contain hostnames, serials, usernames and OU structure for the whole
  estate.

---

## [0.1.0] — 2026-07-31

Baseline import: four standalone extraction scripts (AD, Entra, Intune,
Freshservice) and the assessment decision record, recorded as they stood before
restructuring.
