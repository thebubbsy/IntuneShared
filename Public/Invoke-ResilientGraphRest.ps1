<#
.SYNOPSIS
    Execute resilient HTTP requests against Microsoft Graph with exponential backoff and Retry-After parsing.
.DESCRIPTION
    Handles 429 (Too Many Requests), 503 (Service Unavailable), and 504 (Gateway Timeout) using
    exponential jittered backoff. Fully compatible with Windows PowerShell 5.1 and PowerShell 7+.
#>
function Invoke-ResilientGraphRest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter()]
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')]
        [string]$Method = 'GET',

        [Parameter()]
        [hashtable]$Headers = @{},

        [Parameter()]
        [object]$Body,

        [Parameter()]
        [string]$ContentType = 'application/json',

        [Parameter()]
        [int]$MaxRetries = 5,

        [Parameter()]
        [int]$BaseDelaySeconds = 2
    )

    $retryCount = 0
    $success = $false
    $result = $null

    while (-not $success -and $retryCount -le $MaxRetries) {
        try {
            $requestParams = @{
                Uri         = $Uri
                Method      = $Method
                Headers     = $Headers
                ContentType = $ContentType
                ErrorAction = 'Stop'
            }

            if ($Body) {
                if ($Body -is [string] -or $Body -is [byte[]]) {
                    $requestParams['Body'] = $Body
                } else {
                    $requestParams['Body'] = ($Body | ConvertTo-Json -Depth 20 -Compress)
                }
            }

            $response = Invoke-RestMethod @requestParams
            $success = $true
            $result = $response
        }
        catch {
            $ex = $_.Exception
            $statusCode = 0
            $retryAfterSeconds = 0

            if ($ex.Response) {
                $statusCode = [int]$ex.Response.StatusCode
                
                # Parse Retry-After header
                if ($ex.Response.Headers -and $ex.Response.Headers['Retry-After']) {
                    $retryHeaderVal = $ex.Response.Headers['Retry-After']
                    $parsedSec = 0
                    if ([int]::TryParse($retryHeaderVal, [ref]$parsedSec)) {
                        $retryAfterSeconds = $parsedSec
                    }
                }
            }

            # Transient errors eligible for retry
            if ($statusCode -eq 429 -or $statusCode -ge 500 -or ($null -ne $ex.InnerException -and $ex.InnerException.Message -match 'timed out|connection closed')) {
                $retryCount++
                if ($retryCount -gt $MaxRetries) {
                    Write-Error "Graph API request failed after $MaxRetries retries. Status: $statusCode. Error: $($_.Exception.Message)"
                    throw $_
                }

                if ($retryAfterSeconds -le 0) {
                    $jitter = (Get-Random -Minimum 0 -Maximum 1000) / 1000.0
                    $calculatedDelay = [Math]::Pow(2, $retryCount) * $BaseDelaySeconds + $jitter
                    $retryAfterSeconds = [Math]::Min(30, [int][Math]::Ceiling($calculatedDelay))
                }

                Write-Warning "Microsoft Graph returned HTTP $statusCode (Throttled/Unavailable). Retrying in $retryAfterSeconds seconds (Attempt $retryCount of $MaxRetries)..."
                Start-Sleep -Seconds $retryAfterSeconds
            }
            else {
                # Extract detailed error payload from Graph response
                $errorDetails = $_.Exception.Message
                if ($ex.Response) {
                    try {
                        $stream = $ex.Response.GetResponseStream()
                        if ($stream) {
                            $reader = New-Object System.IO.StreamReader($stream)
                            $bodyText = $reader.ReadToEnd()
                            if ($bodyText) {
                                $errorJson = $bodyText | ConvertFrom-Json -ErrorAction SilentlyContinue
                                if ($errorJson -and $errorJson.error -and $errorJson.error.message) {
                                    $errorDetails = "$($errorJson.error.code): $($errorJson.error.message)"
                                } else {
                                    $errorDetails = $bodyText
                                }
                            }
                        }
                    } catch { }
                }
                Write-Error "Graph API request failed (HTTP $statusCode): $errorDetails"
                throw [System.InvalidOperationException]::new("Graph API Error ($statusCode): $errorDetails", $ex)
            }
        }
    }

    return $result
}
