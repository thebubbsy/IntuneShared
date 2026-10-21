<#
.SYNOPSIS
    Renders terminal-formatted sign-in cards and verification information for OOBE.
.DESCRIPTION
    Decoupled console visualizer for interactive and Device Code authentication flows.
#>
function Out-AsciiQrCode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$UserCode,

        [Parameter()]
        [int]$ExpiresInSeconds = 900,

        [Parameter()]
        [switch]$CopyReceipt,

        [Parameter()]
        [switch]$CopyJson,

        [Parameter()]
        [switch]$Quiet
    )

    $copiedToClipboard = $false
    if (-not $CopyReceipt -and -not $CopyJson) {
        try {
            Set-Clipboard -Value $UserCode -ErrorAction Stop
            $copiedToClipboard = $true
        } catch { }
    }

    $ttlMins = [Math]::Max(1, [int][Math]::Round($ExpiresInSeconds / 60.0))
    $expiresAtUtc = ([DateTime]::UtcNow.AddSeconds($ExpiresInSeconds)).ToString('HH:mm:ss \U\T\C')
    $clipStatus = if ($copiedToClipboard) { "[CLIPBOARD] Code '$UserCode' auto-copied! Press Ctrl+V" } else { "Tip: Copy and paste the code above into your browser" }

    if (-not $Quiet) {
        $border = "=" * 58
        Write-Host "`n  +$border+" -ForegroundColor Cyan
        Write-Host "  |  MICROSOFT ENTRA ID DEVICE AUTHENTICATION                |" -ForegroundColor Cyan
        Write-Host "  +$border+" -ForegroundColor Cyan
        Write-Host "  |                                                          |" -ForegroundColor Cyan
        Write-Host ("  |   1. Navigate to:   " + $Url.PadRight(37).Substring(0, 37) + "|") -ForegroundColor Yellow
        Write-Host ("  |   2. Enter Code:    " + $UserCode.PadRight(37).Substring(0, 37) + "|") -ForegroundColor Green
        Write-Host ("  |   3. Code Expiry:   " + ("~$ttlMins min ($expiresAtUtc)").PadRight(37).Substring(0, 37) + "|") -ForegroundColor Gray
        Write-Host "  |                                                          |" -ForegroundColor Cyan
        Write-Host ("  |   " + $clipStatus.PadRight(55).Substring(0, 55) + "|") -ForegroundColor $(if ($copiedToClipboard) { 'Green' } else { 'DarkGray' })
        Write-Host "  +$border+`n" -ForegroundColor Cyan
    }

    if ($CopyReceipt) {
        try {
            $mdReceipt = @(
                "### Microsoft Entra ID Device Code Sign-In Prompt",
                "| Field | Value |",
                "| :--- | :--- |",
                "| **Verification URL** | $Url |",
                "| **User Code** | ``$UserCode`` |",
                "| **Window / Expiry** | ~$ttlMins min ($expiresAtUtc) |"
            ) -join [Environment]::NewLine
            Set-Clipboard -Value $mdReceipt -ErrorAction Stop
            if (-not $Quiet) {
                Write-Host "  [CLIPBOARD] Copied Markdown Device Code Sign-In Receipt to clipboard." -ForegroundColor Cyan
            }
        } catch { }
    }

    if ($CopyJson) {
        try {
            $jsonPayload = [PSCustomObject]@{
                VerificationUrl  = $Url
                UserCode         = $UserCode
                ExpiresInSeconds = $ExpiresInSeconds
                ExpiresAtUtc     = $expiresAtUtc
            } | ConvertTo-Json -Depth 3
            Set-Clipboard -Value $jsonPayload -ErrorAction Stop
            if (-not $Quiet) {
                Write-Host "  [CLIPBOARD] Copied Device Code Sign-In JSON to clipboard." -ForegroundColor Cyan
            }
        } catch { }
    }
}
