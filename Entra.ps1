Connect-MgGraph -ClientId $appId -TenantId $tenantId -CertificateThumbprint $thumb -NoWelcome

Get-MgDevice -All -Property "id,deviceId,displayName,operatingSystem,operatingSystemVersion,trustType,profileType,accountEnabled,isCompliant,isManaged,managementType,deviceOwnership,approximateLastSignInDateTime,registrationDateTime,onPremisesSyncEnabled,onPremisesSecurityIdentifier" |
Select-Object `
    @{n='Entra_ObjectId';e={$_.Id}},
    @{n='Entra_DeviceId';e={$_.DeviceId.ToLower()}},
    @{n='Entra_DisplayName';e={$_.DisplayName}},
    @{n='Entra_TrustType';e={$_.TrustType}},
    @{n='Entra_OS';e={$_.OperatingSystem}},
    @{n='Entra_OSVersion';e={$_.OperatingSystemVersion}},
    @{n='Entra_Enabled';e={$_.AccountEnabled}},
    @{n='Entra_IsManaged';e={$_.IsManaged}},
    @{n='Entra_MgmtType';e={$_.ManagementType}},
    @{n='Entra_IsCompliant';e={$_.IsCompliant}},
    @{n='Entra_ProfileType';e={$_.ProfileType}},
    @{n='Entra_Ownership';e={$_.DeviceOwnership}},
    @{n='Entra_LastSignIn';e={if($_.ApproximateLastSignInDateTime){$_.ApproximateLastSignInDateTime.ToString('yyyy-MM-dd')}}},
    @{n='Entra_SignInIsNull';e={$null -eq $_.ApproximateLastSignInDateTime}},
    @{n='Entra_DaysSinceSignIn';e={if($_.ApproximateLastSignInDateTime){[int]((Get-Date)-$_.ApproximateLastSignInDateTime).TotalDays}}},
    @{n='Entra_Registered';e={if($_.RegistrationDateTime){$_.RegistrationDateTime.ToString('yyyy-MM-dd')}}},
    @{n='Entra_OnPremSync';e={$_.OnPremisesSyncEnabled}},
    @{n='Entra_OnPremSid';e={$_.OnPremisesSecurityIdentifier}} |
Export-Csv "C:\estate-audit\02-entra-devices.csv" -NoTypeInformation -Encoding UTF8