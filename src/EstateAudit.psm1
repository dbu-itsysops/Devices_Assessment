#Requires -Version 5.1
<#
.SYNOPSIS
    Shared helpers for the device estate assessment extractors.

.DESCRIPTION
    Every extractor in this repository depends on this module for the four things
    that must behave identically across all five systems, because the Power Query
    joins are unforgiving:

      * snapshot folder layout        (one dated, immutable folder per run)
      * GUID normalization            (lowercase, or merges silently return zero rows)
      * serial normalization          (uppercase, separators stripped, OEM junk nulled)
      * CSV writing + run manifest    (encoding, row counts, provenance)

    Naming convention for emitted columns:

      <Prefix>_<exactSourceAttributeName>        value as the source system returns it
      <Prefix>_<name>_calc                       derived by this tooling, not a source field

    The "_calc" suffix is load-bearing. It is how you tell, six months from now,
    whether a column can be looked up in vendor documentation or whether it came
    from a decision made here.
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Placeholder serials written by OEMs into SMBIOS when the field was never
# populated. Each one is a device that cannot be matched on hardware identity,
# which is a finding in its own right - see docs/decision-record.md, Conventions.
$script:JunkSerials = @(
    'TOBEFILLEDBYOEM', 'TOBEFILLEDBYO.E.M.', 'SYSTEMSERIALNUMBER', 'DEFAULTSTRING',
    'CHASSISSERIALNUMBER', 'BASEBOARDSERIALNUMBER', 'SERIALNUMBER', 'SERIAL',
    'NONE', 'NA', 'N/A', 'NULL', 'UNKNOWN', 'INVALID', 'NOTSPECIFIED',
    'NOTAPPLICABLE', 'NOTAVAILABLE', 'TBD', 'ASSETTAG', '0123456789'
)

$script:EmptyGuid = '00000000-0000-0000-0000-000000000000'

# Populated by New-EstateSnapshot, consumed by Export-EstateCsv.
$script:Snapshot = $null

# ---------------------------------------------------------------------------
# Snapshot management
# ---------------------------------------------------------------------------

function New-EstateSnapshot {
    <#
    .SYNOPSIS
        Creates (or reuses) the dated snapshot folder for this extraction cycle.

    .DESCRIPTION
        Layout:

            <Root>\<yyyy-MM-dd>\
                raw\                    full untouched source responses (.jsonl)
                NN-<system>.csv         curated, analysis-ready extracts
                _manifest.csv           one row per emitted file: rows, timestamp
                _run.log                console transcript for the cycle

        Raw CSVs are immutable by convention: all transformation happens in
        Power Query, so a suspect number can always be traced to either the
        data or the logic.

    .PARAMETER Root
        Base folder for all snapshots. Defaults to C:\estate-audit.

    .PARAMETER Date
        Snapshot date. Defaults to today. Pass an explicit date to append to an
        earlier snapshot (for example when re-running a single failed phase).
    #>
    [CmdletBinding()]
    param(
        [string]   $Root = $(if ($env:ESTATE_AUDIT_ROOT) { $env:ESTATE_AUDIT_ROOT } else { 'C:\estate-audit' }),
        [datetime] $Date = (Get-Date)
    )

    $path    = Join-Path $Root $Date.ToString('yyyy-MM-dd')
    $rawPath = Join-Path $path 'raw'

    New-Item -ItemType Directory -Path $rawPath -Force | Out-Null

    $script:Snapshot = [pscustomobject]@{
        Root        = $Root
        Path        = $path
        RawPath     = $rawPath
        Manifest    = Join-Path $path '_manifest.csv'
        LogFile     = Join-Path $path '_run.log'
        Date        = $Date
        StartedAt   = Get-Date
    }

    Write-EstateLog "Snapshot folder: $path"
    $script:Snapshot
}

function Get-EstateSnapshot {
    <#
    .SYNOPSIS
        Returns the active snapshot, creating a default one if none exists yet.
    #>
    [CmdletBinding()]
    param()

    if ($null -eq $script:Snapshot) { return New-EstateSnapshot }
    $script:Snapshot
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

function Write-EstateLog {
    <#
    .SYNOPSIS
        Writes a timestamped line to the console and, once a snapshot exists,
        to the snapshot's _run.log.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string] $Message,

        # Positional: every call site passes the level as the second argument.
        [Parameter(Position = 1)]
        [ValidateSet('Info', 'Warn', 'Error', 'Success')]
        [string] $Level = 'Info'
    )

    $stamp = (Get-Date).ToString('HH:mm:ss')
    $line  = "[$stamp] $Message"

    $colour = switch ($Level) {
        'Warn'    { 'Yellow' }
        'Error'   { 'Red' }
        'Success' { 'Green' }
        default   { 'Gray' }
    }
    Write-Host $line -ForegroundColor $colour

    if ($null -ne $script:Snapshot) {
        Add-Content -Path $script:Snapshot.LogFile -Value "$($Level.ToUpper().PadRight(7)) $line" -Encoding UTF8
    }
}

# ---------------------------------------------------------------------------
# Normalization
# ---------------------------------------------------------------------------

function ConvertTo-EstateGuid {
    <#
    .SYNOPSIS
        Lowercases a GUID for joining. Returns $null for empty or all-zero values.

    .DESCRIPTION
        AD returns uppercase GUIDs, Graph returns lowercase, and Power Query
        merges are case-sensitive. Normalizing at extraction is the difference
        between a clean join and an apparent data catastrophe.

        The all-zero GUID is treated as absent: an Intune device carrying
        00000000-0000-0000-0000-000000000000 as its azureADDeviceId is enrolled
        but never properly registered in Entra. It looks like a valid GUID and
        joins to nothing, so it is nulled here and flagged in a _calc column.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipeline)]
        [AllowNull()]
        [AllowEmptyString()]
        $Value
    )
    process {
        if ($null -eq $Value) { return $null }
        $s = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { return $null }
        $s = $s.ToLowerInvariant()
        if ($s -eq $script:EmptyGuid) { return $null }
        $s
    }
}

function Test-EstateGuidIsEmpty {
    <#
    .SYNOPSIS
        True when a GUID is missing, blank, or the all-zero placeholder.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        $Value
    )
    if ($null -eq $Value) { return $true }
    $s = ([string]$Value).Trim()
    ([string]::IsNullOrWhiteSpace($s) -or $s -eq $script:EmptyGuid)
}

function ConvertTo-EstateSerial {
    <#
    .SYNOPSIS
        Normalizes a hardware serial for cross-system joining.

    .DESCRIPTION
        Uppercases, strips whitespace and separators, then nulls the result if it
        is an OEM placeholder, shorter than four characters, or a single repeated
        character. Returning $null is deliberate: an unmatchable serial should
        fail to join loudly rather than join to the wrong device.

        The raw value is always retained alongside this one in the extract, so
        nothing is lost - see the <Prefix>_serialNumber column.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipeline)]
        [AllowNull()]
        [AllowEmptyString()]
        $Value
    )
    process {
        if ($null -eq $Value) { return $null }
        $s = ([string]$Value)
        if ([string]::IsNullOrWhiteSpace($s)) { return $null }

        $s = $s.Trim().ToUpperInvariant() -replace '[\s\-_\.]', ''

        if ($script:JunkSerials -contains $s) { return $null }
        if ($s.Length -lt 4)                  { return $null }
        if ($s -match '^(.)\1+$')             { return $null }

        $s
    }
}

function Format-EstateDate {
    <#
    .SYNOPSIS
        Formats a date as yyyy-MM-dd, or $null when absent. Excel and Power Query
        both parse this unambiguously regardless of regional settings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)] [AllowNull()] $Value,
        [switch] $IncludeTime
    )
    if ($null -eq $Value) { return $null }
    try   { $d = [datetime]$Value }
    catch { return $null }
    if ($IncludeTime) { $d.ToString('yyyy-MM-dd HH:mm:ss') } else { $d.ToString('yyyy-MM-dd') }
}

function Get-EstateDaysSince {
    <#
    .SYNOPSIS
        Whole days elapsed between a timestamp and now.

    .DESCRIPTION
        Floor, not rounding. A [int] cast in PowerShell rounds to even, so
        something last seen 9.7 days ago would report 10 - which matters once
        staleness thresholds are applied to these columns.

        Negative results are possible and are left intact: a future-dated AD
        lastLogonTimestamp means DC clock drift, which is a finding, not
        something to clamp away.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)] [AllowNull()] $Value,
        [datetime] $Now = (Get-Date)
    )
    if ($null -eq $Value) { return $null }
    try   { $d = [datetime]$Value }
    catch { return $null }
    [int][math]::Floor(($Now - $d).TotalDays)
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

function Get-EstateCsvEncoding {
    # PS 5.1 'UTF8' writes a BOM; PS 6+ needs 'utf8BOM' for the same behaviour.
    # Excel misreads non-ASCII in BOM-less UTF-8, and device names contain it.
    if ($PSVersionTable.PSVersion.Major -ge 6) { 'utf8BOM' } else { 'UTF8' }
}

function Export-EstateCsv {
    <#
    .SYNOPSIS
        Writes a curated extract into the snapshot folder and records it in the
        run manifest.

    .DESCRIPTION
        Also warns loudly on an empty result set. A zero-row CSV breaks the
        downstream merge in a way that looks like a join problem rather than an
        extraction problem, so it is called out at the point it happens.

    .PARAMETER System
        Source system label, used in the manifest (AD, Entra, Intune, Autopilot,
        BitLocker, Freshservice).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        $InputObject,

        [Parameter(Mandatory)] [string] $FileName,
        [Parameter(Mandatory)] [string] $System
    )
    begin { $rows = [System.Collections.Generic.List[object]]::new() }
    process { if ($null -ne $InputObject) { $rows.Add($InputObject) } }
    end {
        $snap = Get-EstateSnapshot
        $path = Join-Path $snap.Path $FileName

        if ($rows.Count -eq 0) {
            Write-EstateLog "$FileName - NO ROWS RETURNED. Check credentials, permissions and filters before joining." 'Warn'
        }

        $rows | Export-Csv -Path $path -NoTypeInformation -Encoding (Get-EstateCsvEncoding)

        [pscustomobject]@{
            File        = $FileName
            System      = $System
            Rows        = $rows.Count
            Columns     = if ($rows.Count) { @($rows[0].PSObject.Properties).Count } else { 0 }
            GeneratedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        } | Export-Csv -Path $snap.Manifest -NoTypeInformation -Encoding (Get-EstateCsvEncoding) -Append

        Write-EstateLog "$FileName - $($rows.Count) rows" 'Success'
    }
}

function Export-EstateRaw {
    <#
    .SYNOPSIS
        Writes the complete, untransformed source response to the snapshot's raw\
        folder as newline-delimited JSON.

    .DESCRIPTION
        The curated CSVs carry a deliberate subset of attributes. This sidecar
        carries everything the source returned, so a column can be added later
        by re-reading the snapshot instead of re-running extraction against
        production - and so no attribute is ever silently discarded.

        NDJSON rather than a single JSON array: it stays greppable, streams, and
        Power Query reads it with Json.Document per line.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        $InputObject,

        [Parameter(Mandatory)] [string] $FileName,
        [int] $Depth = 12
    )
    begin {
        $snap   = Get-EstateSnapshot
        $path   = Join-Path $snap.RawPath $FileName
        $writer = [System.IO.StreamWriter]::new($path, $false, [System.Text.UTF8Encoding]::new($false))
        $count  = 0
    }
    process {
        if ($null -eq $InputObject) { return }
        $writer.WriteLine(($InputObject | ConvertTo-Json -Depth $Depth -Compress))
        $count++
    }
    end {
        $writer.Flush(); $writer.Dispose()
        Write-EstateLog "raw\$FileName - $count records"
    }
}

function Get-EstateSecret {
    <#
    .SYNOPSIS
        Reads a required secret or setting from the environment, failing fast with
        instructions rather than sending an empty credential to a live API.

    .DESCRIPTION
        Nothing secret is stored in this repository. See docs/setup.md and
        config/config.example.ps1.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [string] $Name,
        [string] $Purpose
    )
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Environment variable '$Name' is not set$(if ($Purpose) { " ($Purpose)" }). " +
              "Copy config\config.example.ps1 to config\config.local.ps1, fill it in, and dot-source it: . .\config\config.local.ps1"
    }
    $value
}

Export-ModuleMember -Function @(
    'New-EstateSnapshot'
    'Get-EstateSnapshot'
    'Write-EstateLog'
    'ConvertTo-EstateGuid'
    'Test-EstateGuidIsEmpty'
    'ConvertTo-EstateSerial'
    'Format-EstateDate'
    'Get-EstateDaysSince'
    'Export-EstateCsv'
    'Export-EstateRaw'
    'Get-EstateSecret'
    'Get-EstateCsvEncoding'
)
