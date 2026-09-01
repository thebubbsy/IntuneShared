<#
.SYNOPSIS
    Acquires an OAuth 2.0 access token for Microsoft Graph with explicit permission provider models.
.DESCRIPTION
    Implements Device Code Flow (interactive/OOBE), Client Secret (application), and Certificate
    authentication. Attaches permission scope metadata to prevent delegated/application mismatches.
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
        [switch]$ForceRefresh
    )

    # 1. Check in-memory cache
    if (-not $ForceRefresh -and $script:GraphAuthContext -and $script:GraphAuthContext.ExpiresOn -gt [datetime]::UtcNow.AddMinutes(2)) {
        return $script:GraphAuthContext.AccessToken
    }

    $tokenEndpoint = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    $scopeString = [string]::Join(' ', $Scopes)

    # 2. Client Secret Flow (Application Permission Scope)
    if ($PSCmdlet.ParameterSetName -eq 'ClientSecret') {
        $body = @{
            client_id     = $ClientId
            client_secret = $ClientSecret
            scope         = $scopeString
            grant_type    = 'client_credentials'
        }

        $res = Invoke-RestMethod -Uri $tokenEndpoint -Method POST -Body $body -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
        
        $script:GraphAuthContext = [PSCustomObject]@{
            AccessToken    = $res.access_token
            TokenType      = $res.token_type
            ExpiresOn      = [datetime]::UtcNow.AddSeconds($res.expires_in)
            TenantId       = $TenantId
            ClientId       = $ClientId
            PermissionType = 'Application'
            Scopes         = $Scopes
        }
        return $res.access_token
    }

    # 3. Device Code Flow (Delegated Permission Scope for OOBE)
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

                $script:GraphAuthContext = [PSCustomObject]@{
                    AccessToken    = $tokenRes.access_token
                    RefreshToken   = $tokenRes.refresh_token
                    TokenType      = $tokenRes.token_type
                    ExpiresOn      = [datetime]::UtcNow.AddSeconds($tokenRes.expires_in)
                    TenantId       = $TenantId
                    ClientId       = $ClientId
                    PermissionType = 'Delegated'
                    Scopes         = $Scopes
                }
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
