# Setup

One-time preparation. Once done, a cycle is [runbook.md](runbook.md).

---

## 1. Workstation prerequisites

| Requirement | Check | Install |
|---|---|---|
| PowerShell 5.1 or 7.x | `$PSVersionTable.PSVersion` | 7.x recommended |
| RSAT ActiveDirectory module | `Get-Module -ListAvailable ActiveDirectory` | `Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0` |
| Microsoft Graph SDK | `Get-Module -ListAvailable Microsoft.Graph.Authentication` | `Install-Module Microsoft.Graph -Scope CurrentUser` |
| Line of sight to a domain controller | `Get-ADDomain` | Phase 1 only |

Phases 2–4 need no domain connectivity. Phase 1 needs no internet.

---

## 2. Entra app registration

Certificate authentication, not a client secret — [decision-record.md](decision-record.md), Decision 5.

### 2.1 Create the certificate

Self-signed is fine; this authenticates an app to your own tenant.

```powershell
$cert = New-SelfSignedCertificate `
    -Subject "CN=DevicesAssessment" `
    -CertStoreLocation "Cert:\CurrentUser\My" `
    -KeyExportPolicy NonExportable `
    -KeySpec Signature `
    -NotAfter (Get-Date).AddYears(2)

$cert.Thumbprint
Export-Certificate -Cert $cert -FilePath "$env:TEMP\DevicesAssessment.cer"
```

`NonExportable` is deliberate: the private key stays on the machine that will run
the extracts. Note the thumbprint — it goes into `config.local.ps1`.

The `.cer` is the public half and is safe to upload. Never commit the `.pfx`.

### 2.2 Register the application

Entra admin center → **App registrations** → **New registration**

- Name: `Devices Assessment (read-only)`
- Supported account types: single tenant
- Redirect URI: none

Record the **Application (client) ID** and **Directory (tenant) ID**.

### 2.3 Upload the certificate

**Certificates & secrets** → **Certificates** → **Upload certificate** → the `.cer`
from step 2.1. Do not create a client secret. If one already exists, delete it.

### 2.4 Grant API permissions

**API permissions** → **Add a permission** → **Microsoft Graph** →
**Application permissions**:

| Permission | Covers | Phase |
|---|---|---|
| `Device.Read.All` | Entra device objects | 2 |
| `DeviceManagementManagedDevices.Read.All` | Intune managed devices | 3 |
| `DeviceManagementServiceConfig.Read.All` | Autopilot device identities | 3 |
| `BitlockerKey.ReadBasic.All` | BitLocker key *metadata* only | 3 |

Then **Grant admin consent**. Without consent the extracts return empty rather
than erroring, which reads like an estate finding — the scripts warn on startup
when a required permission is missing, but check the green ticks anyway.

`Directory.Read.All` was rejected as over-scoped. Every permission above is
least-privileged for its endpoint, and all four are read-only.

`BitlockerKey.ReadBasic.All` returns key IDs, device IDs and volume types. It
does **not** permit reading recovery keys.

---

## 3. Freshservice API key

Freshservice → avatar → **Profile Settings** → **API Key**.

The key inherits your own role, so it sees exactly what you see. If your account
is over-permissioned for a read-only extract, use a dedicated read-only agent
account instead.

The key is used as the Basic auth *username* with `X` as the password, per the
Freshservice API v2 specification. The scripts handle that.

---

## 4. Local configuration

```powershell
Copy-Item .\config\config.example.ps1 .\config\config.local.ps1
notepad .\config\config.local.ps1
```

Fill in the five values. `config.local.ps1` is git-ignored — keep it that way.

Then dot-source it in each new session, before running anything:

```powershell
. .\config\config.local.ps1
```

To persist for your user account instead of per-session:

```powershell
[Environment]::SetEnvironmentVariable('ESTATE_GRAPH_APP_ID', '<app-id>', 'User')
[Environment]::SetEnvironmentVariable('ESTATE_GRAPH_TENANT_ID', '<tenant-id>', 'User')
[Environment]::SetEnvironmentVariable('ESTATE_GRAPH_CERT_THUMB', '<thumbprint>', 'User')
[Environment]::SetEnvironmentVariable('FRESHSERVICE_DOMAIN', 'contoso.freshservice.com', 'User')
[Environment]::SetEnvironmentVariable('FRESHSERVICE_API_KEY', '<api-key>', 'User')
```

User-scoped variables are stored in the registry unencrypted and readable by
anything running as you. For a shared or unattended machine, use
`Microsoft.PowerShell.SecretManagement` with a vault instead.

---

## 5. Verify

```powershell
. .\config\config.local.ps1
Import-Module .\src\EstateAudit.psm1
Import-Module .\src\EstateGraph.psm1
Connect-EstateGraph -RequiredScope 'Device.Read.All','DeviceManagementManagedDevices.Read.All'
```

A connection line and no permission warnings means Graph is ready. Then a cheap
end-to-end check of each system:

```powershell
Get-ADComputer -Filter * -ResultSetSize 1 | Select-Object Name
Get-MgDevice -Top 1 | Select-Object DisplayName, DeviceId
Get-MgDeviceManagementManagedDevice -Top 1 | Select-Object DeviceName, SerialNumber

$key = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$env:FRESHSERVICE_API_KEY`:X"))
(Invoke-RestMethod "https://$env:FRESHSERVICE_DOMAIN/api/v2/assets?per_page=1" `
    -Headers @{ Authorization = "Basic $key" }).assets.Count
```

Four results, no errors → run the assessment.
