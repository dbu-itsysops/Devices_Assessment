$out      = "C:\estate-audit"
$fsDomain = "dbu.freshservice.com"
$apiKey   = "<your-api-key>"
$now      = Get-Date

$headers = @{ Authorization = "Basic " + [Convert]::ToBase64String(
                [Text.Encoding]::ASCII.GetBytes("$apiKey`:X")) }

function Invoke-Fs {
    param([string]$Uri)
    for ($i = 0; $i -lt 5; $i++) {
        try { return Invoke-RestMethod -Uri $Uri -Headers $headers -Method GET }
        catch {
            if ($_.Exception.Response.StatusCode.value__ -eq 429) {
                $wait = [int]$_.Exception.Response.Headers['Retry-After']
                if (-not $wait) { $wait = 30 }
                Write-Host "  rate limited, waiting $wait s..." -ForegroundColor DarkYellow
                Start-Sleep -Seconds $wait
            } else { throw }
        }
    }
    throw "Failed after retries: $Uri"
}

function Get-TypeField {
    param($Fields, [string]$Prefix)
    if ($null -eq $Fields) { return $null }
    ($Fields.PSObject.Properties | Where-Object { $_.Name -like "$Prefix*" } | Select-Object -First 1).Value
}

# ---------- Asset types (build the hierarchy map) ----------
$types = @{}
$p = 1
do {
    $r = Invoke-Fs "https://$fsDomain/api/v2/asset_types?per_page=100&page=$p"
    foreach ($t in $r.asset_types) {
        $types[[string]$t.id] = [pscustomobject]@{
            Name     = $t.name
            ParentId = $t.parent_asset_type_id
        }
    }
    $p++
} while ($r.asset_types.Count -eq 100)

$types.GetEnumerator() | ForEach-Object {
    [pscustomobject]@{
        FST_Id       = $_.Key
        FST_Name     = $_.Value.Name
        FST_ParentId = $_.Value.ParentId
        FST_Parent   = if ($_.Value.ParentId) { $types[[string]$_.Value.ParentId].Name }
    }
} | Export-Csv "$out\06b-fs-asset-types.csv" -NoTypeInformation -Encoding UTF8

Write-Host "Mapped $($types.Count) asset types."

# ---------- Assets ----------
$raw = @()
$p = 1
do {
    $r = Invoke-Fs "https://$fsDomain/api/v2/assets?include=type_fields&per_page=100&page=$p"
    $raw += $r.assets
    if ($p % 10 -eq 0) { Write-Host "  page $p ($($raw.Count) assets)" -ForegroundColor DarkGray }
    $p++
    Start-Sleep -Milliseconds 400
} while ($r.assets.Count -eq 100)

$assets = $raw | ForEach-Object {
    $serialRaw = Get-TypeField $_.type_fields 'serial_number'

    $serialNorm = if ([string]::IsNullOrWhiteSpace($serialRaw)) { $null } else {
        $s = $serialRaw.Trim().ToUpperInvariant() -replace '[\s\-_\.]',''
        $junk = @('TOBEFILLEDBYOEM','SYSTEMSERIALNUMBER','DEFAULTSTRING','CHASSISSERIALNUMBER',
                  'SERIALNUMBER','NONE','NA','NULL','UNKNOWN','INVALID','NOTSPECIFIED','0123456789')
        if ($junk -contains $s -or $s.Length -lt 4 -or $s -match '^(.)\1+$') { $null } else { $s }
    }

    $tid = [string]$_.asset_type_id

    [pscustomobject]@{
        FS_DisplayId       = $_.display_id
        FS_Id              = $_.id
        FS_Name            = $_.name
        FS_AssetTag        = $_.asset_tag
        FS_AssetTypeId     = $_.asset_type_id
        FS_AssetTypeName   = $types[$tid].Name
        FS_AssetTypeParent = if ($types[$tid].ParentId) { $types[[string]$types[$tid].ParentId].Name }
        FS_SerialRaw       = $serialRaw
        FS_SerialNorm      = $serialNorm
        FS_SerialIsJunk    = ($null -eq $serialNorm)
        FS_AssetState      = Get-TypeField $_.type_fields 'asset_state'
        FS_Hostname        = Get-TypeField $_.type_fields 'hostname'
        FS_OS              = Get-TypeField $_.type_fields 'os'
        FS_LastLoginBy     = Get-TypeField $_.type_fields 'last_login_by'
        FS_Warranty        = Get-TypeField $_.type_fields 'warranty'
        FS_AcquisitionDate = Get-TypeField $_.type_fields 'acquisition_date'
        FS_UserId          = $_.user_id
        FS_DepartmentId    = $_.department_id
        FS_LocationId      = $_.location_id
        FS_AgentId         = $_.agent_id
        FS_CreatedAt       = if ($_.created_at) { ([datetime]$_.created_at).ToString('yyyy-MM-dd') }
        FS_UpdatedAt       = if ($_.updated_at) { ([datetime]$_.updated_at).ToString('yyyy-MM-dd') }
        FS_DaysSinceUpdate = if ($_.updated_at) { [int]($now - [datetime]$_.updated_at).TotalDays }
    }
}

$assets | Export-Csv "$out\06-freshservice-assets.csv" -NoTypeInformation -Encoding UTF8
Write-Host "$($assets.Count) assets exported."

# ---------- Quick findings ----------
Write-Host "`nBy asset type:" -ForegroundColor Cyan
$assets | Group-Object FS_AssetTypeName | Sort-Object Count -Descending |
    Select-Object Count, Name -First 15 | Format-Table -AutoSize

Write-Host "Junk/blank serials: $(($assets | Where-Object FS_SerialIsJunk).Count)" -ForegroundColor Yellow

$dupes = $assets | Where-Object FS_SerialNorm | Group-Object FS_SerialNorm | Where-Object Count -gt 1
Write-Host "Duplicate serials: $($dupes.Count)" -ForegroundColor Yellow
$dupes | Select-Object -First 10 Name, Count | Format-Table -AutoSize