# ---------------------------------------------------------------------------
# Device estate assessment - local configuration template
# ---------------------------------------------------------------------------
#
#   1. Copy this file to config.local.ps1  (git-ignored, never committed)
#   2. Fill in the values below
#   3. Dot-source it before running any extractor:
#
#         . .\config\config.local.ps1
#         .\src\Invoke-Assessment.ps1
#
# These are process-scoped: they disappear when the session closes. To persist
# them for your user account instead, see docs/setup.md.
#
# NOTHING SECRET BELONGS IN THIS REPOSITORY. config.local.ps1 is git-ignored;
# keep it that way.
# ---------------------------------------------------------------------------

# --- Microsoft Graph (Entra + Intune phases) -------------------------------
# Certificate authentication, not a client secret - see docs/decision-record.md,
# Decision 5. The certificate must be in CurrentUser\My with its private key.

$env:ESTATE_GRAPH_APP_ID     = '00000000-0000-0000-0000-000000000000'  # Application (client) ID
$env:ESTATE_GRAPH_TENANT_ID  = '00000000-0000-0000-0000-000000000000'  # Directory (tenant) ID
$env:ESTATE_GRAPH_CERT_THUMB = 'ABCDEF0123456789ABCDEF0123456789ABCDEF01'

# --- Freshservice (asset phase) --------------------------------------------
# Profile Settings -> API Key in Freshservice. Used as the Basic auth username
# with 'X' as the password.

$env:FRESHSERVICE_DOMAIN  = 'contoso.freshservice.com'
$env:FRESHSERVICE_API_KEY = 'your-api-key-here'

# --- Output -----------------------------------------------------------------
# Root for dated snapshot folders. Each run writes to <root>\<yyyy-MM-dd>\.

$env:ESTATE_AUDIT_ROOT = 'C:\estate-audit'
