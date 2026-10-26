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
        [switch]$CopyCsv,

        [Parameter()]
        [switch]$CopyHtml,

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
        Write-Host ""
        Write-Host ("  [AUTH:DEVICE-CODE] [CODE:{0}] [TTL:{1}m] [EXPIRES:{2}] [FLOW:OOBE]" -f $UserCode, $ttlMins, $expiresAtUtc) -ForegroundColor Green
        $border = "=" * 58
        Write-Host "  +$border+" -ForegroundColor Cyan
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

    if ($CopyHtml) {
        try {
            $htmlAuth = @(
                "<div style=`"font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;max-width:540px;background:#0f172a;color:#f8fafc;border:1px solid #334155;border-radius:8px;padding:20px;text-align:center;box-shadow:0 4px 6px -1px rgba(0,0,0,0.1);`">",
                "  <h3 style=`"margin:0 0 12px 0;color:#38bdf8;font-size:16px;font-weight:600;`">Microsoft Entra ID Device Sign-In</h3>",
                "  <p style=`"color:#94a3b8;font-size:13px;margin:0 0 16px 0;`">Navigate to the verification portal and enter your one-time device code:</p>",
                "  <div style=`"margin:16px 0;`"><a href=`"$Url`" target=`"_blank`" style=`"background:#0284c7;color:#fff;text-decoration:none;padding:10px 20px;border-radius:6px;font-weight:600;font-size:14px;display:inline-block;`">$Url</a></div>",
                "  <div style=`"background:#1e293b;border:1px dashed #475569;border-radius:6px;padding:12px;margin:16px 0;`">",
                "    <span style=`"font-size:11px;color:#94a3b8;text-transform:uppercase;letter-spacing:1px;display:block;margin-bottom:4px;`">User Code</span>",
                "    <span style=`"font-family:monospace;font-size:24px;font-weight:700;color:#4ade80;letter-spacing:3px;`">$UserCode</span>",
                "  </div>",
                "  <div style=`"color:#64748b;font-size:12px;`">Code expires in ~$ttlMins minutes ($expiresAtUtc)</div>",
                "</div>"
            ) -join [Environment]::NewLine
            Set-Clipboard -Value $htmlAuth -ErrorAction Stop
            if (-not $Quiet) {
                Write-Host "  [CLIPBOARD] Copied HTML Device Code Sign-In Card to clipboard." -ForegroundColor Cyan
            }
        } catch { }
    }

    if ($CopyCsv) {
        try {
            $csvAuth = @(
                "VerificationUrl,UserCode,ExpiresInSeconds,ExpiresAtUtc",
                "`"$Url`",`"$UserCode`",$ExpiresInSeconds,`"$expiresAtUtc`""
            ) -join "`r`n"
            Set-Clipboard -Value $csvAuth -ErrorAction Stop
            if (-not $Quiet) {
                Write-Host "  [CLIPBOARD] Copied CSV Device Code Sign-In Row to clipboard." -ForegroundColor Cyan
            }
        } catch { }
    }
}
