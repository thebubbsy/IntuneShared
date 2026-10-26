<#
.SYNOPSIS
    Acquires an OAuth 2.0 access token for Microsoft Graph with partitioned cache isolation and token refresh.
.DESCRIPTION
    Supports Client Secret (Application) and Device Code (Delegated) authentication flows.
    Isolates cached credentials by TenantId, ClientId, and Scopes.
#>
function Connect-GraphToken {
    [CmdletBinding(DefaultParameterSetName = 'DeviceCode')]
    param(
        [Parameter(ParameterSetName = 'DeviceCode')]
        [switch]$DeviceCode,

        [Parameter(ParameterSetName = 'ClientSecret', Mandatory = $true)]
        [string]$ClientSecret,

        [Parameter()]
        [string]$TenantId = 'organizations',

        [Parameter()]
        [string]$ClientId = 'd1ddf0e6-50e1-4fb8-8182-76f584d73f3e',

        [Parameter()]
        [string[]]$Scopes = @('https://graph.microsoft.com/.default'),

        [Parameter()]
        [switch]$ForceRefresh,

        [Parameter()]
        [switch]$ShowSessionBanner,

        [Parameter()]
        [switch]$CopyToken,

        [Parameter()]
        [switch]$CopySessionReceipt,

        [Parameter()]
        [switch]$CopySessionJson,

        [Parameter()]
        [switch]$CopySessionTsv,

        [Parameter()]
        [switch]$CopySessionHtml,

        [Parameter()]
        [switch]$CopySessionCsv
    )

    function Copy-GraphTokenToClipboard {
        param([string]$TokenValue)
        if ($CopyToken -and $TokenValue) {
            try {
                Set-Clipboard -Value $TokenValue -ErrorAction Stop
                Write-Host "  [CLIPBOARD] Copied OAuth 2.0 Bearer Access Token to clipboard." -ForegroundColor Green
            } catch { }
        }
    }

    function Copy-GraphSessionReceiptToClipboard {
        param([PSCustomObject]$Context, [string]$SourceMode)
        if (-not $Context) { return }
        $ttlMins = [Math]::Max(0, [Math]::Round(($Context.ExpiresOn - [datetime]::UtcNow).TotalMinutes, 1))
        $expUtc = $Context.ExpiresOn.ToString('yyyy-MM-dd HH:mm:ss') + ' UTC'
        $scopesJoined = ($Context.Scopes -join ', ')
        if ($CopySessionReceipt) {
            try {
                $mdSession = @(
                    "### Microsoft Graph OAuth 2.0 Session Telemetry Receipt"
                    ""
                    "| Field | Value |"
                    "| :--- | :--- |"
                    "| **Auth Mode** | ``$($Context.PermissionType) ($SourceMode)`` |"
                    "| **Tenant ID** | ``$($Context.TenantId)`` |"
                    "| **Client ID** | ``$($Context.ClientId)`` |"
                    "| **Token TTL** | $ttlMins min |"
                    "| **Expires (UTC)** | ``$expUtc`` |"
                    "| **Scopes** | ``$scopesJoined`` |"
                ) -join "`r`n"
                Set-Clipboard -Value $mdSession -ErrorAction Stop
                Write-Host "  [CLIPBOARD] Copied Graph OAuth 2.0 Session Telemetry Receipt (Markdown) to clipboard." -ForegroundColor Green
            } catch { }
        }
        if ($CopySessionJson) {
            try {
                $jsonSession = [ordered]@{
                    PermissionType = $Context.PermissionType
                    SourceMode     = $SourceMode
                    TenantId       = $Context.TenantId
                    ClientId       = $Context.ClientId
                    TokenTtlMins   = $ttlMins
                    ExpiresUtc     = $expUtc
                    Scopes         = @($Context.Scopes)
                } | ConvertTo-Json -Depth 4
                Set-Clipboard -Value $jsonSession -ErrorAction Stop
                Write-Host "  [CLIPBOARD] Copied Graph OAuth 2.0 Session Telemetry Receipt (JSON) to clipboard." -ForegroundColor Green
            } catch { }
        }
        if ($CopySessionTsv) {
            try {
                $tsvSession = "PermissionType`tSourceMode`tTenantId`tClientId`tTokenTtlMins`tExpiresUtc`tScopes`r`n$($Context.PermissionType)`t$SourceMode`t$($Context.TenantId)`t$($Context.ClientId)`t$ttlMins`t$expUtc`t$scopesJoined"
                Set-Clipboard -Value $tsvSession -ErrorAction Stop
                Write-Host "  [CLIPBOARD] Copied Graph OAuth 2.0 Session Telemetry Receipt (TSV) to clipboard." -ForegroundColor Green
            } catch { }
        }
        if ($CopySessionHtml) {
            try {
                $htmlSession = @(
                    "<div style=`"font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;max-width:640px;background:#0f172a;color:#f8fafc;border:1px solid #334155;border-radius:8px;padding:16px;box-shadow:0 4px 6px -1px rgba(0,0,0,0.1);`">",
                    "  <div style=`"display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid #334155;padding-bottom:10px;margin-bottom:12px;`">",
                    "    <h3 style=`"margin:0;color:#38bdf8;font-size:16px;font-weight:600;`">Microsoft Graph Session Telemetry</h3>",
                    "    <span style=`"background:#0369a1;color:#7dd3fc;padding:2px 8px;border-radius:12px;font-size:12px;font-weight:600;`">$($Context.PermissionType.ToUpper()) ($SourceMode)</span>",
                    "  </div>",
                    "  <table style=`"width:100%;border-collapse:collapse;font-size:13px;`">",
                    "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Tenant ID</td><td style=`"padding:6px 0;text-align:right;color:#f8fafc;font-family:monospace;font-size:11px;`">$($Context.TenantId)</td></tr>",
                    "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Client ID</td><td style=`"padding:6px 0;text-align:right;color:#f8fafc;font-family:monospace;font-size:11px;`">$($Context.ClientId)</td></tr>",
                    "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Token TTL</td><td style=`"padding:6px 0;text-align:right;color:#4ade80;font-weight:600;`">$ttlMins min ($expUtc)</td></tr>",
                    "    <tr><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Granted Scopes</td><td style=`"padding:6px 0;text-align:right;color:#38bdf8;font-family:monospace;font-size:11px;`">$scopesJoined</td></tr>",
                    "  </table>",
                    "</div>"
                ) -join [Environment]::NewLine
                Set-Clipboard -Value $htmlSession -ErrorAction Stop
                Write-Host "  [CLIPBOARD] Copied Graph OAuth 2.0 Session Telemetry Receipt (HTML) to clipboard." -ForegroundColor Green
            } catch { }
        }
        if ($CopySessionCsv) {
            try {
                $csvSession = @(
                    "PermissionType,SourceMode,TenantId,ClientId,TokenTtlMins,ExpiresUtc,Scopes",
                    "`"$($Context.PermissionType)`",`"$SourceMode`",`"$($Context.TenantId)`",`"$($Context.ClientId)`",$ttlMins,`"$expUtc`",`"$scopesJoined`""
                ) -join "`r`n"
                Set-Clipboard -Value $csvSession -ErrorAction Stop
                Write-Host "  [CLIPBOARD] Copied Graph OAuth 2.0 Session Telemetry Receipt (CSV) to clipboard." -ForegroundColor Green
            } catch { }
        }
    }

    function Write-GraphSessionHud {
        param([PSCustomObject]$Context, [string]$SourceMode)
        $ttlMins = [Math]::Max(0, [Math]::Round(($Context.ExpiresOn - [datetime]::UtcNow).TotalMinutes, 1))
        $expUtc = $Context.ExpiresOn.ToString('HH:mm:ss') + ' UTC'
        $scopeCount = @($Context.Scopes).Count
        Write-Host ""
        Write-Host ("  [OAUTH:2.0] [AUTH:{0}] [SOURCE:{1}] [SCOPES:{2}] [CACHE:READY]" -f $Context.PermissionType.ToUpper(), $SourceMode.ToUpper(), $scopeCount) -ForegroundColor Green
        Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor DarkCyan
        Write-Host "  | MICROSOFT GRAPH OAUTH 2.0 SESSION TELEMETRY                          |" -ForegroundColor Cyan
        Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor DarkCyan
        Write-Host ("  | Auth Mode : {0,-24} Tenant : {1,-22} |" -f "$($Context.PermissionType) ($SourceMode)", $Context.TenantId) -ForegroundColor Green
        Write-Host ("  | Token TTL : {0,-24} Scopes : {1,-22} |" -f "$ttlMins min ($expUtc)", "$scopeCount scope(s)") -ForegroundColor Gray
        Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor DarkCyan
    }

    if (-not $script:GraphTokenCache) {
        $script:GraphTokenCache = [System.Collections.Generic.Dictionary[string, object]]::new()
    }

    $scopeString = [string]::Join(' ', $Scopes)
    $cacheKey = "$($TenantId):$($ClientId):$($scopeString)"
    $tokenEndpoint = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"

    # 1. Check partitioned cache
    if (-not $ForceRefresh -and $script:GraphTokenCache.ContainsKey($cacheKey)) {
        $cachedEntry = $script:GraphTokenCache[$cacheKey]
        if ($cachedEntry.ExpiresOn -gt [datetime]::UtcNow.AddMinutes(2)) {
            $script:GraphAuthContext = $cachedEntry
            if ($ShowSessionBanner) { Write-GraphSessionHud -Context $cachedEntry -SourceMode 'CacheHit' }
            Copy-GraphSessionReceiptToClipboard -Context $cachedEntry -SourceMode 'CacheHit'
            Copy-GraphTokenToClipboard -TokenValue $cachedEntry.AccessToken
            return $cachedEntry.AccessToken
        }

        # 2. Token Refresh Flow (if RefreshToken is present)
        if ($cachedEntry.RefreshToken) {
            Write-Verbose "Access token expired for $cacheKey. Attempting refresh via grant_type=refresh_token..."
            try {
                $refreshBody = @{
                    client_id     = $ClientId
                    grant_type    = 'refresh_token'
                    refresh_token = $cachedEntry.RefreshToken
                    scope         = $scopeString
                }
                $refreshRes = Invoke-RestMethod -Uri $tokenEndpoint -Method POST -Body $refreshBody -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop

                $authObj = [PSCustomObject]@{
                    AccessToken    = $refreshRes.access_token
                    RefreshToken   = if ($refreshRes.refresh_token) { $refreshRes.refresh_token } else { $cachedEntry.RefreshToken }
                    TokenType      = $refreshRes.token_type
                    ExpiresOn      = [datetime]::UtcNow.AddSeconds($refreshRes.expires_in)
                    TenantId       = $TenantId
                    ClientId       = $ClientId
                    PermissionType = $cachedEntry.PermissionType
                    Scopes         = $Scopes
                }
                $script:GraphTokenCache[$cacheKey] = $authObj
                $script:GraphAuthContext = $authObj
                if ($ShowSessionBanner) { Write-GraphSessionHud -Context $authObj -SourceMode 'RefreshToken' }
                Copy-GraphSessionReceiptToClipboard -Context $authObj -SourceMode 'RefreshToken'
                Copy-GraphTokenToClipboard -TokenValue $authObj.AccessToken
                return $authObj.AccessToken
            }
            catch {
                Write-Warning "Token refresh failed: $($_.Exception.Message). Falling back to full authentication."
            }
        }
    }

    # 3. Client Secret Flow (Application Scope)
    if ($PSCmdlet.ParameterSetName -eq 'ClientSecret') {
        $body = @{
            client_id     = $ClientId
            client_secret = $ClientSecret
            scope         = $scopeString
            grant_type    = 'client_credentials'
        }

        $res = Invoke-RestMethod -Uri $tokenEndpoint -Method POST -Body $body -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
        
        $authObj = [PSCustomObject]@{
            AccessToken    = $res.access_token
            RefreshToken   = $null
            TokenType      = $res.token_type
            ExpiresOn      = [datetime]::UtcNow.AddSeconds($res.expires_in)
            TenantId       = $TenantId
            ClientId       = $ClientId
            PermissionType = 'Application'
            Scopes         = $Scopes
        }
        $script:GraphTokenCache[$cacheKey] = $authObj
        $script:GraphAuthContext = $authObj
        if ($ShowSessionBanner) { Write-GraphSessionHud -Context $authObj -SourceMode 'ClientSecret' }
        Copy-GraphSessionReceiptToClipboard -Context $authObj -SourceMode 'ClientSecret'
        Copy-GraphTokenToClipboard -TokenValue $res.access_token
        return $res.access_token
    }

    # 4. Device Code Flow (Delegated Scope)
    if ($PSCmdlet.ParameterSetName -eq 'DeviceCode' -or $DeviceCode) {
        $deviceCodeEndpoint = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/devicecode"
        $dcBody = @{
            client_id = $ClientId
            scope     = $scopeString
        }

        $dcResponse = Invoke-RestMethod -Uri $deviceCodeEndpoint -Method POST -Body $dcBody -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop

        if (Get-Command 'Out-AsciiQrCode' -ErrorAction SilentlyContinue) {
            Out-AsciiQrCode -Url $dcResponse.verification_uri -UserCode $dcResponse.user_code
        } else {
            Write-Host "  Sign-in URL: $($dcResponse.verification_uri)" -ForegroundColor Yellow
            Write-Host "  Code:        $($dcResponse.user_code)" -ForegroundColor Green
        }

        Write-Host "  Waiting for user authentication in Entra ID..." -NoNewline -ForegroundColor Cyan

        $interval = [Math]::Max(3, [int]$dcResponse.interval)
        $expiresAt = [datetime]::UtcNow.AddSeconds($dcResponse.expires_in)

        while ([datetime]::UtcNow -lt $expiresAt) {
            Start-Sleep -Seconds $interval

            try {
                $pollBody = @{
                    client_id   = $ClientId
                    grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
                    device_code = $dcResponse.device_code
                }

                $tokenRes = Invoke-RestMethod -Uri $tokenEndpoint -Method POST -Body $pollBody -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
                Write-Host " [OK] Authenticated!" -ForegroundColor Green

                $authObj = [PSCustomObject]@{
                    AccessToken    = $tokenRes.access_token
                    RefreshToken   = $tokenRes.refresh_token
                    TokenType      = $tokenRes.token_type
                    ExpiresOn      = [datetime]::UtcNow.AddSeconds($tokenRes.expires_in)
                    TenantId       = $TenantId
                    ClientId       = $ClientId
                    PermissionType = 'Delegated'
                    Scopes         = $Scopes
                }
                $script:GraphTokenCache[$cacheKey] = $authObj
                $script:GraphAuthContext = $authObj
                Write-GraphSessionHud -Context $authObj -SourceMode 'DeviceCode'
                Copy-GraphSessionReceiptToClipboard -Context $authObj -SourceMode 'DeviceCode'
                Copy-GraphTokenToClipboard -TokenValue $tokenRes.access_token
                return $tokenRes.access_token
            }
            catch {
                $err = $_.Exception.Message
                if ($err -match 'authorization_pending') {
                    Write-Host "." -NoNewline -ForegroundColor Cyan
                    continue
                }
                elseif ($err -match 'slow_down') {
                    $interval += 3
                    continue
                }
                elseif ($err -match 'code_expired') {
                    Write-Host ""
                    throw "Device login code expired. Please re-run the authentication command."
                }
                else {
                    Write-Host ""
                    throw $_
                }
            }
        }

        throw "Device code authentication timed out."
    }
}
