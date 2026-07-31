#Requires -Version 5.1
<#
.SYNOPSIS
    Phase 3 - extracts Intune managed devices, Autopilot identities and
    BitLocker key escrow presence.

.DESCRIPTION
    Read-only. Emits three CSVs plus raw sidecars:

        03-intune-devices.csv      managed devices  (the join hub)
        04-autopilot.csv           Autopilot device identities
        05-bitlocker-escrow.csv    one row per device with escrowed keys

    Three pulls, not one, because these are distinct objects at distinct
    endpoints with their own IDs and lifecycles - Graph does not surface
    Autopilot or BitLocker data on the managedDevice. A single laptop can hold
    five separate records across the estate, and the mismatch between them is
    the finding: an Autopilot registration with no Intune device was bought and
    never deployed; an Autopilot record pointing at a stale managedDeviceId is
    the residue of a reset.

    Intune is the join hub for the whole assessment. It is the only system
    holding both azureADDeviceId (linking up to AD and Entra) and serialNumber
    (linking across to Apple School Manager and Freshservice).

    Column names carry the Graph property name from the managedDevice and
    windowsAutopilotDeviceIdentity resource types.

.NOTES
    Graph application permissions required:
        DeviceManagementManagedDevices.Read.All      managed devices
        DeviceManagementServiceConfig.Read.All       Autopilot identities
        BitlockerKey.ReadBasic.All                   key metadata only

    BitlockerKey.ReadBasic.All returns key IDs and device IDs. It does not
    permit reading recovery keys, and this script never requests them.
#>
[CmdletBinding()]
param(
    [datetime] $SnapshotDate = (Get-Date),

    # Skip individual pulls when re-running a single failed phase.
    [switch] $SkipManagedDevices,
    [switch] $SkipAutopilot,
    [switch] $SkipBitLocker
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'EstateAudit.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'EstateGraph.psm1') -Force

New-EstateSnapshot -Date $SnapshotDate | Out-Null
Write-EstateLog 'Phase 3/4 - Intune, Autopilot, BitLocker'

Connect-EstateGraph -RequiredScope @(
    'DeviceManagementManagedDevices.Read.All'
    'DeviceManagementServiceConfig.Read.All'
    'BitlockerKey.ReadBasic.All'
) | Out-Null

$now = Get-Date

# ---------------------------------------------------------------------------
# Managed devices - the join hub
# ---------------------------------------------------------------------------
if (-not $SkipManagedDevices) {

    $managed = Get-MgDeviceManagementManagedDevice -All -PageSize 500
    Write-EstateLog "Retrieved $($managed.Count) managed devices"

    $managed | Export-EstateRaw -FileName '03-intune-devices.jsonl'

    $managed | ForEach-Object {

        [pscustomobject]@{
            # --- identity ---------------------------------------------------
            Intune_id                        = $_.Id
            Intune_deviceName                = $_.DeviceName
            Intune_managedDeviceName         = $_.ManagedDeviceName
            Intune_serialNumber              = $_.SerialNumber
            Intune_azureADDeviceId           = ConvertTo-EstateGuid $_.AzureAdDeviceId
            Intune_azureADRegistered         = $_.AzureAdRegistered

            # --- management state -------------------------------------------
            Intune_managementState           = $_.ManagementState
            Intune_complianceState           = $_.ComplianceState
            Intune_deviceRegistrationState   = $_.DeviceRegistrationState
            Intune_managementAgent           = $_.ManagementAgent
            Intune_deviceEnrollmentType      = $_.DeviceEnrollmentType
            Intune_managedDeviceOwnerType    = $_.ManagedDeviceOwnerType
            Intune_deviceCategoryDisplayName = $_.DeviceCategoryDisplayName
            Intune_isEncrypted               = $_.IsEncrypted
            Intune_isSupervised              = $_.IsSupervised
            Intune_jailBroken                = $_.JailBroken

            # --- hardware ----------------------------------------------------
            Intune_operatingSystem           = $_.OperatingSystem
            Intune_osVersion                 = $_.OsVersion
            Intune_manufacturer              = $_.Manufacturer
            Intune_model                     = $_.Model
            Intune_imei                      = $_.Imei
            Intune_wiFiMacAddress            = $_.WiFiMacAddress
            Intune_totalStorageSpaceInBytes  = $_.TotalStorageSpaceInBytes
            Intune_freeStorageSpaceInBytes   = $_.FreeStorageSpaceInBytes

            # --- ownership ---------------------------------------------------
            Intune_userId                    = $_.UserId
            Intune_userPrincipalName         = $_.UserPrincipalName
            Intune_userDisplayName           = $_.UserDisplayName
            Intune_emailAddress              = $_.EmailAddress

            # --- timestamps ---------------------------------------------------
            Intune_enrolledDateTime          = Format-EstateDate $_.EnrolledDateTime
            # The most reliable liveness signal in the estate. Where a device
            # exists in Intune, this is the authoritative last-seen value and
            # the AD/Entra timestamps are fallbacks only.
            Intune_lastSyncDateTime          = Format-EstateDate $_.LastSyncDateTime -IncludeTime

            # --- derived -------------------------------------------------------
            Intune_serialNumber_normalized_calc = ConvertTo-EstateSerial $_.SerialNumber
            Intune_serialNumber_isJunk_calc     = ($null -eq (ConvertTo-EstateSerial $_.SerialNumber))
            # All-zero azureADDeviceId: enrolled but never properly registered
            # in Entra. Looks like a valid GUID, joins to nothing.
            Intune_azureADDeviceId_isEmpty_calc = Test-EstateGuidIsEmpty $_.AzureAdDeviceId
            Intune_lastSyncDateTime_days_calc   = Get-EstateDaysSince $_.LastSyncDateTime -Now $now
            Intune_totalStorageSpaceGB_calc     = if ($_.TotalStorageSpaceInBytes) { [math]::Round($_.TotalStorageSpaceInBytes / 1GB, 1) } else { $null }
            # Exchange ActiveSync only - typically personal phones. Decide
            # whether these belong in the device count before comparing totals.
            Intune_isEasOnly_calc               = ($_.ManagementAgent -eq 'eas')
            Intune_snapshotDate_calc            = $SnapshotDate.ToString('yyyy-MM-dd')
        }

    } | Export-EstateCsv -FileName '03-intune-devices.csv' -System 'Intune'
}

# ---------------------------------------------------------------------------
# Autopilot device identities
# ---------------------------------------------------------------------------
if (-not $SkipAutopilot) {

    $autopilot = Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -All
    Write-EstateLog "Retrieved $($autopilot.Count) Autopilot identities"

    $autopilot | Export-EstateRaw -FileName '04-autopilot.jsonl'

    $autopilot | ForEach-Object {

        [pscustomobject]@{
            AP_id                                = $_.Id
            AP_serialNumber                      = $_.SerialNumber
            AP_azureActiveDirectoryDeviceId      = ConvertTo-EstateGuid $_.AzureActiveDirectoryDeviceId
            AP_managedDeviceId                   = $_.ManagedDeviceId
            AP_groupTag                          = $_.GroupTag
            AP_purchaseOrderIdentifier           = $_.PurchaseOrderIdentifier
            AP_manufacturer                      = $_.Manufacturer
            AP_model                             = $_.Model
            AP_systemFamily                      = $_.SystemFamily
            AP_skuNumber                         = $_.SkuNumber
            AP_enrollmentState                   = $_.EnrollmentState
            AP_deploymentProfileAssignmentStatus = $_.DeploymentProfileAssignmentStatus
            AP_deploymentProfileAssignedDateTime = Format-EstateDate $_.DeploymentProfileAssignedDateTime
            AP_lastContactedDateTime             = Format-EstateDate $_.LastContactedDateTime
            AP_userPrincipalName                 = $_.UserPrincipalName

            AP_serialNumber_normalized_calc      = ConvertTo-EstateSerial $_.SerialNumber
            AP_serialNumber_isJunk_calc          = ($null -eq (ConvertTo-EstateSerial $_.SerialNumber))
            # Constant true. Survives the Power Query merge so an anti-join can
            # answer "is this device registered for Autopilot at all?".
            AP_isPresentInAutopilot_calc         = $true
            AP_snapshotDate_calc                 = $SnapshotDate.ToString('yyyy-MM-dd')
        }

    } | Export-EstateCsv -FileName '04-autopilot.csv' -System 'Autopilot'
}

# ---------------------------------------------------------------------------
# BitLocker escrow presence
# ---------------------------------------------------------------------------
if (-not $SkipBitLocker) {

    # Metadata only. Recovery keys themselves are never requested, and
    # BitlockerKey.ReadBasic.All would not return them if they were.
    $keys = Get-MgInformationProtectionBitlockerRecoveryKey -All
    Write-EstateLog "Retrieved $($keys.Count) BitLocker key records"

    $keys | Export-EstateRaw -FileName '05-bitlocker-escrow.jsonl'

    $keys | Group-Object DeviceId | ForEach-Object {

        $created = $_.Group | ForEach-Object { $_.CreatedDateTime } | Where-Object { $_ } | Sort-Object

        [pscustomobject]@{
            BL_deviceId                  = ConvertTo-EstateGuid $_.Name
            BL_keyCount_calc             = $_.Count
            BL_hasEscrowedKey_calc       = $true
            BL_createdDateTime_first_calc = if ($created) { Format-EstateDate $created[0] } else { $null }
            BL_createdDateTime_last_calc  = if ($created) { Format-EstateDate $created[-1] } else { $null }
            BL_volumeType_calc           = (($_.Group | ForEach-Object { $_.VolumeType } | Where-Object { $_ } | Sort-Object -Unique) -join ';')
            BL_snapshotDate_calc         = $SnapshotDate.ToString('yyyy-MM-dd')
        }

    } | Export-EstateCsv -FileName '05-bitlocker-escrow.csv' -System 'BitLocker'
}

Write-EstateLog 'Phase 3 complete.' 'Success'
Write-EstateLog 'Reminder: a Windows device with Intune_isEncrypted = true and no matching BL_deviceId is an encryption recovery gap, not a data error.' 'Warn'
