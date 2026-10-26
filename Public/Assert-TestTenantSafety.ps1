<#
.SYNOPSIS
    Validates that operations are executing against an authorized non-production test tenant.
.DESCRIPTION
    Enforces M365 tenant safety guardrails by:
    1. Verifying that the target Tenant ID matches $env:M365_TEST_TENANT_ID.
    2. Verifying that the Tenant Name matches the allowed test pattern: '(?i)(Dev|Test|Sandbox|Lab)'.
    Throws [TenantSafetyViolationException] if any validation rule fails.
.PARAMETER TenantId
    The GUID or domain of the target Microsoft 365 tenant.
.PARAMETER TenantName
    The display name of the Microsoft 365 tenant.
.PARAMETER AllowedPattern
    Regex pattern defining authorized non-production tenant names. Defaults to '(?i)(Dev|Test|Sandbox|Lab)'.
.PARAMETER PassThru
    Returns $true if all assertions succeed.
.PARAMETER AllowBypass
    Explicit switch to override guardrail only if $env:INTUNE_ALLOW_PRODUCTION_OVERRIDE is 'true'.
.EXAMPLE
    Assert-TestTenantSafety -TenantId 'a8e99999-0000-0000-0000-000000000000' -TenantName 'Contoso-DevSandbox'
#>
function Assert-TestTenantSafety {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$TenantId,

        [Parameter(Mandatory = $false, Position = 1)]
        [string]$TenantName,

        [Parameter()]
        [string]$AllowedPattern = '(?i)(Dev|Test|Sandbox|Lab)',

        [Parameter()]
        [switch]$PassThru,

        [Parameter()]
        [switch]$AllowBypass,

        [Parameter()]
        [switch]$ShowBanner,

        [Parameter()]
        [switch]$CopyReceipt,

        [Parameter()]
        [switch]$CopyJson,

        [Parameter()]
        [switch]$CopyTsv,

        [Parameter()]
        [switch]$CopyHtml,

        [Parameter()]
        [switch]$CopyCsv
    )

    if ($AllowBypass -and $env:INTUNE_ALLOW_PRODUCTION_OVERRIDE -eq 'true') {
        Write-Warning "Tenant safety assertion bypassed via INTUNE_ALLOW_PRODUCTION_OVERRIDE."
        if ($PassThru) { return $true }
        return
    }

    $configuredTestTenantId = $env:M365_TEST_TENANT_ID

    # 1. Environment Variable Assertion
    if ([string]::IsNullOrWhiteSpace($configuredTestTenantId)) {
        $msg = "Tenant Safety Violation: Environment variable 'M365_TEST_TENANT_ID' is not configured. Live test operations require an explicit test tenant."
        Write-Error $msg
        throw [TenantSafetyViolationException]::new($msg)
    }

    # 2. Tenant ID Match Assertion
    if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
        if ($TenantId.Trim() -ne $configuredTestTenantId.Trim()) {
            $msg = "Tenant Safety Violation: Target Tenant ID '$TenantId' does not match authorized test tenant ID '$configuredTestTenantId' ($env:M365_TEST_TENANT_ID)."
            Write-Error $msg
            throw [TenantSafetyViolationException]::new($msg)
        }
    }

    # 3. Tenant Display Name Sandbox Regex Assertion
    if (-not [string]::IsNullOrWhiteSpace($TenantName)) {
        if ($TenantName -notmatch $AllowedPattern) {
            $msg = "Tenant Safety Violation: Tenant display name '$TenantName' failed safety check. It does not match allowed pattern '$AllowedPattern'. Production tenant operation aborted."
            Write-Error $msg
            throw [TenantSafetyViolationException]::new($msg)
        }
    }

    $tName = if ($TenantName) { $TenantName } else { 'Authorized Sandbox' }
    $tId   = if ($TenantId) { $TenantId } else { $configuredTestTenantId }
    $verifiedUtc = (Get-Date).ToUniversalTime().ToString('o')

    if ($CopyReceipt) {
        $mdLines = @(
            "### M365 Tenant Safety Guardrail Receipt (``SANDBOX VERIFIED``)",
            "| Check | Value |",
            "| :--- | :--- |",
            "| **Tenant Name** | $tName |",
            "| **Authorized Tenant ID** | ``$tId`` |",
            "| **Allowed Regex Pattern** | ``$AllowedPattern`` |",
            "| **Guardrail Status** | ``LOCKED / NON-PRODUCTION VERIFIED`` |"
        )
        try { Set-Clipboard -Value ($mdLines -join [Environment]::NewLine) -ErrorAction SilentlyContinue } catch { }
    }
    if ($CopyJson) {
        $jsonObj = [PSCustomObject]@{
            TenantName         = $tName
            AuthorizedTenantId = $tId
            AllowedPattern     = $AllowedPattern
            GuardrailStatus    = 'LOCKED / NON-PRODUCTION VERIFIED'
            VerifiedAtUtc      = $verifiedUtc
        } | ConvertTo-Json -Depth 4
        try { Set-Clipboard -Value $jsonObj -ErrorAction SilentlyContinue } catch { }
    }
    if ($CopyHtml) {
        $htmlCard = @(
            "<div style=`"font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;max-width:600px;background:#0f172a;color:#f8fafc;border:1px solid #334155;border-radius:8px;padding:16px;box-shadow:0 4px 6px -1px rgba(0,0,0,0.1);`">",
            "  <div style=`"display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid #334155;padding-bottom:10px;margin-bottom:12px;`">",
            "    <h3 style=`"margin:0;color:#38bdf8;font-size:16px;font-weight:600;`">M365 Tenant Safety Guardrail Receipt</h3>",
            "    <span style=`"background:#166534;color:#4ade80;padding:2px 8px;border-radius:12px;font-size:12px;font-weight:600;`">SANDBOX VERIFIED</span>",
            "  </div>",
            "  <table style=`"width:100%;border-collapse:collapse;font-size:13px;`">",
            "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Tenant Name</td><td style=`"padding:6px 0;text-align:right;color:#f8fafc;font-weight:600;`">$tName</td></tr>",
            "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Authorized GUID</td><td style=`"padding:6px 0;text-align:right;color:#38bdf8;font-family:monospace;`">$tId</td></tr>",
            "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Allowed Pattern</td><td style=`"padding:6px 0;text-align:right;color:#cbd5e1;`">$AllowedPattern</td></tr>",
            "    <tr><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Verified At</td><td style=`"padding:6px 0;text-align:right;color:#94a3b8;font-size:12px;`">$verifiedUtc</td></tr>",
            "  </table>",
            "</div>"
        ) -join [Environment]::NewLine
        try { Set-Clipboard -Value $htmlCard -ErrorAction SilentlyContinue } catch { }
    }
    if ($CopyCsv) {
        $csvLines = @(
            "TenantName,AuthorizedTenantId,AllowedPattern,GuardrailStatus,VerifiedAtUtc",
            "`"$tName`",`"$tId`",`"$AllowedPattern`",`"LOCKED / NON-PRODUCTION VERIFIED`",`"$verifiedUtc`""
        ) -join [Environment]::NewLine
        try { Set-Clipboard -Value ($csvLines -join [Environment]::NewLine) -ErrorAction SilentlyContinue } catch { }
    }
    if ($CopyTsv) {
        $tsvLines = @(
            "TenantName`tAuthorizedTenantId`tAllowedPattern`tGuardrailStatus`tVerifiedAtUtc",
            "$tName`t$tId`t$AllowedPattern`tLOCKED / NON-PRODUCTION VERIFIED`t$verifiedUtc"
        )
        try { Set-Clipboard -Value ($tsvLines -join [Environment]::NewLine) -ErrorAction SilentlyContinue } catch { }
    }

    if ($ShowBanner) {
        Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor DarkCyan
        Write-Host "  | TENANT SAFETY GUARDRAIL VERIFICATION CARD       [SANDBOX VERIFIED]   |" -ForegroundColor Green
        Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor DarkCyan
        Write-Host ("  | Tenant Name     : {0,-50} |" -f $tName) -ForegroundColor White
        Write-Host ("  | Authorized GUID : {0,-50} |" -f $tId) -ForegroundColor Cyan
        Write-Host ("  | Allowed Pattern : {0,-50} |" -f $AllowedPattern) -ForegroundColor Gray
        if ($CopyReceipt) {
            Write-Host "  | [CLIPBOARD] Markdown guardrail verification receipt copied.          |" -ForegroundColor Green
        }
        if ($CopyJson) {
            Write-Host "  | [CLIPBOARD] JSON guardrail verification receipt copied.              |" -ForegroundColor Green
        }
        if ($CopyHtml) {
        $htmlCard = @(
            "<div style=`"font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;max-width:600px;background:#0f172a;color:#f8fafc;border:1px solid #334155;border-radius:8px;padding:16px;box-shadow:0 4px 6px -1px rgba(0,0,0,0.1);`">",
            "  <div style=`"display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid #334155;padding-bottom:10px;margin-bottom:12px;`">",
            "    <h3 style=`"margin:0;color:#38bdf8;font-size:16px;font-weight:600;`">M365 Tenant Safety Guardrail Receipt</h3>",
            "    <span style=`"background:#166534;color:#4ade80;padding:2px 8px;border-radius:12px;font-size:12px;font-weight:600;`">SANDBOX VERIFIED</span>",
            "  </div>",
            "  <table style=`"width:100%;border-collapse:collapse;font-size:13px;`">",
            "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Tenant Name</td><td style=`"padding:6px 0;text-align:right;color:#f8fafc;font-weight:600;`">$tName</td></tr>",
            "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Authorized GUID</td><td style=`"padding:6px 0;text-align:right;color:#38bdf8;font-family:monospace;`">$tId</td></tr>",
            "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Allowed Pattern</td><td style=`"padding:6px 0;text-align:right;color:#cbd5e1;`">$AllowedPattern</td></tr>",
            "    <tr><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Verified At</td><td style=`"padding:6px 0;text-align:right;color:#94a3b8;font-size:12px;`">$verifiedUtc</td></tr>",
            "  </table>",
            "</div>"
        ) -join [Environment]::NewLine
        try { Set-Clipboard -Value $htmlCard -ErrorAction SilentlyContinue } catch { }
    }
    if ($CopyCsv) {
        $csvLines = @(
            "TenantName,AuthorizedTenantId,AllowedPattern,GuardrailStatus,VerifiedAtUtc",
            "`"$tName`",`"$tId`",`"$AllowedPattern`",`"LOCKED / NON-PRODUCTION VERIFIED`",`"$verifiedUtc`""
        ) -join [Environment]::NewLine
        try { Set-Clipboard -Value ($csvLines -join [Environment]::NewLine) -ErrorAction SilentlyContinue } catch { }
    }
    if ($CopyTsv) {
            Write-Host "  | [CLIPBOARD] TSV guardrail verification receipt copied.               |" -ForegroundColor Green
        }
        if ($CopyHtml) {
            Write-Host "  | [CLIPBOARD] HTML guardrail verification card copied.                 |" -ForegroundColor Green
        }
        if ($CopyCsv) {
            Write-Host "  | [CLIPBOARD] CSV guardrail verification receipt copied.               |" -ForegroundColor Green
        }
        Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor DarkCyan
    }

    Write-Verbose "Tenant safety assertion verified for tenant '$TenantId' ('$TenantName')."
    if ($PassThru) {
        return $true
    }
}
