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
        [switch]$AllowBypass
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

    Write-Verbose "Tenant safety assertion verified for tenant '$TenantId' ('$TenantName')."
    if ($PassThru) {
        return $true
    }
}
