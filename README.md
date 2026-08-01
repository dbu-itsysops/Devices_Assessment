# Devices Assessment

One script that pulls computer records out of AD, Entra, Intune, Autopilot,
BitLocker and Freshservice into CSVs, ready to load into Excel and reconcile.

Read-only. Nothing here disables, deletes, retires or releases anything —
remediation stays out of scope until the data is understood
([decision-record.md](docs/decision-record.md), Decision 1).

## Run it

```powershell
.\Export-DeviceEstate.ps1
```

You'll get a browser sign-in prompt for Graph. Writes to `C:\estate-audit\<today>\`.

```powershell
.\Export-DeviceEstate.ps1 -Server adc.dbu.edu
.\Export-DeviceEstate.ps1 -OutputPath D:\audit
.\Export-DeviceEstate.ps1 -Phase Freshservice
.\Export-DeviceEstate.ps1 -Phase AD,Entra -Server adc.dbu.edu -OutputPath D:\audit
```

| Parameter | Default |
|---|---|
| `-OutputPath` | `C:\estate-audit\<today>` |
| `-Phase` | all four: `AD`, `Entra`, `Intune`, `Freshservice` |
| `-Server` | your logon DC |
| `-GraphAuth` | `Interactive` — or `Certificate` for app-only |

## Setup

```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0
```

Freshservice credentials come from the environment — nothing secret is in this repo:

```powershell
$env:FRESHSERVICE_DOMAIN  = 'dbu.freshservice.com'
$env:FRESHSERVICE_API_KEY = '<api key>'
```

Or pass `-FreshserviceDomain` / `-FreshserviceApiKey` on the command line.

## Graph access

Permissions are the same names either way, all read-only:
`Device.Read.All`, `DeviceManagementManagedDevices.Read.All`,
`DeviceManagementServiceConfig.Read.All`, `BitlockerKey.ReadBasic.All`.

**Signing in as yourself (default).** The script requests those scopes at sign-in.
Delegated access is the intersection of what the app may do and what *you* may do,
so your Entra role decides how much of the tenant comes back — **Global Reader is
enough** for all four phases.

> ⚠️ **BitLocker is the one to watch.** With delegated access you only get keys for
> devices *you personally own*, unless you hold Global reader, Security reader,
> Cloud device administrator, Helpdesk administrator, Intune service administrator
> or Security administrator. Without one of those, `05-bitlocker-escrow.csv` comes
> back nearly empty and looks like an estate-wide encryption gap. It isn't one.
> The script prints a reminder at that step.

**App-only (`-GraphAuth Certificate`).** Certificate, not a client secret
([decision-record.md](docs/decision-record.md), Decision 5). Set the app
registration up, grant admin consent, then:

```powershell
$env:ESTATE_GRAPH_APP_ID     = '<app id>'
$env:ESTATE_GRAPH_TENANT_ID  = '<tenant id>'
$env:ESTATE_GRAPH_CERT_THUMB = '<cert thumbprint in CurrentUser\My>'
.\Export-DeviceEstate.ps1 -GraphAuth Certificate
```

Create the certificate with:

```powershell
$cert = New-SelfSignedCertificate -Subject "CN=DevicesAssessment" `
    -CertStoreLocation "Cert:\CurrentUser\My" -KeyExportPolicy NonExportable `
    -KeySpec Signature -NotAfter (Get-Date).AddYears(2)
$cert.Thumbprint
Export-Certificate -Cert $cert -FilePath "$env:TEMP\DevicesAssessment.cer"
```

Upload the `.cer` to the app registration. Never commit the private key.
Without admin consent the extracts come back empty rather than erroring, which
reads like an estate finding.

## Output

| File | Contents |
|---|---|
| `01-ad-computers.csv` | AD computer objects |
| `02-entra-devices.csv` | Entra device identities |
| `03-intune-devices.csv` | Intune managed devices — **the join hub** |
| `04-autopilot.csv` | Autopilot registrations |
| `05-bitlocker-escrow.csv` | Devices with escrowed BitLocker keys |
| `06-freshservice-assets.csv` | Freshservice assets |
| `06b-fs-asset-types.csv` | Asset type hierarchy, with the full path per type |
| `06c-fs-type-fields-long.csv` | Every Freshservice custom field, under its exact API key |

Apple School Manager is not automated. Export from the UI and drop it in as
`07-asm-devices.csv`.

The script prints row counts at the end. **Compare them against each system's own
UI before joining** — a large gap is an extraction problem, not an estate problem.

## Column names

```
<Prefix>_<exactSourceAttributeName>    value as the source system returns it
<Prefix>_<name>_calc                   worked out by the script
```

So `Entra_approximateLastSignInDateTime`, not `Entra_LastSignIn`. Any column
without `_calc` can be looked up in the vendor's own documentation under that
name. Prefixes: `AD_`, `Entra_`, `Intune_`, `AP_`, `BL_`, `FS_`, `FST_`.

## What changed from the original four scripts

Renamed columns — **this breaks any existing Power Query work**:

| Before | After |
|---|---|
| `AD_PasswordLastSet` | `AD_pwdLastSet` |
| `AD_LastLogonDate` | `AD_lastLogonTimestamp` |
| `Entra_LastSignIn` | `Entra_approximateLastSignInDateTime` |
| `Entra_Enabled` | `Entra_accountEnabled` |
| `Intune_AadDeviceId` | `Intune_azureADDeviceId` |
| `Intune_SerialRaw` / `SerialNorm` | `Intune_serialNumber` / `Intune_serialNumber_normalized_calc` |
| `FS_SerialRaw` | `FS_type_fields.serial_number` |

Bugs fixed:

- Freshservice `type_fields` were matched by prefix, so `os` also matched
  `os_version` and `os_service_pack` — which one won depended on property order.
  Now anchored to `<name>` or `<name>_<digits>`.
- Every custom Freshservice field except seven named ones was silently dropped.
  All of them now land in `06c-fs-type-fields-long.csv` under their exact keys.
- `Retry-After` parsing was broken on PowerShell 6+, so rate-limited requests
  always fell back to a 30-second guess.
- AD `DNSHostName` was requested but never written out.
- All four scripts wrote to a flat `C:\estate-audit\`, overwriting the previous
  run despite the dated-snapshot convention.
- Day counts rounded instead of flooring — 9.7 days reported as 10.
- The Freshservice API key was a literal in the script; `$appId`, `$tenantId`
  and `$thumb` were undefined variables.
- Graph returns UTC timestamps and the script compared them against local time,
  shifting every Entra, Intune and Freshservice day count by the UTC offset.
  Devices that had just synced reported `-1` days.
- `onPremisesSecurityIdentifier` is not in Graph's default projection for
  devices, so it needed an explicit `$select`. Without it the
  `objectSid → onPremisesSecurityIdentifier` cross-check on the AD→Entra join
  came back empty.

Dropped, because both are beta-only and returned empty on every row:
`Intune_managementState` (use `complianceState` / `deviceRegistrationState`) and
`AP_deploymentProfileAssignmentStatus` (replaced by `AP_lastContactedDateTime`).
