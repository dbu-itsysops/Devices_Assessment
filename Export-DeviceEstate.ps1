#Requires -Version 5.1
<#
.SYNOPSIS
    Extracts computer records from AD, Entra, Intune, Autopilot, BitLocker and
    Freshservice to CSV, ready to load into Excel.

.DESCRIPTION
    Read-only. Nothing here disables, deletes, retires or releases anything.

    Column names are the exact source attribute (LDAP / Graph / Freshservice API)
    prefixed with the system, so every column can be looked up in the vendor's
    own documentation. Anything this script works out itself ends in _calc.

.PARAMETER OutputPath
    Where the CSVs go. Defaults to C:\estate-audit\<today>.

.PARAMETER Phase
    Which systems to pull. Defaults to all of them.

.PARAMETER Server
    Domain controller to query for the AD phase. Defaults to your logon DC.

.PARAMETER GraphAuth
    Interactive  - sign in as yourself in a browser (default).
    Certificate  - app-only, using -AppId / -TenantId / -CertThumbprint.

.EXAMPLE
    .\Export-DeviceEstate.ps1

.EXAMPLE
    .\Export-DeviceEstate.ps1 -Server dc01.dbu.edu -OutputPath D:\audit

.EXAMPLE
    .\Export-DeviceEstate.ps1 -GraphAuth Certificate

.NOTES
    Freshservice credentials come from FRESHSERVICE_DOMAIN and
    FRESHSERVICE_API_KEY (or the matching parameters).

    Graph permissions, same names for delegated and app-only:
        Device.Read.All, DeviceManagementManagedDevices.Read.All,
        DeviceManagementServiceConfig.Read.All, BitlockerKey.ReadBasic.All

    Signing in as yourself needs an Entra role that can read the whole tenant -
    Global Reader is enough. See the BitLocker warning in the Intune phase.
#>
[CmdletBinding()]
param(
    [string] $OutputPath = "C:\estate-audit\$(Get-Date -Format 'yyyy-MM-dd')",

    [ValidateSet('AD', 'Entra', 'Intune', 'Freshservice')]
    [string[]] $Phase = @('AD', 'Entra', 'Intune', 'Freshservice'),

    [string] $Server,

    [ValidateSet('Interactive', 'Certificate')]
    [string] $GraphAuth = 'Interactive',

    [string] $AppId    = $env:ESTATE_GRAPH_APP_ID,
    [string] $TenantId = $env:ESTATE_GRAPH_TENANT_ID,
    [string] $CertThumbprint = $env:ESTATE_GRAPH_CERT_THUMB,
    [string] $FreshserviceDomain = $env:FRESHSERVICE_DOMAIN,
    [string] $FreshserviceApiKey = $env:FRESHSERVICE_API_KEY
)

$ErrorActionPreference = 'Stop'
$now = Get-Date
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

# --- helpers ---------------------------------------------------------------

function Say  { param($Text, $Colour = 'Gray') Write-Host $Text -ForegroundColor $Colour }
function Step { param($Text) Write-Host "`n>> $Text" -ForegroundColor Cyan }

# Lowercase GUIDs: AD returns uppercase, Graph lowercase, and Excel merges are
# case-sensitive. All-zero means "never registered" - treat as absent.
function Norm-Guid {
    param($Value)
    if (-not $Value) { return $null }
    $g = "$Value".Trim().ToLowerInvariant()
    if (-not $g -or $g -eq '00000000-0000-0000-0000-000000000000') { $null } else { $g }
}

# Uppercase, strip separators, null out OEM placeholders. Nulling is deliberate:
# an unmatchable serial should fail to join rather than join to the wrong device.
$JunkSerials = @('TOBEFILLEDBYOEM','SYSTEMSERIALNUMBER','DEFAULTSTRING','CHASSISSERIALNUMBER',
                 'SERIALNUMBER','SERIAL','NONE','NA','N/A','NULL','UNKNOWN','INVALID',
                 'NOTSPECIFIED','NOTAVAILABLE','TBD','0123456789')
function Norm-Serial {
    param($Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $s = "$Value".Trim().ToUpperInvariant() -replace '[\s\-_\.]', ''
    if ($JunkSerials -contains $s -or $s.Length -lt 4 -or $s -match '^(.)\1+$') { $null } else { $s }
}

# Readable top-down OU path: CN=PC1,OU=Laptops,OU=IT,DC=dbu,DC=edu -> "IT \ Laptops"
# Drops the leaf CN and every DC segment, then reverses. Filtering DC= by name
# rather than by a fixed offset keeps this correct whatever the domain depth.
function Friendly-OUPath {
    param($DistinguishedName)
    if (-not $DistinguishedName) { return $null }
    # (?<!\\) so an escaped comma inside a name isn't treated as a separator.
    $segs = @($DistinguishedName -split '(?<!\\),' | Select-Object -Skip 1 | Where-Object { $_ -notmatch '^\s*DC=' })
    if (-not $segs.Count) { return 'Root' }
    [array]::Reverse($segs)
    ($segs -replace '^\s*(OU|CN)=', '' -replace '\\,', ',') -join ' \ '
}

# Graph hands back UTC (DateTimeOffset, or DateTime with Kind=Utc); AD's
# FromFileTime hands back local. Subtracting the two without normalising shifts
# every Graph day-count by the UTC offset, which is why devices that had just
# synced were reporting -1 days. Everything is put on local time here so the
# numbers agree with what the portals show.
function To-Local {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [datetimeoffset]) { return $Value.LocalDateTime }
    $d = [datetime]$Value
    if ($d.Kind -eq [System.DateTimeKind]::Utc) { return $d.ToLocalTime() }
    $d
}

function Fmt-Date {
    param($Value, [switch]$WithTime)
    $d = To-Local $Value
    if (-not $d) { return $null }
    if ($WithTime) { $d.ToString('yyyy-MM-dd HH:mm') } else { $d.ToString('yyyy-MM-dd') }
}

# Floor, not round: something last seen 9.7 days ago is 9 days, not 10.
# Negatives are kept - a future date means DC clock drift, which is a finding.
function Days-Since {
    param($Value)
    $d = To-Local $Value
    if (-not $d) { return $null }
    [int][math]::Floor(($now - $d).TotalDays)
}

function Save {
    param([Parameter(ValueFromPipeline)]$Row, $Name)
    begin { $all = [System.Collections.Generic.List[object]]::new() }
    process { if ($Row) { $all.Add($Row) } }
    end {
        $all | Export-Csv (Join-Path $OutputPath $Name) -NoTypeInformation -Encoding UTF8
        if ($all.Count) { Say "   $($all.Count) rows -> $Name" 'Green' }
        else { Say "   NO ROWS -> $Name  (check permissions before you trust this)" 'Yellow' }
    }
}

$GraphScopes = 'Device.Read.All', 'DeviceManagementManagedDevices.Read.All',
               'DeviceManagementServiceConfig.Read.All', 'BitlockerKey.ReadBasic.All'
$script:GraphConnected = $false

function Connect-Graph {
    if ($script:GraphConnected) { return }
    try { Get-MgContext | Out-Null }
    catch { throw "Microsoft Graph SDK not found. Run: Install-Module Microsoft.Graph -Scope CurrentUser" }

    if ($GraphAuth -eq 'Certificate') {
        if (-not $AppId -or -not $TenantId -or -not $CertThumbprint) {
            throw "-GraphAuth Certificate needs -AppId, -TenantId and -CertThumbprint (or ESTATE_GRAPH_* environment variables)."
        }
        Connect-MgGraph -ClientId $AppId -TenantId $TenantId -CertificateThumbprint $CertThumbprint -NoWelcome
        Say "   signed in as app $AppId"
    }
    else {
        # Signing in as yourself. Delegated access is the intersection of what
        # the app may do and what you may do, so your Entra role decides how
        # much of the tenant comes back.
        $signIn = @{ Scopes = $GraphScopes; NoWelcome = $true }
        if ($TenantId) { $signIn.TenantId = $TenantId }
        Connect-MgGraph @signIn
        $account = (Get-MgContext).Account
        Say "   signed in as $account"
    }
    $script:GraphConnected = $true
}

Say "Device estate extract -> $OutputPath" 'White'
Say "Phases: $($Phase -join ', ')"

# --- 1. Active Directory ---------------------------------------------------

if ($Phase -contains 'AD') {
    Step '[1/4] Active Directory'
    Import-Module ActiveDirectory

    $props = 'DNSHostName','OperatingSystem','OperatingSystemVersion','LastLogonTimeStamp',
             'PasswordLastSet','whenCreated','Description','userCertificate'

    $ad = @{ Filter = '*'; Properties = $props; ResultPageSize = 1000 }
    if ($Server) { $ad.Server = $Server; Say "   querying $Server" }

    Get-ADComputer @ad | ForEach-Object {

        # lastLogonTimestamp is a FILETIME integer, and it only replicates once
        # the stored value is 9-14 days old. pwdLastSet is the better signal.
        $lastLogon = if ($_.LastLogonTimeStamp) { [datetime]::FromFileTime($_.LastLogonTimeStamp) }

        [pscustomobject]@{
            AD_name                   = $_.Name
            AD_dNSHostName            = $_.DNSHostName
            AD_objectGUID             = Norm-Guid $_.ObjectGUID
            AD_objectSid              = $_.SID.Value
            AD_enabled                = $_.Enabled
            AD_operatingSystem        = $_.OperatingSystem
            AD_operatingSystemVersion = $_.OperatingSystemVersion
            AD_lastLogonTimestamp     = Fmt-Date $lastLogon
            AD_pwdLastSet             = Fmt-Date $_.PasswordLastSet
            AD_whenCreated            = Fmt-Date $_.whenCreated
            AD_description            = $_.Description

            AD_lastLogonTimestamp_days_calc     = Days-Since $lastLogon
            AD_lastLogonTimestamp_isFuture_calc = ($lastLogon -and $lastLogon -gt $now)
            AD_pwdLastSet_days_calc             = Days-Since $_.PasswordLastSet
            AD_ou_calc                          = ($_.DistinguishedName -split ',', 2)[1]
            AD_friendlyOUPath_calc              = Friendly-OUPath $_.DistinguishedName
            AD_hasUserCertificate_calc          = ($null -ne $_.userCertificate -and @($_.userCertificate).Count -gt 0)
        }
    } | Save -Name '01-ad-computers.csv'
}

# --- 2. Entra ID -----------------------------------------------------------

if ($Phase -contains 'Entra') {
    Step '[2/4] Entra ID'
    Connect-Graph

    # Explicit $select. onPremisesSecurityIdentifier is NOT in the default
    # projection, and without it the objectSid -> onPremSid path in Decision 4
    # comes back empty, losing the cross-check on the objectGUID join.
    $entraProps = 'id,deviceId,displayName,operatingSystem,operatingSystemVersion,trustType,' +
                  'profileType,accountEnabled,isCompliant,isManaged,managementType,deviceOwnership,' +
                  'approximateLastSignInDateTime,registrationDateTime,onPremisesSyncEnabled,' +
                  'onPremisesSecurityIdentifier'

    Get-MgDevice -All -PageSize 999 -Property $entraProps | ForEach-Object {
        [pscustomobject]@{
            Entra_id                            = $_.Id
            Entra_deviceId                      = Norm-Guid $_.DeviceId
            Entra_displayName                   = $_.DisplayName
            # ServerAd = hybrid (AD is authoritative), AzureAd = cloud joined,
            # Workplace = registered. This decides the cleanup path entirely.
            Entra_trustType                     = $_.TrustType
            Entra_profileType                   = $_.ProfileType
            Entra_operatingSystem               = $_.OperatingSystem
            Entra_operatingSystemVersion        = $_.OperatingSystemVersion
            Entra_accountEnabled                = $_.AccountEnabled
            Entra_isManaged                     = $_.IsManaged
            Entra_isCompliant                   = $_.IsCompliant
            Entra_managementType                = $_.ManagementType
            Entra_deviceOwnership               = $_.DeviceOwnership
            Entra_approximateLastSignInDateTime = Fmt-Date $_.ApproximateLastSignInDateTime
            Entra_registrationDateTime          = Fmt-Date $_.RegistrationDateTime
            Entra_onPremisesSyncEnabled         = $_.OnPremisesSyncEnabled
            Entra_onPremisesSecurityIdentifier  = $_.OnPremisesSecurityIdentifier

            # Null here means "unknown", never "stale" - the property only
            # updates when the delta exceeds ~14 days, and some live devices
            # never populate it at all.
            Entra_approximateLastSignInDateTime_isNull_calc = ($null -eq $_.ApproximateLastSignInDateTime)
            Entra_approximateLastSignInDateTime_days_calc   = Days-Since $_.ApproximateLastSignInDateTime
        }
    } | Save -Name '02-entra-devices.csv'
}

# --- 3. Intune, Autopilot, BitLocker ---------------------------------------

if ($Phase -contains 'Intune') {
    Step '[3/4] Intune managed devices'
    Connect-Graph

    Get-MgDeviceManagementManagedDevice -All -PageSize 500 | ForEach-Object {
        [pscustomobject]@{
            Intune_id                        = $_.Id
            Intune_deviceName                = $_.DeviceName
            Intune_serialNumber              = $_.SerialNumber
            Intune_azureADDeviceId           = Norm-Guid $_.AzureAdDeviceId
            Intune_operatingSystem           = $_.OperatingSystem
            Intune_osVersion                 = $_.OsVersion
            Intune_manufacturer              = $_.Manufacturer
            Intune_model                     = $_.Model
            # managementState is beta-only - it returned empty on every row.
            # complianceState and deviceRegistrationState carry the same signal.
            Intune_complianceState           = $_.ComplianceState
            Intune_deviceRegistrationState   = $_.DeviceRegistrationState
            # 'eas' = Exchange ActiveSync only, usually a personal phone.
            Intune_managementAgent           = $_.ManagementAgent
            Intune_deviceEnrollmentType      = $_.DeviceEnrollmentType
            Intune_managedDeviceOwnerType    = $_.ManagedDeviceOwnerType
            Intune_deviceCategoryDisplayName = $_.DeviceCategoryDisplayName
            Intune_enrolledDateTime          = Fmt-Date $_.EnrolledDateTime
            # Most reliable last-seen value in the estate.
            Intune_lastSyncDateTime          = Fmt-Date $_.LastSyncDateTime -WithTime
            Intune_isEncrypted               = $_.IsEncrypted
            Intune_isSupervised              = $_.IsSupervised
            Intune_userPrincipalName         = $_.UserPrincipalName
            Intune_userDisplayName           = $_.UserDisplayName

            Intune_serialNumber_normalized_calc = Norm-Serial $_.SerialNumber
            # All zeros: enrolled but never registered in Entra. Looks like a
            # valid GUID, joins to nothing.
            Intune_azureADDeviceId_isEmpty_calc = ($null -eq (Norm-Guid $_.AzureAdDeviceId))
            Intune_lastSyncDateTime_days_calc   = Days-Since $_.LastSyncDateTime
            Intune_totalStorageSpaceGB_calc     = if ($_.TotalStorageSpaceInBytes) { [math]::Round($_.TotalStorageSpaceInBytes / 1GB, 1) }
        }
    } | Save -Name '03-intune-devices.csv'

    Say '   Autopilot identities...'
    Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -All | ForEach-Object {
        [pscustomobject]@{
            AP_id                                = $_.Id
            AP_serialNumber                      = $_.SerialNumber
            AP_azureActiveDirectoryDeviceId      = Norm-Guid $_.AzureActiveDirectoryDeviceId
            # Pointing at a device that no longer exists is the residue of a reset.
            AP_managedDeviceId                   = $_.ManagedDeviceId
            AP_manufacturer                      = $_.Manufacturer
            AP_model                             = $_.Model
            AP_groupTag                          = $_.GroupTag
            AP_enrollmentState                   = $_.EnrollmentState
            # deploymentProfileAssignmentStatus is beta-only and came back empty
            # on every row. lastContactedDateTime is on v1.0 and is the useful
            # liveness signal for an Autopilot record anyway.
            AP_lastContactedDateTime             = Fmt-Date $_.LastContactedDateTime

            AP_serialNumber_normalized_calc      = Norm-Serial $_.SerialNumber
            AP_isPresentInAutopilot_calc         = $true
        }
    } | Save -Name '04-autopilot.csv'

    # Metadata only - ReadBasic.All cannot return recovery keys, and we don't ask.
    Say '   BitLocker key escrow...'
    if ($GraphAuth -eq 'Interactive') {
        # Delegated BitLocker access returns ONLY devices you personally own,
        # unless you hold Global reader / Security reader / Cloud device admin /
        # Helpdesk admin / Intune service admin / Security admin. Without one of
        # those this file comes back nearly empty and looks like an estate-wide
        # encryption gap, which it is not.
        Say '   (delegated: needs Global reader or similar, or you only get your own devices)' 'DarkYellow'
    }
    Get-MgInformationProtectionBitlockerRecoveryKey -All | Group-Object DeviceId | ForEach-Object {
        [pscustomobject]@{
            BL_deviceId            = Norm-Guid $_.Name
            BL_keyCount_calc       = $_.Count
            BL_hasEscrowedKey_calc = $true
        }
    } | Save -Name '05-bitlocker-escrow.csv'

    Say '   Note: isEncrypted = true with no BitLocker row is a recovery gap, not a data error.' 'Yellow'
}

# --- 4. Freshservice -------------------------------------------------------

if ($Phase -contains 'Freshservice') {
    Step '[4/4] Freshservice'

    if (-not $FreshserviceDomain -or -not $FreshserviceApiKey) {
        throw "Freshservice credentials missing. Set FRESHSERVICE_DOMAIN and FRESHSERVICE_API_KEY (see README)."
    }

    $fsHeaders = @{
        Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$FreshserviceApiKey`:X"))
    }

    function Get-FsPage {
        param($Path, $Collection)
        $all  = [System.Collections.Generic.List[object]]::new()
        $page = 1
        do {
            $uri = "https://$FreshserviceDomain/api/v2/$Path" + ($(if ($Path -match '\?') { '&' } else { '?' })) + "per_page=100&page=$page"
            $batch = $null
            for ($try = 1; $try -le 5 -and -not $batch; $try++) {
                try { $batch = @((Invoke-RestMethod -Uri $uri -Headers $fsHeaders).$Collection) }
                catch {
                    $status = 0
                    try { $status = [int]$_.Exception.Response.StatusCode } catch { }
                    if ($status -ne 429 -and ($status -lt 500 -or $status -gt 599)) { throw }
                    # Retry-After is a string on PS 5.1 and a typed header on 6+.
                    $wait = 30
                    try { if ($_.Exception.Response.Headers.RetryAfter.Delta) { $wait = [int]$_.Exception.Response.Headers.RetryAfter.Delta.TotalSeconds } }
                    catch { try { $wait = [int]@($_.Exception.Response.Headers['Retry-After'])[0] } catch { } }
                    Say "   rate limited (HTTP $status), waiting ${wait}s" 'DarkYellow'
                    Start-Sleep -Seconds $wait
                }
            }
            foreach ($item in $batch) { $all.Add($item) }
            if ($page % 10 -eq 0) { Say "   page $page ($($all.Count) so far)" 'DarkGray' }
            $page++
            Start-Sleep -Milliseconds 400
        } while ($batch.Count -eq 100)
        $all
    }

    # Match <name> or <name>_<digits>, anchored. A 'starts with' test would let
    # 'os' match os_version, and which one wins depends on property order.
    function Get-FsField {
        param($Fields, $Name, [switch]$ReturnKey)
        if (-not $Fields) { return $null }
        $p = '^' + [regex]::Escape($Name) + '(_\d+)?$'
        $hit = $Fields.PSObject.Properties | Where-Object { $_.Name -match $p } | Select-Object -First 1
        if (-not $hit) { return $null }
        if ($ReturnKey) { $hit.Name } else { $hit.Value }
    }

    Say '   asset types...'
    $types = @{}
    Get-FsPage 'asset_types' 'asset_types' | ForEach-Object { $types["$($_.id)"] = $_ }

    # Full chain to the root - this is what tells you which types are computers.
    function Get-FsTypePath {
        param($Id)
        $names = @()
        while ($Id -and $types.ContainsKey("$Id") -and $names.Count -lt 20) {
            $names = @($types["$Id"].name) + $names
            $Id = $types["$Id"].parent_asset_type_id
        }
        $names -join ' > '
    }

    $types.Values | ForEach-Object {
        [pscustomobject]@{
            FST_id                   = $_.id
            FST_name                 = $_.name
            FST_parent_asset_type_id = $_.parent_asset_type_id
            FST_path_calc            = Get-FsTypePath $_.id
        }
    } | Save -Name '06b-fs-asset-types.csv'

    # No server-side type filter: the API's asset_type_id is exact-match only,
    # so filtering on Computer would silently drop Laptop, Desktop and Server.
    Say '   assets (the slow one)...'
    $assets = Get-FsPage 'assets?include=type_fields' 'assets'

    $assets | ForEach-Object {
        $tf        = $_.type_fields
        $typeId    = "$($_.asset_type_id)"
        $serialRaw = Get-FsField $tf 'serial_number'

        [pscustomobject]@{
            FS_display_id                    = $_.display_id
            FS_id                            = $_.id
            FS_name                          = $_.name
            FS_asset_tag                     = $_.asset_tag
            FS_asset_type_id                 = $_.asset_type_id
            FS_user_id                       = $_.user_id
            FS_department_id                 = $_.department_id
            FS_location_id                   = $_.location_id
            FS_created_at                    = Fmt-Date $_.created_at
            FS_updated_at                    = Fmt-Date $_.updated_at

            'FS_type_fields.serial_number'   = $serialRaw
            'FS_type_fields.asset_state'     = Get-FsField $tf 'asset_state'
            'FS_type_fields.hostname'        = Get-FsField $tf 'hostname'
            'FS_type_fields.os'              = Get-FsField $tf 'os'
            'FS_type_fields.last_login_by'   = Get-FsField $tf 'last_login_by'
            'FS_type_fields.warranty'        = Get-FsField $tf 'warranty'
            'FS_type_fields.acquisition_date' = Get-FsField $tf 'acquisition_date'

            FS_asset_type_name_calc          = $types[$typeId].name
            FS_asset_type_path_calc          = Get-FsTypePath $typeId
            # Exact key as returned. Its numeric suffix is the PARENT asset type
            # id, which is why it can't be the column name.
            FS_serial_number_sourceKey_calc  = Get-FsField $tf 'serial_number' -ReturnKey
            FS_serial_number_normalized_calc = Norm-Serial $serialRaw
            FS_updated_at_days_calc          = Days-Since $_.updated_at
        }
    } | Save -Name '06-freshservice-assets.csv'

    # Every custom field under its exact API key, so nothing is dropped just
    # because this script doesn't know about it.
    $assets | ForEach-Object {
        $a = $_
        if ($a.type_fields) {
            $a.type_fields.PSObject.Properties | ForEach-Object {
                [pscustomobject]@{
                    FS_display_id           = $a.display_id
                    FS_asset_type_id        = $a.asset_type_id
                    FS_type_field_key       = $_.Name
                    FS_type_field_name_calc = ($_.Name -replace '_\d+$', '')
                    FS_type_field_value     = $_.Value
                }
            }
        }
    } | Save -Name '06c-fs-type-fields-long.csv'

    $junk = @($assets | Where-Object { -not (Norm-Serial (Get-FsField $_.type_fields 'serial_number')) }).Count
    Say "   Unusable serials: $junk   (each one is a device that can't be matched)" 'Yellow'
    Say '   Note: assets deleted in Freshservice sit in Trash and are not in this extract.' 'Yellow'
}

# --- done ------------------------------------------------------------------

Step 'Done'
Get-ChildItem $OutputPath -Filter *.csv | ForEach-Object {
    Say ("   {0,-32} {1,6} rows" -f $_.Name, @(Import-Csv $_.FullName).Count)
}
Say "`nCompare these counts against each system's own UI before joining in Excel.`n" 'White'
