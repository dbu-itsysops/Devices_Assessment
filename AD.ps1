$out = "C:\estate-audit"
New-Item -ItemType Directory -Path $out -Force | Out-Null
$now = Get-Date

$props = 'DNSHostName','OperatingSystem','OperatingSystemVersion','LastLogonTimeStamp',
         'PasswordLastSet','whenCreated','Enabled','Description','ManagedBy','userCertificate'

Get-ADComputer -Filter * -Properties $props -ResultPageSize 1000 | ForEach-Object {

    $ll = if ($_.LastLogonTimeStamp) { [DateTime]::FromFileTime($_.LastLogonTimeStamp) } else { $null }

    [pscustomobject]@{
        AD_Name            = $_.Name
        AD_ObjectGuid      = $_.ObjectGUID.Guid.ToLower()
        AD_ObjectSid       = $_.SID.Value
        AD_Enabled         = $_.Enabled
        AD_OS              = $_.OperatingSystem
        AD_OSVersion       = $_.OperatingSystemVersion
        AD_LastLogonDate   = if ($ll) { $ll.ToString('yyyy-MM-dd') } else { $null }
        AD_DaysSinceLogon  = if ($ll) { [int]($now - $ll).TotalDays } else { $null }
        AD_FutureTimestamp = if ($ll -and $ll -gt $now) { $true } else { $false }
        AD_PasswordLastSet = if ($_.PasswordLastSet) { $_.PasswordLastSet.ToString('yyyy-MM-dd') } else { $null }
        AD_DaysSincePwdSet = if ($_.PasswordLastSet) { [int]($now - $_.PasswordLastSet).TotalDays } else { $null }
        AD_WhenCreated     = $_.whenCreated.ToString('yyyy-MM-dd')
        AD_OU              = ($_.DistinguishedName -split ',',2)[1]
        AD_Description     = $_.Description
        AD_HasUserCert     = ($null -ne $_.userCertificate -and $_.userCertificate.Count -gt 0)
    }
} | Export-Csv "$out\01-ad-computers.csv" -NoTypeInformation -Encoding UTF8