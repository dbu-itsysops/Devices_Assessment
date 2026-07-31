#Requires -Version 5.1
<#
.SYNOPSIS
    Verifies the shared helpers in src/EstateAudit.psm1.

.DESCRIPTION
    No credentials, no network, no domain. Writes to a temporary folder and
    cleans up after itself, so it is safe to run anywhere at any time.

    These functions are worth testing because every cross-system join depends on
    them: if GUID casing or serial normalization drifts, merges return zero rows
    and it looks like an estate catastrophe rather than a code change.

.EXAMPLE
    .\tests\Test-EstateAudit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "estate-audit-tests-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$env:ESTATE_AUDIT_ROOT = $testRoot

Import-Module (Join-Path $PSScriptRoot '..\src\EstateAudit.psm1') -Force

$script:failures = 0

function Assert-Equal {
    param([string] $Name, $Actual, $Expected)

    $ok = ($null -eq $Expected -and $null -eq $Actual) -or ($Actual -eq $Expected)
    if ($ok) {
        Write-Host "  PASS  $Name" -ForegroundColor Green
    }
    else {
        Write-Host "  FAIL  $Name -> got '$Actual', expected '$Expected'" -ForegroundColor Red
        $script:failures++
    }
}

try {

    # -----------------------------------------------------------------------
    Write-Host "`nConvertTo-EstateSerial" -ForegroundColor Cyan
    Assert-Equal 'uppercases and strips separators' (ConvertTo-EstateSerial ' 5cd-123_4.5x ') '5CD12345X'
    Assert-Equal 'nulls "To Be Filled By O.E.M."'   (ConvertTo-EstateSerial 'To Be Filled By O.E.M.') $null
    Assert-Equal 'nulls "Default string"'           (ConvertTo-EstateSerial 'Default string') $null
    Assert-Equal 'nulls "System Serial Number"'     (ConvertTo-EstateSerial 'System Serial Number') $null
    Assert-Equal 'nulls "N/A"'                      (ConvertTo-EstateSerial 'N/A') $null
    Assert-Equal 'nulls under four characters'      (ConvertTo-EstateSerial 'ABC') $null
    Assert-Equal 'nulls a repeated character'       (ConvertTo-EstateSerial '000000') $null
    Assert-Equal 'nulls whitespace'                 (ConvertTo-EstateSerial '   ') $null
    Assert-Equal 'nulls null'                       (ConvertTo-EstateSerial $null) $null
    # Regression: the reason key columns must be Text in Power Query.
    Assert-Equal 'preserves leading zeros'          (ConvertTo-EstateSerial '0012345') '0012345'
    Assert-Equal 'passes a real Apple serial'       (ConvertTo-EstateSerial 'C02XK1FLJGH5') 'C02XK1FLJGH5'

    # -----------------------------------------------------------------------
    Write-Host "`nConvertTo-EstateGuid" -ForegroundColor Cyan
    Assert-Equal 'lowercases'          (ConvertTo-EstateGuid '4A7B2C1D-0000-1111-2222-ABCDEF012345') '4a7b2c1d-0000-1111-2222-abcdef012345'
    Assert-Equal 'accepts a Guid type' (ConvertTo-EstateGuid ([guid]'4A7B2C1D-0000-1111-2222-ABCDEF012345')) '4a7b2c1d-0000-1111-2222-abcdef012345'
    Assert-Equal 'nulls the zero GUID' (ConvertTo-EstateGuid '00000000-0000-0000-0000-000000000000') $null
    Assert-Equal 'nulls empty'         (ConvertTo-EstateGuid '') $null

    Write-Host "`nTest-EstateGuidIsEmpty" -ForegroundColor Cyan
    Assert-Equal 'zero GUID is empty'     (Test-EstateGuidIsEmpty '00000000-0000-0000-0000-000000000000') $true
    Assert-Equal 'real GUID is not empty' (Test-EstateGuidIsEmpty '4a7b2c1d-0000-1111-2222-abcdef012345') $false
    Assert-Equal 'null is empty'          (Test-EstateGuidIsEmpty $null) $true

    # -----------------------------------------------------------------------
    Write-Host "`nDates" -ForegroundColor Cyan
    Assert-Equal 'formats ISO input' (Format-EstateDate '2026-03-04T11:22:33Z') '2026-03-04'
    Assert-Equal 'nulls null'        (Format-EstateDate $null) $null
    Assert-Equal 'counts whole days' (Get-EstateDaysSince (Get-Date).AddDays(-10)) 10
    # Floors rather than rounds: 9.7 days ago is 9 days, not 10. Thresholds
    # will be applied to these values.
    Assert-Equal 'floors, not rounds' (Get-EstateDaysSince (Get-Date).AddDays(-9.7)) 9
    # Future timestamps mean DC clock drift and are reported, never clamped.
    Assert-Equal 'keeps negatives'    (Get-EstateDaysSince (Get-Date).AddDays(5)) -5

    # -----------------------------------------------------------------------
    Write-Host "`nSnapshot, CSV and manifest" -ForegroundColor Cyan
    $snapshot = New-EstateSnapshot -Date ([datetime]'2026-07-31')

    1..3 |
        ForEach-Object { [pscustomobject]@{ AD_name = "PC$_"; AD_objectGUID = (ConvertTo-EstateGuid ([guid]::NewGuid())) } } |
        Export-EstateCsv -FileName '01-ad-computers.csv' -System 'AD'

    1..2 |
        ForEach-Object { [pscustomobject]@{ Intune_id = $_; Intune_serialNumber = 'To Be Filled By O.E.M.' } } |
        Export-EstateRaw -FileName '03-intune-devices.jsonl'

    # Must warn rather than fail: an empty extract breaks the downstream merge
    # in a way that looks like a join problem.
    @() | Export-EstateCsv -FileName '99-empty.csv' -System 'Test'

    Assert-Equal 'writes the CSV'       (Test-Path (Join-Path $snapshot.Path    '01-ad-computers.csv'))   $true
    Assert-Equal 'writes the sidecar'   (Test-Path (Join-Path $snapshot.RawPath '03-intune-devices.jsonl')) $true
    Assert-Equal 'writes the run log'   (Test-Path $snapshot.LogFile) $true
    Assert-Equal 'CSV row count'        (@(Import-Csv (Join-Path $snapshot.Path '01-ad-computers.csv')).Count) 3
    Assert-Equal 'one JSON line per record' (@(Get-Content (Join-Path $snapshot.RawPath '03-intune-devices.jsonl')).Count) 2

    $manifest = @(Import-Csv $snapshot.Manifest)
    Assert-Equal 'manifest has a row per file' $manifest.Count 2
    Assert-Equal 'manifest records rows'    (($manifest | Where-Object File -eq '01-ad-computers.csv').Rows)    '3'
    Assert-Equal 'manifest records columns' (($manifest | Where-Object File -eq '01-ad-computers.csv').Columns) '2'

    # -----------------------------------------------------------------------
    Write-Host "`nGet-EstateSecret" -ForegroundColor Cyan
    $probe = 'ESTATE_TEST_SECRET_PROBE'
    [Environment]::SetEnvironmentVariable($probe, $null)
    try {
        Get-EstateSecret $probe -Purpose 'test' | Out-Null
        Assert-Equal 'throws when unset' 'did not throw' 'throws'
    }
    catch {
        Assert-Equal 'throws when unset' ($_.Exception.Message -like '*is not set*') $true
    }
    [Environment]::SetEnvironmentVariable($probe, 'set-for-test')
    Assert-Equal 'returns when set' (Get-EstateSecret $probe) 'set-for-test'
    [Environment]::SetEnvironmentVariable($probe, $null)

}
finally {
    Remove-Module EstateAudit -Force -ErrorAction SilentlyContinue
    if (Test-Path $testRoot) { Remove-Item $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
if ($script:failures -gt 0) {
    Write-Host "$script:failures check(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed.' -ForegroundColor Green
