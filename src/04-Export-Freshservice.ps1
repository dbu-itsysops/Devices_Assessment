#Requires -Version 5.1
<#
.SYNOPSIS
    Phase 4 - extracts Freshservice assets and the asset type hierarchy.

.DESCRIPTION
    Read-only. Emits three CSVs plus raw sidecars:

        06-freshservice-assets.csv        one row per asset, curated
        06b-fs-asset-types.csv            the asset type hierarchy
        06c-fs-type-fields-long.csv       every custom field, long format

    No server-side asset type filter. The Freshservice UI's "Choose from
    Hierarchy" includes child asset types, but the API's asset_type_id filter is
    exact match only - filtering on Computer server-side would silently drop
    Laptop, Desktop, Server and every other sub-type. Everything is pulled and
    filtered in Excel instead. Comparing the full API count against the UI count
    is also the first sanity check of the whole assessment.

    ATTRIBUTE NAMES ARE PRESERVED. Freshservice returns custom fields under keys
    whose numeric suffix is the *parent* asset type ID, not the asset's own type
    - serial_number_1234, asset_state_1234. Three things follow from that:

      1. Curated columns are named after the API attribute with the volatile
         numeric suffix removed: FS_type_fields.serial_number. Stable across
         asset types, still traceable to the API response.
      2. The exact key as returned, suffix included, is kept beside it in a
         _sourceKey_calc column, so the parent asset type is never lost.
      3. 06c-fs-type-fields-long.csv carries EVERY custom field under its exact
         key, whether or not this script knows about it. Nothing is discarded.

    Matching is by attribute name with an optional numeric suffix, anchored at
    both ends - not by a "starts with" test. A prefix test for 'os' also matches
    os_version and os_service_pack, and which one wins depends on property
    ordering, which is a silent wrong-value bug.

.PARAMETER Domain
    Freshservice domain, e.g. contoso.freshservice.com.
    Defaults to $env:FRESHSERVICE_DOMAIN.

.NOTES
    Requires $env:FRESHSERVICE_API_KEY. See docs/setup.md.
    The API key is used as the Basic auth username with 'X' as the password,
    per the Freshservice API v2 specification.
#>
[CmdletBinding()]
param(
    [string]   $Domain = $env:FRESHSERVICE_DOMAIN,
    [datetime] $SnapshotDate = (Get-Date),
    [int]      $PageSize = 100,
    [int]      $ThrottleMs = 400,
    [int]      $MaxPage = 1000
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'EstateAudit.psm1') -Force

New-EstateSnapshot -Date $SnapshotDate | Out-Null
Write-EstateLog 'Phase 4/4 - Freshservice'

if ([string]::IsNullOrWhiteSpace($Domain)) {
    throw "Freshservice domain not set. Pass -Domain, or set `$env:FRESHSERVICE_DOMAIN (e.g. contoso.freshservice.com)."
}

$apiKey  = Get-EstateSecret 'FRESHSERVICE_API_KEY' -Purpose 'Freshservice API v2 key'
$headers = @{
    Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$apiKey`:X"))
    Accept        = 'application/json'
}

$now = Get-Date

# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

function Get-RetryAfterSeconds {
    <#
        Retry-After is exposed differently by the two PowerShell HTTP stacks:
        WebResponse (5.1) has a string header, HttpResponseMessage (6+) has a
        typed RetryConditionHeaderValue. Neither indexing style works on both.
    #>
    param($Response)

    $default = 30
    if ($null -eq $Response) { return $default }

    try {
        $retryAfter = $Response.Headers.RetryAfter
        if ($retryAfter -and $retryAfter.Delta) { return [int]$retryAfter.Delta.TotalSeconds }
    } catch { }

    try {
        $raw = $Response.Headers['Retry-After']
        if ($raw) {
            $value = @($raw)[0]
            $parsed = 0
            if ([int]::TryParse([string]$value, [ref]$parsed) -and $parsed -gt 0) { return $parsed }
        }
    } catch { }

    $default
}

function Invoke-Fs {
    <#
        GET with retry on 429 and transient 5xx. Anything else throws
        immediately with the API's own error body attached, because a 401 or a
        403 should stop the run rather than be retried five times.
    #>
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [int] $MaxAttempt = 5
    )

    for ($attempt = 1; $attempt -le $MaxAttempt; $attempt++) {
        try {
            return Invoke-RestMethod -Uri $Uri -Headers $headers -Method GET
        }
        catch {
            $response = $null
            try { $response = $_.Exception.Response } catch { }

            $status = 0
            if ($response) { try { $status = [int]$response.StatusCode } catch { } }

            if ($status -eq 429 -or ($status -ge 500 -and $status -le 599)) {
                if ($attempt -eq $MaxAttempt) { throw "Gave up after $MaxAttempt attempts (HTTP $status): $Uri" }
                $wait = Get-RetryAfterSeconds $response
                Write-EstateLog "HTTP $status - waiting ${wait}s then retrying (attempt $attempt/$MaxAttempt)" 'Warn'
                Start-Sleep -Seconds $wait
                continue
            }

            $detail = ''
            try { if ($_.ErrorDetails.Message) { $detail = " - $($_.ErrorDetails.Message)" } } catch { }
            throw "Freshservice request failed (HTTP $status)$detail`nURI: $Uri"
        }
    }
}

function Get-FsPagedResult {
    <#
        Walks a paged v2 collection endpoint and returns every record.
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Collection,
        [string] $Query = ''
    )

    $all  = [System.Collections.Generic.List[object]]::new()
    $page = 1

    do {
        $uri    = "https://$Domain/api/v2/$Path" + "?per_page=$PageSize&page=$page" + $Query
        $result = Invoke-Fs $uri
        $batch  = @($result.$Collection)

        foreach ($item in $batch) { $all.Add($item) }

        if ($page % 10 -eq 0) { Write-EstateLog "  $Collection - page $page ($($all.Count) records)" }

        $page++
        if ($ThrottleMs -gt 0) { Start-Sleep -Milliseconds $ThrottleMs }

        if ($page -gt $MaxPage) {
            Write-EstateLog "Stopped at the -MaxPage limit of $MaxPage. The extract is INCOMPLETE; raise -MaxPage and re-run." 'Warn'
            break
        }
    } while ($batch.Count -eq $PageSize)

    $all
}

# ---------------------------------------------------------------------------
# type_fields helpers
# ---------------------------------------------------------------------------

function Get-FsTypeFieldKey {
    <#
        Returns the exact key for an attribute, suffix included, or $null.
        Anchored match on <name> or <name>_<digits> only.
    #>
    param($TypeFields, [string] $Name)

    if ($null -eq $TypeFields) { return $null }
    $pattern = '^' + [regex]::Escape($Name) + '(_\d+)?$'

    $match = $TypeFields.PSObject.Properties |
             Where-Object { $_.Name -match $pattern } |
             Select-Object -First 1

    if ($match) { $match.Name } else { $null }
}

function Get-FsTypeFieldValue {
    param($TypeFields, [string] $Name)

    $key = Get-FsTypeFieldKey $TypeFields $Name
    if ($null -eq $key) { return $null }
    $TypeFields.$key
}

# ---------------------------------------------------------------------------
# Asset types
# ---------------------------------------------------------------------------

Write-EstateLog 'Fetching asset type hierarchy...'
$assetTypes = Get-FsPagedResult -Path 'asset_types' -Collection 'asset_types'
$assetTypes | Export-EstateRaw -FileName '06b-fs-asset-types.jsonl'

$typeById = @{}
foreach ($type in $assetTypes) { $typeById[[string]$type.id] = $type }

function Get-FsTypePath {
    <#
        Walks parent_asset_type_id up to the root, returning "Hardware > Computer
        > Laptop". This is what answers the open question of which asset types
        actually count as computers.
    #>
    param([string] $Id)

    $names = [System.Collections.Generic.List[string]]::new()
    $guard = 0

    while ($Id -and $typeById.ContainsKey($Id) -and $guard -lt 20) {
        $names.Insert(0, $typeById[$Id].name)
        $parent = $typeById[$Id].parent_asset_type_id
        if (-not $parent) { break }
        $Id = [string]$parent
        $guard++
    }

    $names -join ' > '
}

$assetTypes | ForEach-Object {
    $parentId = if ($_.parent_asset_type_id) { [string]$_.parent_asset_type_id } else { $null }

    [pscustomobject]@{
        FST_id                     = $_.id
        FST_name                   = $_.name
        FST_description            = $_.description
        FST_parent_asset_type_id   = $_.parent_asset_type_id
        FST_visible                = $_.visible
        FST_created_at             = Format-EstateDate $_.created_at
        FST_updated_at             = Format-EstateDate $_.updated_at

        FST_parent_name_calc       = if ($parentId -and $typeById.ContainsKey($parentId)) { $typeById[$parentId].name } else { $null }
        FST_path_calc              = Get-FsTypePath ([string]$_.id)
        FST_snapshotDate_calc      = $SnapshotDate.ToString('yyyy-MM-dd')
    }
} | Export-EstateCsv -FileName '06b-fs-asset-types.csv' -System 'Freshservice'

# ---------------------------------------------------------------------------
# Assets
# ---------------------------------------------------------------------------

Write-EstateLog 'Fetching assets (this is the slow one)...'
$assets = Get-FsPagedResult -Path 'assets' -Collection 'assets' -Query '&include=type_fields'
Write-EstateLog "Retrieved $($assets.Count) assets"

$assets | Export-EstateRaw -FileName '06-freshservice-assets.jsonl'

# --- curated ---------------------------------------------------------------

$assets | ForEach-Object {

    $typeFields = $_.type_fields
    $typeId     = [string]$_.asset_type_id

    $serialKey = Get-FsTypeFieldKey   $typeFields 'serial_number'
    $serialRaw = Get-FsTypeFieldValue $typeFields 'serial_number'
    $parentId  = if ($typeById.ContainsKey($typeId) -and $typeById[$typeId].parent_asset_type_id) {
                     [string]$typeById[$typeId].parent_asset_type_id
                 } else { $null }

    [pscustomobject]@{
        # --- top-level asset attributes (exact API names) -------------------
        FS_display_id                      = $_.display_id
        FS_id                              = $_.id
        FS_name                            = $_.name
        FS_description                     = $_.description
        FS_asset_tag                       = $_.asset_tag
        FS_asset_type_id                   = $_.asset_type_id
        FS_impact                          = $_.impact
        FS_usage_type                      = $_.usage_type
        FS_user_id                         = $_.user_id
        FS_department_id                   = $_.department_id
        FS_location_id                     = $_.location_id
        FS_agent_id                        = $_.agent_id
        FS_group_id                        = $_.group_id
        FS_assigned_on                     = Format-EstateDate $_.assigned_on
        FS_created_at                      = Format-EstateDate $_.created_at
        FS_updated_at                      = Format-EstateDate $_.updated_at

        # --- type_fields (numeric suffix stripped, exact key kept below) ----
        'FS_type_fields.serial_number'     = $serialRaw
        'FS_type_fields.asset_state'       = Get-FsTypeFieldValue $typeFields 'asset_state'
        'FS_type_fields.hostname'          = Get-FsTypeFieldValue $typeFields 'hostname'
        'FS_type_fields.os'                = Get-FsTypeFieldValue $typeFields 'os'
        'FS_type_fields.os_version'        = Get-FsTypeFieldValue $typeFields 'os_version'
        'FS_type_fields.last_login_by'     = Get-FsTypeFieldValue $typeFields 'last_login_by'
        'FS_type_fields.warranty'          = Get-FsTypeFieldValue $typeFields 'warranty'
        'FS_type_fields.warranty_expiry_date' = Get-FsTypeFieldValue $typeFields 'warranty_expiry_date'
        'FS_type_fields.acquisition_date'  = Get-FsTypeFieldValue $typeFields 'acquisition_date'
        'FS_type_fields.product'           = Get-FsTypeFieldValue $typeFields 'product'
        'FS_type_fields.vendor'            = Get-FsTypeFieldValue $typeFields 'vendor'

        # --- derived --------------------------------------------------------
        FS_asset_type_name_calc            = if ($typeById.ContainsKey($typeId)) { $typeById[$typeId].name } else { $null }
        FS_asset_type_parent_calc          = if ($parentId -and $typeById.ContainsKey($parentId)) { $typeById[$parentId].name } else { $null }
        FS_asset_type_path_calc            = Get-FsTypePath $typeId
        # The exact key as returned. Its numeric suffix is the parent asset
        # type ID - useful provenance, useless as a stable column name.
        FS_serial_number_sourceKey_calc    = $serialKey
        FS_serial_number_normalized_calc   = ConvertTo-EstateSerial $serialRaw
        FS_serial_number_isJunk_calc       = ($null -eq (ConvertTo-EstateSerial $serialRaw))
        FS_updated_at_days_calc            = Get-EstateDaysSince $_.updated_at -Now $now
        FS_snapshotDate_calc               = $SnapshotDate.ToString('yyyy-MM-dd')
    }

} | Export-EstateCsv -FileName '06-freshservice-assets.csv' -System 'Freshservice'

# --- every type_field, long format -----------------------------------------
# One row per asset per custom field, under its exact API key. This is the file
# that guarantees no attribute is lost regardless of asset type or future
# customisation. Unpivot it in Power Query if a field earns a column.

$assets | ForEach-Object {
    $asset = $_
    if ($null -eq $asset.type_fields) { return }

    $asset.type_fields.PSObject.Properties | ForEach-Object {
        [pscustomobject]@{
            FS_display_id            = $asset.display_id
            FS_id                    = $asset.id
            FS_asset_type_id         = $asset.asset_type_id
            FS_type_field_key        = $_.Name
            FS_type_field_name_calc  = ($_.Name -replace '_\d+$', '')
            FS_type_field_value      = $_.Value
            FS_type_field_isEmpty_calc = [string]::IsNullOrWhiteSpace([string]$_.Value)
        }
    }
} | Export-EstateCsv -FileName '06c-fs-type-fields-long.csv' -System 'Freshservice'

# ---------------------------------------------------------------------------
# Baseline counts - the open item that has to close before joining
# ---------------------------------------------------------------------------

Write-EstateLog ''
Write-EstateLog 'Asset counts by type (compare against the Freshservice UI before joining):'
$assets |
    Group-Object asset_type_id |
    Sort-Object Count -Descending |
    Select-Object -First 20 @{n = 'Count'; e = { $_.Count }},
                            @{n = 'AssetType'; e = { Get-FsTypePath ([string]$_.Name) }} |
    Format-Table -AutoSize |
    Out-String -Width 200 |
    Write-Host

$junkCount = @($assets | Where-Object { $null -eq (ConvertTo-EstateSerial (Get-FsTypeFieldValue $_.type_fields 'serial_number')) }).Count
Write-EstateLog "Unusable serials (blank or OEM placeholder): $junkCount" 'Warn'

$duplicates = $assets |
    ForEach-Object { ConvertTo-EstateSerial (Get-FsTypeFieldValue $_.type_fields 'serial_number') } |
    Where-Object { $_ } |
    Group-Object |
    Where-Object { $_.Count -gt 1 }
Write-EstateLog "Serials appearing on more than one asset: $(@($duplicates).Count)" 'Warn'

Write-EstateLog 'Reminder: assets deleted in Freshservice sit in Trash and are absent from this extract.' 'Warn'
Write-EstateLog 'Phase 4 complete.' 'Success'
