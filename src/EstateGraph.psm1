#Requires -Version 5.1
<#
.SYNOPSIS
    Microsoft Graph connection helper shared by the Entra and Intune extractors.

.DESCRIPTION
    Certificate authentication only, by design. Power Query can call Graph
    directly, but that leaves a client secret stored inside the workbook - and a
    credential holding Device.Read.All across the tenant does not belong in a
    shareable .xlsx. Certificate auth via PowerShell removes the problem rather
    than managing it. See docs/decision-record.md, Decision 5.
#>

Set-StrictMode -Version Latest

# Depends on Get-EstateSecret and Write-EstateLog. Imported globally so the
# helpers resolve regardless of which extractor loaded this module first.
Import-Module (Join-Path $PSScriptRoot 'EstateAudit.psm1') -Global -Force

function Connect-EstateGraph {
    <#
    .SYNOPSIS
        Connects to Microsoft Graph using the app registration and certificate
        configured in the environment, then verifies the granted permissions.

    .DESCRIPTION
        Reads three environment variables (see docs/setup.md):

            ESTATE_GRAPH_APP_ID      application (client) ID
            ESTATE_GRAPH_TENANT_ID   tenant ID
            ESTATE_GRAPH_CERT_THUMB  thumbprint of a certificate in CurrentUser\My

        Reuses an existing connection when one is already established with the
        same app, so running the phases back to back does not re-authenticate.

    .PARAMETER RequiredScope
        Application permissions the caller depends on. Missing ones are reported
        as warnings up front, rather than surfacing later as an empty extract
        that looks like an estate finding.
    #>
    [CmdletBinding()]
    param(
        [string[]] $RequiredScope = @()
    )

    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        throw "The Microsoft.Graph PowerShell SDK is not installed. Run: " +
              "Install-Module Microsoft.Graph -Scope CurrentUser"
    }

    $appId    = Get-EstateSecret 'ESTATE_GRAPH_APP_ID'     -Purpose 'Entra app registration (client) ID'
    $tenantId = Get-EstateSecret 'ESTATE_GRAPH_TENANT_ID'  -Purpose 'Entra tenant ID'
    $thumb    = Get-EstateSecret 'ESTATE_GRAPH_CERT_THUMB' -Purpose 'certificate thumbprint in CurrentUser\My'

    $context = $null
    try { $context = Get-MgContext } catch { $context = $null }

    if ($null -ne $context -and $context.ClientId -eq $appId -and $context.TenantId -eq $tenantId) {
        Write-EstateLog "Reusing existing Graph connection (app $appId)"
    }
    else {
        Connect-MgGraph -ClientId $appId -TenantId $tenantId -CertificateThumbprint $thumb -NoWelcome
        $context = Get-MgContext
        Write-EstateLog "Connected to Graph as app $($context.ClientId) in tenant $($context.TenantId)"
    }

    foreach ($scope in $RequiredScope) {
        if ($context.Scopes -notcontains $scope) {
            Write-EstateLog "Graph permission '$scope' is not granted to this app. The corresponding extract will be empty or incomplete." 'Warn'
        }
    }

    $context
}

function Disconnect-EstateGraph {
    [CmdletBinding()]
    param()
    try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { }
}

Export-ModuleMember -Function 'Connect-EstateGraph', 'Disconnect-EstateGraph'
