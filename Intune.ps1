$out = "C:\estate-audit"
$now = Get-Date

Connect-MgGraph -ClientId $appId -TenantId $tenantId -CertificateThumbprint $thumb -NoWelcome

# ---------- Managed devices ----------
Get-MgDeviceManagementManagedDevice -All | Select-Object `
    @{n='Intune_Id';e={$_.Id}},
    @{n='Intune_DeviceName';e={$_.DeviceName}},
    @{n='Intune_SerialRaw';e={$_.SerialNumber}},
    @{n='Intune_SerialNorm';e={
        $s = $_.SerialNumber
        if ([string]::IsNullOrWhiteSpace($s)) { $null }
        else {
            $s = $s.Trim().ToUpperInvariant() -replace '[\s\-_\.]',''
            $junk = @('TOBEFILLEDBYOEM','SYSTEMSERIALNUMBER','DEFAULTSTRING','CHASSISSERIALNUMBER',
                      'SERIALNUMBER','NONE','NA','NULL','UNKNOWN','INVALID','NOTSPECIFIED','0123456789')
            if ($junk -contains $s -or $s.Length -lt 4 -or $s -match '^(.)\1+$') { $null } else { $s }
        }}},
    @{n='Intune_AadDeviceId';e={ if($_.AzureAdDeviceId){$_.AzureAdDeviceId.ToLower()} }},
    @{n='Intune_AadIdIsEmpty';e={ $_.AzureAdDeviceId -eq '00000000-0000-0000-0000-000000000000' -or [string]::IsNullOrWhiteSpace($_.AzureAdDeviceId) }},
    @{n='Intune_OS';e={$_.OperatingSystem}},
    @{n='Intune_OSVersion';e={$_.OsVersion}},
    @{n='Intune_Manufacturer';e={$_.Manufacturer}},
    @{n='Intune_Model';e={$_.Model}},
    @{n='Intune_ManagementState';e={$_.ManagementState}},
    @{n='Intune_ComplianceState';e={$_.ComplianceState}},
    @{n='Intune_RegistrationState';e={$_.DeviceRegistrationState}},
    @{n='Intune_ManagementAgent';e={$_.ManagementAgent}},
    @{n='Intune_EnrollmentType';e={$_.DeviceEnrollmentType}},
    @{n='Intune_OwnerType';e={$_.ManagedDeviceOwnerType}},
    @{n='Intune_Category';e={$_.DeviceCategoryDisplayName}},
    @{n='Intune_Enrolled';e={ if($_.EnrolledDateTime){$_.EnrolledDateTime.ToString('yyyy-MM-dd')} }},
    @{n='Intune_LastSync';e={ if($_.LastSyncDateTime){$_.LastSyncDateTime.ToString('yyyy-MM-dd HH:mm')} }},
    @{n='Intune_DaysSinceSync';e={ if($_.LastSyncDateTime){[int]($now - $_.LastSyncDateTime).TotalDays} }},
    @{n='Intune_IsEncrypted';e={$_.IsEncrypted}},
    @{n='Intune_IsSupervised';e={$_.IsSupervised}},
    @{n='Intune_UPN';e={$_.UserPrincipalName}},
    @{n='Intune_UserDisplayName';e={$_.UserDisplayName}},
    @{n='Intune_StorageGB';e={ if($_.TotalStorageSpaceInBytes){[math]::Round($_.TotalStorageSpaceInBytes/1GB,1)} }} |
    Export-Csv "$out\03-intune-devices.csv" -NoTypeInformation -Encoding UTF8


# ---------- Autopilot identities ----------
Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -All | Select-Object `
    @{n='AP_Id';e={$_.Id}},
    @{n='AP_SerialRaw';e={$_.SerialNumber}},
    @{n='AP_SerialNorm';e={ if($_.SerialNumber){($_.SerialNumber.Trim().ToUpperInvariant() -replace '[\s\-_\.]','')} }},
    @{n='AP_AadDeviceId';e={ if($_.AzureActiveDirectoryDeviceId){$_.AzureActiveDirectoryDeviceId.ToLower()} }},
    @{n='AP_ManagedDeviceId';e={$_.ManagedDeviceId}},
    @{n='AP_Manufacturer';e={$_.Manufacturer}},
    @{n='AP_Model';e={$_.Model}},
    @{n='AP_GroupTag';e={$_.GroupTag}},
    @{n='AP_EnrollmentState';e={$_.EnrollmentState}},
    @{n='AP_ProfileStatus';e={$_.DeploymentProfileAssignmentStatus}},
    @{n='AP_IsAutopilot';e={$true}} |
    Export-Csv "$out\04-autopilot.csv" -NoTypeInformation -Encoding UTF8


# ---------- BitLocker escrow presence ----------
Get-MgInformationProtectionBitlockerRecoveryKey -All |
    Group-Object DeviceId |
    ForEach-Object {
        [pscustomobject]@{
            BL_DeviceId       = $_.Name.ToLower()
            BL_KeyCount       = $_.Count
            BL_HasEscrowedKey = $true
        }
    } | Export-Csv "$out\05-bitlocker-escrow.csv" -NoTypeInformation -Encoding UTF8