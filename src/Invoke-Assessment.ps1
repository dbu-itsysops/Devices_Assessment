#Requires -Version 5.1
<#
.SYNOPSIS
    Runs every extraction phase into a single dated snapshot.

.DESCRIPTION
    Read-only end to end. Nothing in this repository disables, deletes, retires
    or releases anything in any system.

    Phases continue after a failure by default. A missing RSAT module should not
    cost you the Freshservice pull, and a partial snapshot with a clearly logged
    gap is more useful than no snapshot at all. Use -StopOnError to change that.

    Apple School Manager is not automated yet - see docs/decision-record.md,
    section 8. Drop the UI export into the snapshot folder as
    07-asm-devices.csv to complete the set.

.PARAMETER Phase
    Phases to run. Defaults to all four.

.EXAMPLE
    . .\config\config.local.ps1
    .\src\Invoke-Assessment.ps1

.EXAMPLE
    .\src\Invoke-Assessment.ps1 -Phase Freshservice
#>
[CmdletBinding()]
param(
    [ValidateSet('AD', 'Entra', 'Intune', 'Freshservice')]
    [string[]] $Phase = @('AD', 'Entra', 'Intune', 'Freshservice'),

    [datetime] $SnapshotDate = (Get-Date),
    [switch]   $StopOnError
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'EstateAudit.psm1') -Force

$snapshot = New-EstateSnapshot -Date $SnapshotDate

Write-EstateLog '=============================================================='
Write-EstateLog "Device estate assessment - $($SnapshotDate.ToString('yyyy-MM-dd'))"
Write-EstateLog "Phases: $($Phase -join ', ')"
Write-EstateLog '=============================================================='

$scripts = [ordered]@{
    AD           = '01-Export-ADComputers.ps1'
    Entra        = '02-Export-EntraDevices.ps1'
    Intune       = '03-Export-IntuneDevices.ps1'
    Freshservice = '04-Export-Freshservice.ps1'
}

$results = [System.Collections.Generic.List[object]]::new()

foreach ($name in $scripts.Keys) {
    if ($Phase -notcontains $name) { continue }

    $started = Get-Date
    try {
        & (Join-Path $PSScriptRoot $scripts[$name]) -SnapshotDate $SnapshotDate
        $results.Add([pscustomobject]@{ Phase = $name; Status = 'OK'; Duration = (Get-Date) - $started; Error = '' })
    }
    catch {
        Write-EstateLog "$name FAILED: $($_.Exception.Message)" 'Error'
        $results.Add([pscustomobject]@{ Phase = $name; Status = 'FAILED'; Duration = (Get-Date) - $started; Error = $_.Exception.Message })
        if ($StopOnError) { throw }
    }
}

Write-EstateLog ''
Write-EstateLog '--- Phase results ---'
$results |
    Select-Object Phase, Status, @{n = 'Minutes'; e = { [math]::Round($_.Duration.TotalMinutes, 1) }}, Error |
    Format-Table -AutoSize | Out-String -Width 200 | Write-Host

if (Test-Path $snapshot.Manifest) {
    Write-EstateLog '--- Row counts (baseline: compare these against each system''s own UI) ---'
    Import-Csv $snapshot.Manifest |
        Select-Object File, System, Rows, Columns |
        Format-Table -AutoSize | Out-String -Width 200 | Write-Host
}

Write-EstateLog "Snapshot written to $($snapshot.Path)" 'Success'
Write-EstateLog 'Next: docs/join-model.md for the Power Query merge.'

if ($results | Where-Object { $_.Status -eq 'FAILED' }) { exit 1 }
