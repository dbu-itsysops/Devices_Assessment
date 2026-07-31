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

Writes to `C:\estate-audit\<today>\`. Options:

```powershell
.\Export-DeviceEstate.ps1 -OutputPath D:\audit
.\Export-DeviceEstate.ps1 -Phase Freshservice
.\Export-DeviceEstate.ps1 -Phase AD,Entra -OutputPath D:\audit
```

## Setup

```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0
```

Credentials come from environment variables — nothing secret is in this repo:

```powershell
$env:ESTATE_GRAPH_APP_ID     = '<app id>'
$env:ESTATE_GRAPH_TENANT_ID  = '<tenant id>'
$env:ESTATE_GRAPH_CERT_THUMB = '<cert thumbprint in CurrentUser\My>'
$env:FRESHSERVICE_DOMAIN     = 'dbu.freshservice.com'
$env:FRESHSERVICE_API_KEY    = '<api key>'
```

Add `-Verbose`-style overrides on the command line instead if you prefer:
`-AppId`, `-TenantId`, `-CertThumbprint`, `-FreshserviceDomain`, `-FreshserviceApiKey`.

Graph app permissions (application, least-privileged, all read-only):
`Device.Read.All`, `DeviceManagementManagedDevices.Read.All`,
`DeviceManagementServiceConfig.Read.All`, `BitlockerKey.ReadBasic.All`.
Grant admin consent — without it the extracts come back empty rather than
erroring, which reads like an estate finding.

Certificate auth, not a client secret ([decision-record.md](docs/decision-record.md), Decision 5):

```powershell
$cert = New-SelfSignedCertificate -Subject "CN=DevicesAssessment" `
    -CertStoreLocation "Cert:\CurrentUser\My" -KeyExportPolicy NonExportable `
    -KeySpec Signature -NotAfter (Get-Date).AddYears(2)
$cert.Thumbprint
Export-Certificate -Cert $cert -FilePath "$env:TEMP\DevicesAssessment.cer"
```

Upload the `.cer` to the app registration. Never commit the private key.

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
