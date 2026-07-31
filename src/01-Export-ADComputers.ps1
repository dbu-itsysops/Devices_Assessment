#Requires -Version 5.1
<#
.SYNOPSIS
    Phase 1 - extracts all Active Directory computer objects.

.DESCRIPTION
    Read-only. Emits 01-ad-computers.csv plus a complete raw sidecar.

    Column names carry the LDAP attribute name, not a friendly alias, so every
    value can be traced back to a documented schema attribute. Note that the
    PowerShell property names differ from the LDAP names in two places that
    matter, and the LDAP name wins here:

        Get-ADComputer property      LDAP attribute (column emitted)
        LastLogonTimeStamp     ->    AD_lastLogonTimestamp
        PasswordLastSet        ->    AD_pwdLastSet

    Liveness signal: AD_pwdLastSet is the better one. Domain-joined machines
    rotate their computer account password every 30 days by default, so the
    value moves on a predictable schedule. AD_lastLogonTimestamp replicates only
    once the stored value is already 9-14 days stale, which makes any gap under
    three weeks meaningless - see docs/decision-record.md, section 6.

.PARAMETER Server
    Domain controller to query. Defaults to the logon DC.

.PARAMETER SearchBase
    Optional OU to scope the extract to. Defaults to the whole domain.

.PARAMETER RawProperty
    Attributes to retrieve for the raw sidecar. Defaults to '*' (everything).
    Narrow this on very large domains if the pull is slow.

.EXAMPLE
    .\01-Export-ADComputers.ps1

.NOTES
    Requires the ActiveDirectory module (RSAT). Read access to computer objects
    is sufficient; no write permission is used or needed.
#>
[CmdletBinding()]
param(
    [string]   $Server,
    [string]   $SearchBase,
    [string[]] $RawProperty = '*',
    [datetime] $SnapshotDate = (Get-Date)
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'EstateAudit.psm1') -Force

if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    throw "The ActiveDirectory module is not available. Install RSAT: " +
          "Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0"
}
Import-Module ActiveDirectory

New-EstateSnapshot -Date $SnapshotDate | Out-Null
Write-EstateLog 'Phase 1/4 - Active Directory'

$now = Get-Date

$query = @{
    Filter         = '*'
    Properties     = $RawProperty
    ResultPageSize = 1000
}
if ($Server)     { $query.Server     = $Server }
if ($SearchBase) { $query.SearchBase = $SearchBase }

$computers = Get-ADComputer @query
Write-EstateLog "Retrieved $($computers.Count) computer objects"

# Raw sidecar first: if the curation below has a bug, the source data survives.
$computers |
    Select-Object -Property * -ExcludeProperty PropertyNames, PropertyCount,
                                               AddedProperties, RemovedProperties, ModifiedProperties |
    Export-EstateRaw -FileName '01-ad-computers.jsonl'

$computers | ForEach-Object {

    # lastLogonTimestamp is stored as a Windows FILETIME integer, not a date.
    $lastLogon = $null
    if ($_.LastLogonTimeStamp) {
        $lastLogon = [DateTime]::FromFileTime($_.LastLogonTimeStamp)
    }

    $certCount = 0
    if ($null -ne $_.userCertificate) { $certCount = @($_.userCertificate).Count }

    [pscustomobject]@{
        # --- identity -------------------------------------------------------
        AD_name                        = $_.Name
        AD_sAMAccountName              = $_.SamAccountName
        AD_dNSHostName                 = $_.DNSHostName
        AD_objectGUID                  = ConvertTo-EstateGuid $_.ObjectGUID
        AD_objectSid                   = $_.SID.Value
        AD_distinguishedName           = $_.DistinguishedName

        # --- state ----------------------------------------------------------
        AD_enabled                     = $_.Enabled
        AD_userAccountControl          = $_.userAccountControl
        AD_operatingSystem             = $_.OperatingSystem
        AD_operatingSystemVersion      = $_.OperatingSystemVersion
        AD_description                 = $_.Description
        AD_managedBy                   = $_.ManagedBy

        # --- timestamps -----------------------------------------------------
        AD_lastLogonTimestamp          = Format-EstateDate $lastLogon
        AD_pwdLastSet                  = Format-EstateDate $_.PasswordLastSet
        AD_whenCreated                 = Format-EstateDate $_.whenCreated
        AD_whenChanged                 = Format-EstateDate $_.whenChanged

        # --- derived --------------------------------------------------------
        AD_lastLogonTimestamp_days_calc     = Get-EstateDaysSince $lastLogon -Now $now
        # Future-dated means DC clock drift, not device activity. Surfaced, never clamped.
        AD_lastLogonTimestamp_isFuture_calc = ($null -ne $lastLogon -and $lastLogon -gt $now)
        AD_pwdLastSet_days_calc             = Get-EstateDaysSince $_.PasswordLastSet -Now $now
        AD_ou_calc                          = ($_.DistinguishedName -split ',', 2)[1]
        # A populated userCertificate is the strongest on-prem indicator that a
        # device has completed hybrid Entra join.
        AD_userCertificate_count_calc       = $certCount
        AD_hasUserCertificate_calc          = ($certCount -gt 0)
        AD_snapshotDate_calc                = $SnapshotDate.ToString('yyyy-MM-dd')
    }

} | Export-EstateCsv -FileName '01-ad-computers.csv' -System 'AD'
