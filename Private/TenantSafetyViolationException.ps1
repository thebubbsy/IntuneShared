<#
.SYNOPSIS
    Custom exception thrown when tenant safety guardrails are violated.
.DESCRIPTION
    Inherits from System.Exception. Thrown by Assert-TestTenantSafety to prevent
    unauthorized execution against production M365 tenants.
#>
if (-not ('TenantSafetyViolationException' -as [type])) {
    class TenantSafetyViolationException : System.Exception {
        TenantSafetyViolationException() : base("Execution blocked by Tenant Safety Guardrail: Unrecognized or production tenant detected.") {}
        TenantSafetyViolationException([string]$message) : base($message) {}
        TenantSafetyViolationException([string]$message, [System.Exception]$innerException) : base($message, $innerException) {}
    }
}
