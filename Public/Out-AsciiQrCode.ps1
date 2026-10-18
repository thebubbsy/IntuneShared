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
        [int]$ExpiresInSeconds = 900
    )

    $copiedToClipboard = $false
    try {
        Set-Clipboard -Value $UserCode -ErrorAction Stop
        $copiedToClipboard = $true
    } catch { }

    $ttlMins = [Math]::Max(1, [int][Math]::Round($ExpiresInSeconds / 60.0))
    $clipStatus = if ($copiedToClipboard) { "[CLIPBOARD] Code '$UserCode' auto-copied! Press Ctrl+V" } else { "Tip: Copy and paste the code above into your browser" }

    $border = "=" * 58
    Write-Host "`n  +$border+" -ForegroundColor Cyan
    Write-Host "  |  MICROSOFT ENTRA ID DEVICE AUTHENTICATION                |" -ForegroundColor Cyan
    Write-Host "  +$border+" -ForegroundColor Cyan
    Write-Host "  |                                                          |" -ForegroundColor Cyan
    Write-Host ("  |   1. Navigate to:   " + $Url.PadRight(37).Substring(0, 37) + "|") -ForegroundColor Yellow
    Write-Host ("  |   2. Enter Code:    " + $UserCode.PadRight(37).Substring(0, 37) + "|") -ForegroundColor Green
    Write-Host ("  |   3. Code Expiry:   " + ("~$ttlMins min window").PadRight(37).Substring(0, 37) + "|") -ForegroundColor Gray
    Write-Host "  |                                                          |" -ForegroundColor Cyan
    Write-Host ("  |   " + $clipStatus.PadRight(55).Substring(0, 55) + "|") -ForegroundColor $(if ($copiedToClipboard) { 'Green' } else { 'DarkGray' })
    Write-Host "  +$border+`n" -ForegroundColor Cyan
}
