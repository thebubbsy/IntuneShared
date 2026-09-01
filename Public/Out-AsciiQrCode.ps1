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
        [string]$UserCode
    )

    $border = "=" * 58
    Write-Host "`n  +$border+" -ForegroundColor Cyan
    Write-Host "  |  MICROSOFT ENTRA ID DEVICE AUTHENTICATION                |" -ForegroundColor Cyan
    Write-Host "  +$border+" -ForegroundColor Cyan
    Write-Host "  |                                                          |" -ForegroundColor Cyan
    Write-Host ("  |   1. Navigate to:   " + $Url.PadRight(37) + "|") -ForegroundColor Yellow
    Write-Host ("  |   2. Enter Code:    " + $UserCode.PadRight(37) + "|") -ForegroundColor Green
    Write-Host "  |                                                          |" -ForegroundColor Cyan
    Write-Host "  +$border+`n" -ForegroundColor Cyan
}
