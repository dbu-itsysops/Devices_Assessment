#Requires -Version 5.1
<#
.SYNOPSIS
    Phase 2 - extracts all Microsoft Entra ID device identities.

.DESCRIPTION
    Read-only. Emits 02-entra-devices.csv plus a complete raw sidecar.

    Column names carry the Graph property name exactly as documented on the
    microsoft.graph.device resource type, so any column can be looked up
    directly in the Graph reference.

    Two traps this extract makes visible rather than hiding:

      * Entra_approximateLastSignInDateTime only updates when the delta exceeds
        14 days, with roughly five days of variance. Nothing under about 21 days
        is a valid staleness signal.
      * The same property returns null for some genuinely active devices. The
        _isNull_calc column exists so those bucket as "unknown" instead of
        being read as "never signed in".

.PARAMETER SnapshotDate
    Snapshot folder to write into. Defaults to today.

.NOTES
    Graph application permission required: Device.Read.All
#>
[CmdletBinding()]
param(
    [datetime] $SnapshotDate = (Get-Date)
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'EstateAudit.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'EstateGraph.psm1') -Force

New-EstateSnapshot -Date $SnapshotDate | Out-Null
Write-EstateLog 'Phase 2/4 - Entra ID'

Connect-EstateGraph -RequiredScope 'Device.Read.All' | Out-Null

$now = Get-Date

# No -Property/$select: the raw sidecar is only complete if Graph returns the
# full default projection.
$devices = Get-MgDevice -All -PageSize 999
Write-EstateLog "Retrieved $($devices.Count) device identities"

$devices | Export-EstateRaw -FileName '02-entra-devices.jsonl'

$devices | ForEach-Object {

    [pscustomobject]@{
        # --- identity -------------------------------------------------------
        Entra_id                             = $_.Id
        Entra_deviceId                       = ConvertTo-EstateGuid $_.DeviceId
        Entra_displayName                    = $_.DisplayName
        Entra_domainName                     = $_.DomainName

        # --- join and management state --------------------------------------
        # trustType determines the cleanup path entirely: a ServerAd device
        # cannot be removed here, because Connect re-creates it from AD.
        Entra_trustType                      = $_.TrustType
        Entra_profileType                    = $_.ProfileType
        Entra_accountEnabled                 = $_.AccountEnabled
        Entra_isManaged                      = $_.IsManaged
        Entra_isCompliant                    = $_.IsCompliant
        Entra_isRooted                       = $_.IsRooted
        Entra_managementType                 = $_.ManagementType
        Entra_mdmAppId                       = $_.MdmAppId
        Entra_deviceOwnership                = $_.DeviceOwnership
        Entra_deviceCategory                 = $_.DeviceCategory
        Entra_enrollmentType                 = $_.EnrollmentType
        Entra_enrollmentProfileName          = $_.EnrollmentProfileName

        # --- hardware -------------------------------------------------------
        Entra_manufacturer                   = $_.Manufacturer
        Entra_model                          = $_.Model
        Entra_operatingSystem                = $_.OperatingSystem
        Entra_operatingSystemVersion         = $_.OperatingSystemVersion

        # --- hybrid linkage --------------------------------------------------
        Entra_onPremisesSyncEnabled          = $_.OnPremisesSyncEnabled
        Entra_onPremisesSecurityIdentifier   = $_.OnPremisesSecurityIdentifier
        Entra_onPremisesLastSyncDateTime     = Format-EstateDate $_.OnPremisesLastSyncDateTime

        # --- timestamps -----------------------------------------------------
        Entra_approximateLastSignInDateTime  = Format-EstateDate $_.ApproximateLastSignInDateTime
        Entra_registrationDateTime           = Format-EstateDate $_.RegistrationDateTime

        # --- derived --------------------------------------------------------
        Entra_approximateLastSignInDateTime_isNull_calc = ($null -eq $_.ApproximateLastSignInDateTime)
        Entra_approximateLastSignInDateTime_days_calc   = Get-EstateDaysSince $_.ApproximateLastSignInDateTime -Now $now
        Entra_trustType_meaning_calc                    = switch ($_.TrustType) {
                                                              'ServerAd'  { 'Hybrid Entra joined (AD is authoritative)' }
                                                              'AzureAd'   { 'Entra joined (cloud only)' }
                                                              'Workplace' { 'Entra registered (personal / BYOD)' }
                                                              default     { $_.TrustType }
                                                          }
        Entra_deviceId_isEmpty_calc                     = Test-EstateGuidIsEmpty $_.DeviceId
        Entra_snapshotDate_calc                         = $SnapshotDate.ToString('yyyy-MM-dd')
    }

} | Export-EstateCsv -FileName '02-entra-devices.csv' -System 'Entra'
